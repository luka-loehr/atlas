//! Every asset embedding in one contiguous block of memory.
//!
//! Semantic search is an exact scan: the query vector against every asset
//! vector, no approximate index and no recall gap. Postgres can do that scan
//! too, but each vector sits out of line in TOAST, so the database spends its
//! time fetching 8 KB per row. Held here as one `n x 2048` matrix the same
//! scan is a few milliseconds and never leaves the CPU cache's happy path.
//!
//! The matrix is loaded once and then follows the table incrementally: rows
//! carry `updated_at`, Postgres announces writes, and a refresh pulls only
//! what is newer than the last load. Deleted assets are dropped by the
//! caller's join against the visible set, so a stale row can never surface.
//!
//! Stills and clips are scored against their own kind, each with its own
//! question (see [`Questions`]): the two sit at different distances from any
//! text (with the previous model clips had 0.28 against 0.17 mean similarity
//! for the same query), and one scale for both put one kind in front of
//! better hits of the other. The scale is robust, median and median absolute
//! deviation, so a concept a fifth of the library shows (selfies) does not
//! widen its own yardstick until none of its photos stands out.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::Result;
use atlas_core::vector::{dot, normalize};
use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use tokio::sync::RwLock;

pub use atlas_core::EMBED_DIM as DIM;

/// Below this many vectors a kind is scored on the scale of the whole
/// library: its own median and spread would be noise.
const MIN_KIND: usize = 50;

/// One asset a search found.
pub struct Hit {
    pub id: String,
    /// cosine similarity to the query's question for its kind
    pub similarity: f32,
    /// robust z-score within its kind: how many spreads it lies above the
    /// kind's median similarity for this query
    pub z: f32,
    /// the z-score the best of its kind reaches by chance alone, and the one
    /// that about two unrelated vectors of its kind still exceed; both grow
    /// with the number of vectors
    pub chance_best: f32,
    pub chance_tail: f32,
}

/// A search as the model embeds it: once as the question for stills and
/// once for clips (unit vectors).
pub struct Questions {
    pub still: Vec<f32>,
    pub clip: Vec<f32>,
}

#[derive(Default)]
struct Matrix {
    ids: Vec<String>,
    /// per row: a clip (true) or a still
    video: Vec<bool>,
    rows: HashMap<String, usize>,
    data: Vec<f32>,
    loaded_until: Option<DateTime<Utc>>,
}

pub struct VectorIndex {
    matrix: RwLock<Matrix>,
    stale: AtomicBool,
}

impl Default for VectorIndex {
    fn default() -> Self {
        VectorIndex { matrix: RwLock::default(), stale: AtomicBool::new(true) }
    }
}

impl VectorIndex {
    /// The embeddings table changed; refresh before the next search.
    pub fn mark_stale(&self) {
        self.stale.store(true, Ordering::SeqCst);
    }

    async fn refresh(&self, pool: &Pool) -> Result<()> {
        if !self.stale.swap(false, Ordering::SeqCst) {
            return Ok(());
        }
        let mut matrix = self.matrix.write().await;
        let result = load_newer(pool, &mut matrix).await;
        if result.is_err() {
            self.stale.store(true, Ordering::SeqCst);
        }
        result
    }

    /// The `limit` assets that stand out most, best first. Raw similarities
    /// are not comparable across queries (a vague query sits close to
    /// everything) nor across kinds; the z-score says how much an asset
    /// stands out among its kind for this one.
    pub async fn search(self: &Arc<Self>, pool: &Pool, query: Arc<Questions>, limit: usize) -> Result<Vec<Hit>> {
        self.refresh(pool).await?;
        let index = self.clone();
        Ok(tokio::task::spawn_blocking(move || {
            let matrix = index.matrix.blocking_read();
            let scored = matrix.score(&query);
            let limit = limit.min(scored.scores.len());
            if limit == 0 {
                return Vec::new();
            }
            let kind_of = |row: usize| scored.kind(matrix.video[row]);
            let mut ranked: Vec<(usize, f32)> =
                scored.scores.iter().enumerate().map(|(row, &s)| (row, kind_of(row).z(s))).collect();
            ranked.select_nth_unstable_by(limit - 1, |a, b| b.1.total_cmp(&a.1));
            ranked.truncate(limit);
            ranked.sort_unstable_by(|a, b| b.1.total_cmp(&a.1));
            ranked
                .into_iter()
                .map(|(row, z)| {
                    let kind = kind_of(row);
                    Hit {
                        id: matrix.ids[row].clone(),
                        similarity: scored.scores[row],
                        z,
                        chance_best: chance(kind.n, 0.5),
                        chance_tail: chance(kind.n, 2.0),
                    }
                })
                .collect()
        })
        .await?)
    }

    /// How much each of `ids` stands out for the query (z within its kind,
    /// on the scale of the whole library, so a subset ranks the way the
    /// library would). Assets without a vector are left out.
    pub async fn scores(
        self: &Arc<Self>,
        pool: &Pool,
        query: Arc<Questions>,
        ids: Vec<String>,
    ) -> Result<HashMap<String, f32>> {
        self.refresh(pool).await?;
        let index = self.clone();
        Ok(tokio::task::spawn_blocking(move || {
            let matrix = index.matrix.blocking_read();
            let scored = matrix.score(&query);
            ids.into_iter()
                .filter_map(|id| {
                    let row = *matrix.rows.get(&id)?;
                    Some((id, scored.kind(matrix.video[row]).z(scored.scores[row])))
                })
                .collect()
        })
        .await?)
    }

