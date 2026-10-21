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
            let scores: Vec<f32> = matrix
                .data
                .chunks_exact(DIM)
                .zip(&matrix.video)
                .map(|(row, &video)| dot(row, if video { &query.clip } else { &query.still }))
                .collect();
            let limit = limit.min(scores.len());
            if limit == 0 {
                return Vec::new();
            }
            let all = Scale::of(scores.clone());
            let scale = |video: bool| {
                let kind = Scale::of(scores.iter().zip(&matrix.video).filter(|(_, v)| **v == video).map(|(s, _)| *s).collect());
                if kind.n >= MIN_KIND { kind } else { all }
            };
            let (stills, clips) = (scale(false), scale(true));
            let kind_of = |row: usize| if matrix.video[row] { &clips } else { &stills };
            let mut scored: Vec<(usize, f32)> = scores.iter().enumerate().map(|(row, &s)| (row, kind_of(row).z(s))).collect();
            scored.select_nth_unstable_by(limit - 1, |a, b| b.1.total_cmp(&a.1));
            scored.truncate(limit);
            scored.sort_unstable_by(|a, b| b.1.total_cmp(&a.1));
            scored
                .into_iter()
                .map(|(row, z)| {
                    let kind = kind_of(row);
                    Hit {
                        id: matrix.ids[row].clone(),
                        similarity: scores[row],
                        z,
                        chance_best: chance(kind.n, 0.5),
                        chance_tail: chance(kind.n, 2.0),
                    }
                })
                .collect()
        })
        .await?)
    }

    pub async fn len(&self) -> usize {
        self.matrix.read().await.ids.len()
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

pub fn normalize(v: &mut [f32]) {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        v.iter_mut().for_each(|x| *x /= norm);
    }
}

/// Eight independent accumulators let the compiler vectorize the sum; a
/// single running total would force strict left-to-right float addition.
fn dot(a: &[f32], b: &[f32]) -> f32 {
    let mut acc = [0f32; 8];
    for (x, y) in a.chunks_exact(8).zip(b.chunks_exact(8)) {
        for i in 0..8 {
            acc[i] += x[i] * y[i];
        }
    }
    acc.iter().sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dot_matches_the_plain_sum() {
        let a: Vec<f32> = (0..DIM).map(|i| (i as f32 * 0.37).sin()).collect();
        let b: Vec<f32> = (0..DIM).map(|i| (i as f32 * 0.11).cos()).collect();
        let plain: f32 = a.iter().zip(&b).map(|(x, y)| x * y).sum();
        assert!((dot(&a, &b) - plain).abs() < 1e-2);
    }

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

    #[test]
    fn normalize_makes_unit_vectors() {
        let mut v = vec![3.0, 4.0];
        normalize(&mut v);
        assert!((v[0] - 0.6).abs() < 1e-6 && (v[1] - 0.8).abs() < 1e-6);
    }
}
