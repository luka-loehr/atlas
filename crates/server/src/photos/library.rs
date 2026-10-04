//! Library-wide views: who the server is, totals, the side collections
//! (favorites, videos, archive, locked, trash) and places.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{COLS, Columns, VISIBLE};
use crate::{ApiError, ApiResult, AppState, media};

/// What a client checks when it connects: is this an Atlas server, which
/// version, and which timezone the library is shown in.
pub async fn server(State(app): State<AppState>) -> Json<Value> {
    Json(json!({
        "name": "atlas",
        "version": env!("CARGO_PKG_VERSION"),
        "hostname": crate::system::metrics::hostname(),
        "timezone": app.cfg.tz.name(),
        "sharing": app.cfg.sharing(),
    }))
}

pub async fn stats(State(app): State<AppState>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let a = c
        .query_one(
            &format!(
                "SELECT count(*) FILTER (WHERE {VISIBLE} AND type = 'photo'),
                        count(*) FILTER (WHERE {VISIBLE} AND type = 'video'),
                        coalesce(sum(size_bytes), 0)::bigint,
                        min(taken_at) FILTER (WHERE {VISIBLE}),
                        max(taken_at) FILTER (WHERE {VISIBLE}),
                        count(*) FILTER (WHERE {VISIBLE} AND favorite),
                        count(*) FILTER (WHERE archived AND trashed_at IS NULL AND NOT locked),
                        count(*) FILTER (WHERE locked AND trashed_at IS NULL),
                        count(*) FILTER (WHERE trashed_at IS NOT NULL)
                 FROM assets"
            ),
            &[],
        )
        .await?;
    let d = c
        .query_one(
            "SELECT count(*), coalesce(sum(size_bytes), 0)::bigint,
                    (SELECT count(*) FROM drive_folders),
                    (SELECT count(*) FROM drive_files WHERE trashed_at IS NOT NULL)
             FROM drive_files WHERE trashed_at IS NULL",
            &[],
        )
        .await?;
    let albums: i64 = c.query_one("SELECT count(*) FROM albums", &[]).await?.get(0);
    let people: i64 = c
        .query_one("SELECT count(*) FROM persons WHERE merged_into IS NULL AND face_count > 0", &[])
        .await?
        .get(0);
    Ok(Json(json!({
        "photos": {
            "photos": a.get::<_, i64>(0),
            "videos": a.get::<_, i64>(1),
            "bytes": a.get::<_, i64>(2),
            "oldest": a.get::<_, Option<DateTime<Utc>>>(3),
            "newest": a.get::<_, Option<DateTime<Utc>>>(4),
            "favorites": a.get::<_, i64>(5),
            "archived": a.get::<_, i64>(6),
            "locked": a.get::<_, i64>(7),
            "trashed": a.get::<_, i64>(8),
            "albums": albums,
            "people": people,
        },
        "drive": {
            "files": d.get::<_, i64>(0),
            "bytes": d.get::<_, i64>(1),
            "folders": d.get::<_, i64>(2),
            "trashed": d.get::<_, i64>(3),
        },
    })))
}

/// Photos per day over the last year (the library's activity heatmap).
/// Days are local days in the library timezone.
pub async fn heatmap(State(app): State<AppState>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!(
                "SELECT to_char((taken_at AT TIME ZONE $1)::date, 'YYYY-MM-DD') AS day, count(*)::int
                 FROM assets
                 WHERE taken_at > now() - interval '372 days' AND {VISIBLE}
                 GROUP BY 1 ORDER BY 1"
            ),
            &[&app.cfg.tz.name()],
        )
        .await?;
    let items: Vec<Value> =
        rows.iter().map(|r| json!({ "d": r.get::<_, String>(0), "n": r.get::<_, i32>(1) })).collect();
    Ok(Json(json!({ "items": items })))
}

/// The collections next to the timeline. They are mutually exclusive with
/// it and with each other where it matters: trash wins over everything,
/// archive excludes locked.
pub async fn view(State(app): State<AppState>, Path(view): Path<String>, headers: HeaderMap) -> ApiResult<Response> {
    let (predicate, order) = match view.as_str() {
        "favorites" => (format!("assets.favorite AND {VISIBLE}"), "assets.taken_at DESC NULLS LAST"),
        "videos" => (format!("assets.type = 'video' AND {VISIBLE}"), "assets.taken_at DESC NULLS LAST"),
        "archive" => (
            "assets.archived AND assets.trashed_at IS NULL AND NOT assets.locked".into(),
            "assets.taken_at DESC NULLS LAST",
        ),
        "locked" => ("assets.locked AND assets.trashed_at IS NULL".into(), "assets.taken_at DESC NULLS LAST"),
        "trash" => ("assets.trashed_at IS NOT NULL".into(), "assets.trashed_at DESC"),
        _ => return Err(ApiError::NotFound),
    };
    let c = app.pool.get().await?;
    let rows = c
        .query(&format!("SELECT {COLS} FROM assets WHERE {predicate} ORDER BY {order}, assets.id"), &[])
        .await?;
    Ok(media::json_validated(&headers, &json!({ "assets": Columns::from_rows(&rows, app.cfg.tz) })))
}

/// Every place with visible photos, most photographed first.
pub async fn places(State(app): State<AppState>, headers: HeaderMap) -> ApiResult<Response> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!(
                "SELECT p.id, p.name, p.admin1, p.cc, count(*),
                        (array_agg(assets.id ORDER BY assets.taken_at DESC NULLS LAST))[1]
                 FROM places p
                 JOIN edges e ON e.dst_type = 'place' AND e.dst_id = p.id::text
                             AND e.rel = 'taken_at' AND e.src_type = 'asset'
                 JOIN assets ON assets.id = e.src_id
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

pub async fn place_assets(State(app): State<AppState>, Path(id): Path<i64>, headers: HeaderMap) -> ApiResult<Response> {
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