    pub async fn len(&self) -> usize {
        self.matrix.read().await.ids.len()
    }
}

impl Matrix {
    /// Every row against the question of its kind, and each kind's scale.
    fn score(&self, query: &Questions) -> Scored {
        let scores: Vec<f32> = self
            .data
            .chunks_exact(DIM)
            .zip(&self.video)
            .map(|(row, &video)| dot(row, if video { &query.clip } else { &query.still }))
            .collect();
        let all = Scale::of(scores.clone());
        let scale = |video: bool| {
            let kind = Scale::of(scores.iter().zip(&self.video).filter(|(_, v)| **v == video).map(|(s, _)| *s).collect());
            if kind.n >= MIN_KIND { kind } else { all }
        };
        let (stills, clips) = (scale(false), scale(true));
        Scored { scores, stills, clips }
    }
}

/// One query's similarity per row, and the scale of each kind.
struct Scored {
    scores: Vec<f32>,
    stills: Scale,
    clips: Scale,
}

impl Scored {
    fn kind(&self, video: bool) -> &Scale {
        if video { &self.clips } else { &self.stills }
    }
}

/// Median and spread of a set of similarities; the spread is the median
/// absolute deviation, scaled (x 1.4826) to equal the standard deviation of
/// normal data.
#[derive(Clone, Copy)]
struct Scale {
    n: usize,
    median: f32,
    spread: f32,
}

impl Scale {
    fn of(mut scores: Vec<f32>) -> Scale {
        let n = scores.len();
        if n == 0 {
            return Scale { n, median: 0.0, spread: 1.0 };
        }
        let median = middle(&mut scores);
        scores.iter_mut().for_each(|s| *s = (*s - median).abs());
        Scale { n, median, spread: (1.4826 * middle(&mut scores)).max(1e-6) }
    }

    fn z(&self, score: f32) -> f32 {
        (score - self.median) / self.spread
    }
}

fn middle(values: &mut [f32]) -> f32 {
    let mid = values.len() / 2;
    *values.select_nth_unstable_by(mid, f32::total_cmp).1
}

/// The z-score that about `k` of `n` vectors unrelated to the query still
/// exceed: the normal tail `Q(t) = k / n`, solved with `Q(t) ≈ φ(t) / t`.
fn chance(n: usize, k: f32) -> f32 {
    let l = (n as f32 / (k * (2.0 * std::f32::consts::PI).sqrt())).ln();
    if l <= 0.0 {
        return 0.0;
    }
    (2.0 * l - (2.0 * l).ln()).max(0.0).sqrt()
}

async fn load_newer(pool: &Pool, matrix: &mut Matrix) -> Result<()> {
    let started = std::time::Instant::now();
    let c = pool.get().await?;
    // strictly-newer would miss rows written in the same microsecond as the
    // last one seen; >= re-reads at most that one instant, and the row map
    // makes re-reading harmless
    let rows = c
        .query(
            "SELECT e.owner_id, e.vec, e.updated_at, a.type = 'video'
               FROM embeddings e JOIN assets a ON a.id = e.owner_id
              WHERE e.owner_type = 'asset' AND e.model = $1 AND ($2::timestamptz IS NULL OR e.updated_at >= $2)
              ORDER BY e.updated_at",
            &[&atlas_core::EMBED_MODEL, &matrix.loaded_until],
        )
        .await?;
    let before = matrix.ids.len();
    for row in &rows {
        let id: String = row.get(0);
        let vec: pgvector::Vector = row.get(1);
        let mut values = vec.to_vec();
        if values.len() != DIM {
            continue;
        }
        normalize(&mut values);
        match matrix.rows.get(&id) {
            Some(&at) => matrix.data[at * DIM..(at + 1) * DIM].copy_from_slice(&values),
            None => {
                matrix.rows.insert(id.clone(), matrix.ids.len());
                matrix.ids.push(id);
                matrix.video.push(row.get(3));
                matrix.data.extend_from_slice(&values);
            }
        }
        matrix.loaded_until = Some(row.get(2));
    }
    if matrix.ids.len() != before {
        tracing::info!(
            "vector index: {} assets ({} new) in {:?}",
            matrix.ids.len(),
            matrix.ids.len() - before,
            started.elapsed()
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_scale_ignores_a_cluster_of_matches() {
        // 80 unrelated scores around 0.2, 20 matches far above
        let mut scores: Vec<f32> = (0..80).map(|i| 0.2 + (i % 9) as f32 * 0.005 - 0.02).collect();
        scores.extend([0.5f32; 20]);
        let scale = Scale::of(scores);
        assert_eq!(scale.n, 100);
        assert!((scale.median - 0.2).abs() < 0.011, "median {}", scale.median);
        assert!(scale.z(0.5) > 10.0, "the matches stand out: {}", scale.z(0.5));
    }

    #[test]
    fn chance_levels_follow_the_normal_tail() {
        // exact normal quantiles: Q^-1(2/800) = 2.81, Q^-1(2/19700) = 3.72
        assert!((chance(800, 2.0) - 2.81).abs() < 0.03, "{}", chance(800, 2.0));
        assert!((chance(19_700, 2.0) - 3.72).abs() < 0.03, "{}", chance(19_700, 2.0));
        assert!(chance(19_700, 0.5) > chance(800, 0.5));
        assert_eq!(chance(1, 2.0), 0.0);
    }
}
