//! Everything the viewer's info sheet shows about one asset.

use axum::Json;
use axum::extract::{Path, State};
use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::photos::local_seconds;
use crate::{ApiError, ApiResult, AppState, util};

/// Everything the viewer's info sheet shows, in one round trip.
pub async fn info(State(app): State<AppState>, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    if !util::is_content_id(&id) {
        return Err(ApiError::NotFound);
    }
    let c = app.pool.get().await?;
    let r = c
        .query_opt(
            "SELECT type, taken_at, tz_offset_s, taken_src, orig_name, camera, width, height, size_bytes,
                    duration_s, lat, lon, favorite, archived, locked, trashed_at, source, description,
                    exif, preview_at IS NOT NULL
             FROM assets WHERE id = $1",
            &[&id],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    let place = c
        .query_opt(
            "SELECT p.id, p.name, p.admin1, p.cc
             FROM edges e JOIN places p ON p.id::text = e.dst_id
             WHERE e.src_type = 'asset' AND e.src_id = $1 AND e.rel = 'taken_at' AND e.dst_type = 'place'
             LIMIT 1",
            &[&id],
        )
        .await?
        .map(|p| {
            json!({
                "id": p.get::<_, i64>(0), "name": p.get::<_, Option<String>>(1),
                "region": p.get::<_, Option<String>>(2), "country": p.get::<_, Option<String>>(3),
            })
        });
    // each person or pet once, at their best face; named ones first
    let people: Vec<Value> = c
        .query(
            "SELECT face, id, name, kind FROM (
                 SELECT DISTINCT ON (p.id) f.id AS face, p.id, p.display_name AS name, p.kind,
                        coalesce(f.quality, 0) * coalesce(f.width_px, 1) AS worth
                 FROM faces f JOIN persons p ON p.id = f.person_id
                 WHERE f.asset_id = $1 AND NOT p.hidden AND p.merged_into IS NULL
                 ORDER BY p.id, worth DESC
             ) x ORDER BY (name IS NULL), worth DESC",
            &[&id],
        )
        .await?
        .iter()
        .map(|f| {
            json!({
                "face": f.get::<_, i64>(0), "id": f.get::<_, i64>(1),
                "name": f.get::<_, Option<String>>(2), "kind": f.get::<_, String>(3),
            })
        })
        .collect();
    let text: Option<String> = c
        .query_opt("SELECT text FROM asset_text WHERE asset_id = $1", &[&id])
        .await?
        .map(|r| r.get(0));
    let albums: Vec<Value> = c
        .query(
            "SELECT a.id, a.title FROM albums a JOIN album_assets aa ON aa.album_id = a.id
             WHERE aa.asset_id = $1 ORDER BY lower(a.title)",
            &[&id],
        )
        .await?
        .iter()
        .map(|a| json!({ "id": a.get::<_, i64>(0), "title": a.get::<_, String>(1) }))
        .collect();
    let taken: Option<DateTime<Utc>> = r.get(1);
    let offset: Option<i32> = r.get(2);
    Ok(Json(json!({
        "id": id,
        "type": r.get::<_, String>(0),
        "taken_at": taken,
        "local": taken.map(|t| local_seconds(t, offset, app.cfg.tz)),
        "taken_src": r.get::<_, Option<String>>(3),
        "name": r.get::<_, Option<String>>(4),
        "camera": r.get::<_, Option<String>>(5),
        "width": r.get::<_, Option<i32>>(6),
        "height": r.get::<_, Option<i32>>(7),
        "size": r.get::<_, Option<i64>>(8),
        "duration": r.get::<_, Option<f64>>(9),
        "lat": r.get::<_, Option<f64>>(10),
        "lon": r.get::<_, Option<f64>>(11),
        "favorite": r.get::<_, Option<bool>>(12).unwrap_or(false),
        "archived": r.get::<_, bool>(13),
        "locked": r.get::<_, bool>(14),
        "trashed_at": r.get::<_, Option<DateTime<Utc>>>(15),
        "source": r.get::<_, Option<String>>(16),
        "description": r.get::<_, Option<String>>(17),
        "exif": r.get::<_, Option<Value>>(18),
        "has_preview": r.get::<_, bool>(19),
        "place": place,
        "people": people,
        "text": text,
        "albums": albums,
    })))
}
