//! Places: the towns photos were taken in (reverse geocoded by the
//! `geocode` job), and photos without a location placed by their neighbors.

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde_json::{Value, json};

use super::{COLS, Columns, VISIBLE};
use crate::{ApiError, ApiResult, App, AppState, media};

/// Places as the lists show them ([`place_json`]): each with the `assets`
/// taken there; the caller adds WHERE and GROUP BY p.id.
pub const SUMMARY: &str = "SELECT p.id, p.name, p.admin1, p.cc, count(*),
                                  (array_agg(assets.id ORDER BY assets.taken_at DESC NULLS LAST))[1]
                           FROM places p
                           JOIN edges e ON e.dst_type = 'place' AND e.dst_id = p.id::text
                                       AND e.rel = 'taken_at' AND e.src_type = 'asset'
                           JOIN assets ON assets.id = e.src_id";

/// Every place with visible photos, most photographed first.
pub async fn list(State(app): State<AppState>, headers: HeaderMap) -> ApiResult<Response> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!(
                "{SUMMARY}
                 WHERE {VISIBLE}
                 GROUP BY p.id
                 ORDER BY count(*) DESC, p.name"
            ),
            &[],
        )
        .await?;
    let places: Vec<Value> = rows.iter().map(place_json).collect();
    Ok(media::json_validated(&headers, &json!({ "places": places })))
}

pub fn place_json(r: &tokio_postgres::Row) -> Value {
    json!({
        "id": r.get::<_, i64>(0),
        "name": r.get::<_, Option<String>>(1),
        "region": r.get::<_, Option<String>>(2),
        "country": r.get::<_, Option<String>>(3),
        "photos": r.get::<_, i64>(4),
        "cover": r.get::<_, Option<String>>(5),
    })
}

pub async fn assets(State(app): State<AppState>, Path(id): Path<i64>, headers: HeaderMap) -> ApiResult<Response> {
    let c = app.pool.get().await?;
    let place = c
        .query_opt("SELECT name, admin1, cc FROM places WHERE id = $1", &[&id])
        .await?
        .ok_or(ApiError::NotFound)?;
    let rows = c
        .query(
            &format!(
                "SELECT {COLS} FROM assets
                 JOIN edges e ON e.src_type = 'asset' AND e.src_id = assets.id
                             AND e.rel = 'taken_at' AND e.dst_type = 'place'
                 WHERE e.dst_id = $1 AND {VISIBLE}
                 ORDER BY assets.taken_at DESC NULLS LAST, assets.id"
            ),
            &[&id.to_string()],
        )
        .await?;
    Ok(media::json_validated(
        &headers,
        &json!({
            "id": id,
            "name": place.get::<_, Option<String>>(0),
            "region": place.get::<_, Option<String>>(1),
            "country": place.get::<_, Option<String>>(2),
            "assets": Columns::from_rows(&rows, app.cfg.tz),
        }),
    ))
}

/// A photo without a location (a screenshot, a camera without GPS, a photo
/// sent in a chat) borrows the place of the located photo taken closest to
/// it, if one was taken within three hours: then "in Croatia" finds the
/// whole trip, not only what the phone geotagged. Borrowed places are marked
/// (`props.borrowed`) and never lent on. Run hourly; returns how many were
/// placed.
pub async fn borrow_places(app: &App) -> ApiResult<u64> {
    let c = app.pool.get().await?;
    Ok(c.execute(
        "INSERT INTO edges (src_type, src_id, rel, dst_type, dst_id, confidence, props)
         SELECT 'asset', a.id, 'taken_at', 'place', near.dst_id, 0.5, '{\"borrowed\": true}'::jsonb
         FROM assets a
         CROSS JOIN LATERAL (
             SELECT e.dst_id FROM assets b
             JOIN edges e ON e.src_type = 'asset' AND e.src_id = b.id AND e.rel = 'taken_at' AND e.dst_type = 'place'
                         AND NOT coalesce((e.props->>'borrowed')::boolean, false)
             WHERE b.taken_at BETWEEN a.taken_at - interval '3 hours' AND a.taken_at + interval '3 hours'
               AND b.id <> a.id
             ORDER BY abs(extract(epoch FROM b.taken_at - a.taken_at))
             LIMIT 1
         ) near
         WHERE a.taken_at IS NOT NULL AND a.lat IS NULL
           AND NOT EXISTS (SELECT 1 FROM edges e WHERE e.src_type = 'asset' AND e.src_id = a.id AND e.rel = 'taken_at')
         ON CONFLICT DO NOTHING",
        &[],
    )
    .await?)
}
