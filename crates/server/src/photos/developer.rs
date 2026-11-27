//! Developer-friendly structured Media & AI Search REST API (`/v1/media/*`),
//! exposing semantic embeddings (`wemm2b`), people/face recognition, pet recognition,
//! OCR text, places, and visual similarity in clean typed JSON objects linked
//! directly to the `media` S3 bucket.

use std::collections::HashMap;

use atlas_common::models::{MediaPersonRef, MediaSearchItem, MediaSearchResponse, MediaUrls};
use axum::Json;
use axum::extract::{Path, Query, State};
use serde::Deserialize;

use super::VISIBLE;
use super::search::{SearchQuery, search};
use crate::{ApiError, ApiResult, App, AppState, util};

#[derive(Deserialize, Default)]
pub struct DeveloperSearchQuery {
    #[serde(default)]
    pub q: String,
    pub limit: Option<usize>,
    pub person_id: Option<i64>,
    pub media_type: Option<String>,
}

#[derive(Deserialize, Default)]
pub struct SimilarQuery {
    pub limit: Option<usize>,
}

fn urls_for(id: &str, key: &str) -> MediaUrls {
    MediaUrls {
        original: format!("/v1/assets/{id}/original"),
        thumb_512: format!("/v1/assets/{id}/thumb/512"),
        thumb_2048: format!("/v1/assets/{id}/thumb/2048"),
        tile: format!("/v1/assets/{id}/tile"),
        s3: format!("/s3/media/{key}"),
    }
}

/// Hydrates an ordered list of `(asset_id, optional_score)` into rich [`MediaSearchItem`]s
/// in two batched Postgres queries (zero N+1 queries!).
pub async fn hydrate_media_items(
    app: &App,
    ordered_ids: &[(String, Option<f32>)],
) -> ApiResult<Vec<MediaSearchItem>> {
    if ordered_ids.is_empty() {
        return Ok(vec![]);
    }
    let ids: Vec<String> = ordered_ids.iter().map(|(id, _)| id.clone()).collect();
    let c = app.pool.get().await?;

    let asset_rows = c
        .query(
            "SELECT a.id, a.type, a.taken_at, a.width, a.height, a.duration_s, a.size_bytes,
                    coalesce(a.favorite, false), a.camera, a.orig_path,
                    o.key,
                    pl.name AS place_name,
                    at.text AS ocr_text
               FROM assets a
               LEFT JOIN LATERAL (
                   SELECT key FROM objects
                    WHERE bucket = 'media' AND asset_id = a.id AND trashed_at IS NULL
                    LIMIT 1
               ) o ON TRUE
               LEFT JOIN LATERAL (
                   SELECT p.name FROM edges e
                     JOIN places p ON p.id::text = e.dst_id
                    WHERE e.src_type = 'asset' AND e.src_id = a.id
                      AND e.rel = 'taken_at' AND e.dst_type = 'place'
                    LIMIT 1
               ) pl ON TRUE
               LEFT JOIN asset_text at ON at.asset_id = a.id
              WHERE a.id = ANY($1)",
            &[&ids],
        )
        .await?;

    let people_rows = c
        .query(
            "SELECT DISTINCT f.asset_id, p.id, p.display_name, p.kind
               FROM faces f
               JOIN persons p ON p.id = f.person_id
              WHERE f.asset_id = ANY($1)
                AND NOT p.hidden
                AND p.merged_into IS NULL
              ORDER BY f.asset_id, p.id",
            &[&ids],
        )
        .await?;
    drop(c);

    let mut people_by_asset: HashMap<String, Vec<MediaPersonRef>> = HashMap::new();
    for r in people_rows {
        let aid: String = r.get(0);
        people_by_asset
            .entry(aid)
            .or_default()
            .push(MediaPersonRef {
                id: r.get(1),
                name: r.get(2),
                kind: r.get(3),
            });
    }

    let mut by_id: HashMap<String, MediaSearchItem> = HashMap::with_capacity(asset_rows.len());
    for r in asset_rows {
        let id: String = r.get(0);
        let media_type: String = r.get(1);
        let taken_at: Option<chrono::DateTime<chrono::Utc>> = r.get(2);
        let orig_path: String = r.get(9);
        let obj_key: Option<String> = r.get(10);
        let fallback_ext = util::lower_ext(&orig_path);
        let ext = if fallback_ext.is_empty() {
            if media_type == "video" { "mp4" } else { "jpg" }
        } else {
            fallback_ext.as_str()
        };
        let key = obj_key.unwrap_or_else(|| {
            let month = taken_at
                .map(|t| t.format("%Y/%m").to_string())
                .unwrap_or_else(|| "0000/00".into());
            format!("{month}/{id}.{ext}")
        });
        let urls = urls_for(&id, &key);
        let people = people_by_asset.remove(&id).unwrap_or_default();

        by_id.insert(
            id.clone(),
            MediaSearchItem {
                id,
                bucket: "media".into(),
                key,
                media_type,
                taken_at,
                width: r.get(3),
                height: r.get(4),
                duration_s: r.get(5),
                size_bytes: r.get(6),
                favorite: r.get(7),
                camera: r.get(8),
                place: r.get(11),
                people,
                ocr_text: r.get(12),
                score: None,
                urls,
            },
        );
    }

    let mut out = Vec::with_capacity(ordered_ids.len());
    for (id, score) in ordered_ids {
        if let Some(mut item) = by_id.remove(id) {
            item.score = *score;
            out.push(item);
        }
    }
    Ok(out)
}

