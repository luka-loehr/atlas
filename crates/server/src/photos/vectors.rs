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

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::Result;
use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use tokio::sync::RwLock;

pub const DIM: usize = 2048;
pub const MODEL: &str = "qwen3vl";

#[derive(Default)]
struct Matrix {
    ids: Vec<String>,
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

    /// The `limit` nearest assets, best first, each with its z-score: how
    /// many standard deviations its cosine similarity lies above the mean of
    /// the whole library for this query. Raw similarities are not comparable
    /// across queries (a vague query sits close to everything); the z-score
    /// says how much an asset stands out for this one.
    pub async fn search(self: &Arc<Self>, pool: &Pool, query: Arc<Vec<f32>>, limit: usize) -> Result<Vec<(String, f32)>> {
        self.refresh(pool).await?;
        let index = self.clone();
        Ok(tokio::task::spawn_blocking(move || {
            let matrix = index.matrix.blocking_read();
            let mut scored: Vec<(usize, f32)> = matrix
                .data
                .chunks_exact(DIM)
                .map(|row| dot(row, &query))
                .enumerate()
                .collect();
            let limit = limit.min(scored.len());
            if limit == 0 {
                return Vec::new();
            }
            let n = scored.len() as f32;
            let mean = scored.iter().map(|s| s.1).sum::<f32>() / n;
            let deviation = (scored.iter().map(|s| (s.1 - mean).powi(2)).sum::<f32>() / n).sqrt().max(1e-6);
            scored.select_nth_unstable_by(limit - 1, |a, b| b.1.total_cmp(&a.1));
            scored.truncate(limit);
            scored.sort_unstable_by(|a, b| b.1.total_cmp(&a.1));
            scored.into_iter().map(|(row, score)| (matrix.ids[row].clone(), (score - mean) / deviation)).collect()
        })
        .await?)
    }

    pub async fn len(&self) -> usize {
        self.matrix.read().await.ids.len()
    }
}

async fn load_newer(pool: &Pool, matrix: &mut Matrix) -> Result<()> {
    let started = std::time::Instant::now();
    let c = pool.get().await?;
    // strictly-newer would miss rows written in the same microsecond as the
    // last one seen; >= re-reads at most that one instant, and the row map
    // makes re-reading harmless
    let rows = c
        .query(
            "SELECT owner_id, vec, updated_at FROM embeddings
             WHERE owner_type = 'asset' AND model = $1 AND ($2::timestamptz IS NULL OR updated_at >= $2)
             ORDER BY updated_at",
            &[&MODEL, &matrix.loaded_until],
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
    fn normalize_makes_unit_vectors() {
        let mut v = vec![3.0, 4.0];
        normalize(&mut v);
        assert!((v[0] - 0.6).abs() < 1e-6 && (v[1] - 0.8).abs() < 1e-6);
    }
}
