//! The timeline, precomputed.
//!
//! The grid's whole geometry comes from one small index (every month with
//! its count and per-day histogram), so the client lays out the full scroll
//! range before a single asset is loaded; months are then fetched as they
//! scroll into view. Both the index and every month are held in memory as
//! ready-to-send gzip bodies with a validator, so the hot path is a hash
//! lookup and a write, and an unchanged month costs a 304.
//!
//! The cache is rebuilt lazily after any write to `assets`: Postgres
//! announces those (trigger + LISTEN), so writes from the workers, the import
//! command or psql all invalidate it.

use std::collections::HashMap;
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, RwLock};

use anyhow::Result;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use bytes::Bytes;
use chrono::{DateTime, Datelike};
use serde::Serialize;

use super::{COLS, Columns, Item, VISIBLE};
use crate::{ApiError, ApiResult, App, AppState, media, util};

/// Bucket key of assets without a capture date; sorts after every month.
pub const UNDATED: &str = "undated";

#[derive(Default)]
pub struct Cache {
    generation: AtomicU64,
    built: RwLock<Option<Arc<Timeline>>>,
    building: tokio::sync::Mutex<()>,
}

pub struct Timeline {
    generation: u64,
    index: Body,
    buckets: HashMap<String, Body>,
}

struct Body {
    raw: Bytes,
    gzip: Bytes,
    etag: String,
}

impl Body {
    fn new(raw: Vec<u8>) -> Self {
        let mut encoder = flate2::write::GzEncoder::new(Vec::with_capacity(raw.len() / 3), flate2::Compression::new(6));
        let _ = encoder.write_all(&raw);
        let gzip = encoder.finish().unwrap_or_default();
        Body { etag: util::etag(&raw), raw: raw.into(), gzip: gzip.into() }
    }

    fn respond(&self, headers: &HeaderMap) -> Response {
        if media::accepts_gzip(headers) {
            media::validated(headers, &self.etag, || self.gzip.clone(), true)
        } else {
            media::validated(headers, &self.etag, || self.raw.clone(), false)
        }
    }
}

impl Cache {
    pub fn invalidate(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
    }

    fn current(&self) -> Option<Arc<Timeline>> {
        let built = self.built.read().unwrap();
        built.as_ref().filter(|t| t.generation == self.generation.load(Ordering::SeqCst)).cloned()
    }

    pub async fn get(&self, app: &App) -> Result<Arc<Timeline>> {
        if let Some(t) = self.current() {
            return Ok(t);
        }
        // one rebuild at a time; latecomers reuse it
        let _guard = self.building.lock().await;
        if let Some(t) = self.current() {
            return Ok(t);
        }
        let generation = self.generation.load(Ordering::SeqCst);
        let started = std::time::Instant::now();
        let c = app.pool.get().await?;
        let rows = c.query(&format!("SELECT {COLS} FROM assets WHERE {VISIBLE}"), &[]).await?;
        drop(c);
        let tz = app.cfg.tz;
        let timeline = tokio::task::spawn_blocking(move || {
            let items = rows.iter().map(|r| Item::from_row(r, tz)).collect();
            build(items, generation)
        })
        .await??;
        tracing::debug!("timeline rebuilt in {:?}", started.elapsed());
        let timeline = Arc::new(timeline);
        *self.built.write().unwrap() = Some(timeline.clone());
        Ok(timeline)
    }
}

#[derive(Serialize)]
struct Index {
    total: usize,
    buckets: Vec<IndexEntry>,
}

#[derive(Serialize)]
struct IndexEntry {
    key: String,
    count: usize,
    etag: String,
    /// [day of month, count], newest day first; empty for the undated bucket
    days: Vec<(u32, usize)>,
}

#[derive(Serialize)]
struct Bucket<'a> {
    key: &'a str,
    #[serde(flatten)]
    assets: Columns,
}

fn build(mut items: Vec<Item>, generation: u64) -> Result<Timeline> {
    // newest first; undated last (None sorts below every Some)
    items.sort_unstable_by(|a, b| b.local.cmp(&a.local).then_with(|| a.id.cmp(&b.id)));
    let total = items.len();

    let mut index = Index { total, buckets: Vec::new() };
    let mut buckets = HashMap::new();
    let mut current: Option<(String, Columns, Vec<(u32, usize)>)> = None;

    let mut flush = |entry: Option<(String, Columns, Vec<(u32, usize)>)>| -> Result<()> {
        if let Some((key, assets, days)) = entry {
            let count = assets.id.len();
            let body = Body::new(serde_json::to_vec(&Bucket { key: &key, assets })?);
            index.buckets.push(IndexEntry { key: key.clone(), count, etag: body.etag.clone(), days });
            buckets.insert(key, body);
        }
        Ok(())
    };

    for item in items {
        let (key, day) = match item.local.and_then(|t| DateTime::from_timestamp(t, 0)) {
            Some(date) => (date.format("%Y-%m").to_string(), Some(date.day())),
            None => (UNDATED.to_string(), None),
        };
        if current.as_ref().is_none_or(|(k, _, _)| *k != key) {
            flush(current.take())?;
            current = Some((key, Columns::default(), Vec::new()));
        }
        let (_, assets, days) = current.as_mut().unwrap();
        if let Some(day) = day {
            match days.last_mut() {
                Some((d, n)) if *d == day => *n += 1,
                _ => days.push((day, 1)),
            }
        }
        assets.push(item);
    }
    flush(current.take())?;

    Ok(Timeline { generation, index: Body::new(serde_json::to_vec(&index)?), buckets })
}

pub async fn index(State(app): State<AppState>, headers: HeaderMap) -> ApiResult<Response> {
    Ok(app.timeline.get(&app).await?.index.respond(&headers))
}

pub async fn bucket(State(app): State<AppState>, Path(key): Path<String>, headers: HeaderMap) -> ApiResult<Response> {
    let timeline = app.timeline.get(&app).await?;
    Ok(timeline.buckets.get(&key).ok_or(ApiError::NotFound)?.respond(&headers))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};

    fn item(id: &str, local: Option<(i32, u32, u32)>) -> Item {
        Item {
            id: id.into(),
            video: false,
            local: local.map(|(y, m, d)| Utc.with_ymd_and_hms(y, m, d, 12, 0, 0).unwrap().timestamp()),
            width: 4,
            height: 3,
            duration: 0.0,
            favorite: false,
            thumbhash: None,
        }
    }

    #[test]
    fn groups_by_month_newest_first_with_undated_last() {
        let timeline = build(
            vec![
                item("a", Some((2024, 7, 30))),
                item("u", None),
                item("b", Some((2024, 8, 1))),
                item("c", Some((2024, 7, 31))),
                item("d", Some((2024, 7, 31))),
            ],
            1,
        )
        .unwrap();
        let index: serde_json::Value = serde_json::from_slice(&timeline.index.raw).unwrap();
        assert_eq!(index["total"], 5);
        let keys: Vec<&str> = index["buckets"].as_array().unwrap().iter().map(|b| b["key"].as_str().unwrap()).collect();
        assert_eq!(keys, ["2024-08", "2024-07", UNDATED]);
        assert_eq!(index["buckets"][1]["days"], serde_json::json!([[31, 2], [30, 1]]));

        let july: serde_json::Value = serde_json::from_slice(&timeline.buckets["2024-07"].raw).unwrap();
        assert_eq!(july["id"], serde_json::json!(["c", "d", "a"]));
        assert_eq!(index["buckets"][1]["etag"], timeline.buckets["2024-07"].etag);
    }
}