/// `GET /v1/media/search` — developer-friendly structured search across semantic
/// embeddings, people, pets, places, dates, filenames, and OCR text.
pub async fn media_search(
    State(app): State<AppState>,
    Query(q): Query<DeveloperSearchQuery>,
) -> ApiResult<Json<MediaSearchResponse>> {
    let limit = q.limit.unwrap_or(50).clamp(1, 200);
    let term = q.q.trim().to_string();

    // Direct structured filter mode when `q` is empty (e.g. `?person_id=3` or recent media)
    if term.is_empty() {
        let c = app.pool.get().await?;
        let rows = if let Some(pid) = q.person_id {
            c.query(
                &format!(
                    "SELECT DISTINCT assets.id, assets.taken_at
                       FROM assets
                       JOIN faces f ON f.asset_id = assets.id
                      WHERE f.person_id = $1
                        AND {VISIBLE}
                        AND ($2::text IS NULL OR assets.type = $2)
                      ORDER BY assets.taken_at DESC NULLS LAST
                      LIMIT $3"
                ),
                &[&pid, &q.media_type, &(limit as i64)],
            )
            .await?
        } else {
            c.query(
                &format!(
                    "SELECT assets.id, assets.taken_at
                       FROM assets
                      WHERE {VISIBLE}
                        AND ($1::text IS NULL OR assets.type = $1)
                      ORDER BY assets.taken_at DESC NULLS LAST
                      LIMIT $2"
                ),
                &[&q.media_type, &(limit as i64)],
            )
            .await?
        };
        drop(c);

        let ordered: Vec<(String, Option<f32>)> =
            rows.into_iter().map(|r| (r.get(0), None)).collect();
        let items = hydrate_media_items(&app, &ordered).await?;
        let total = items.len();
        return Ok(Json(MediaSearchResponse {
            query: term,
            semantic: "filtered".into(),
            total,
            items,
        }));
    }

    // Full hybrid semantic + lexicon + OCR search via existing search engine
    let Json(raw) = search(
        State(app.clone()),
        Query(SearchQuery {
            q: term.clone(),
            debug: true,
        }),
    )
    .await?;

    let semantic = raw["semantic"].as_str().unwrap_or("unknown").to_string();
    let ids: Vec<String> = raw["assets"]["id"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    let scores: Vec<Option<f32>> = raw["scores"]
        .as_array()
        .map(|arr| arr.iter().map(|v| v.as_f64().map(|x| x as f32)).collect())
        .unwrap_or_else(|| vec![None; ids.len()]);

    let mut ordered: Vec<(String, Option<f32>)> = ids
        .into_iter()
        .enumerate()
        .map(|(i, id)| (id, scores.get(i).copied().flatten()))
        .collect();

    // Optional post-filters (`person_id`, `media_type`) before hydration
    ordered.truncate(limit * 2);
    let mut items = hydrate_media_items(&app, &ordered).await?;
    if let Some(pid) = q.person_id {
        items.retain(|it| it.people.iter().any(|p| p.id == pid));
    }
    if let Some(ref mt) = q.media_type {
        items.retain(|it| &it.media_type == mt);
    }
    items.truncate(limit);
    let total = items.len();

    Ok(Json(MediaSearchResponse {
        query: term,
        semantic,
        total,
        items,
    }))
}

/// `GET /v1/media/similar/{id}` — finds visually & semantically similar photos/videos
/// using exact cosine similarity on the in-memory `wemm2b` 2048-d embedding matrix.
pub async fn similar_media(
    State(app): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SimilarQuery>,
) -> ApiResult<Json<MediaSearchResponse>> {
    if !util::is_content_id(&id) {
        return Err(ApiError::NotFound);
    }
    let limit = q.limit.unwrap_or(24).clamp(1, 200);
    let hits = app.ml.vectors.similar(&app.pool, &id, limit).await?;
    let ordered: Vec<(String, Option<f32>)> = hits
        .into_iter()
        .map(|h| (h.id, Some(h.similarity)))
        .collect();
    let items = hydrate_media_items(&app, &ordered).await?;
    let total = items.len();
    Ok(Json(MediaSearchResponse {
        query: format!("similar:{id}"),
        semantic: "ready".into(),
        total,
        items,
    }))
}

/// `GET /v1/media/assets/{id}` — single structured `MediaSearchItem` lookup.
pub async fn get_media_item(
    State(app): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<MediaSearchItem>> {
    if !util::is_content_id(&id) {
        return Err(ApiError::NotFound);
    }
    let mut items = hydrate_media_items(&app, &[(id, None)]).await?;
    let item = items.pop().ok_or(ApiError::NotFound)?;
    Ok(Json(item))
}
