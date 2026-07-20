//! atlas-photos — timeline / thumbs / originals / video streaming.
//!
//!   GET /api/stats                       library totals (for the account sheet)
//!   GET /api/timeline/summary            [{month:"2024-07", count}]
//!   GET /api/timeline?before=&limit=     newest-first cursor pages
//!   GET /api/albums                      [{id, title, count, cover}]
//!   GET /api/albums/:id/assets
//!   GET /api/search?q=                   v1: name/album/description/year match
//!   GET /api/assets/:id/thumb/256|1024   WebP, Cache-Control: immutable
//!   GET /api/assets/:id/original
//!   GET /api/assets/:id/stream           Range streaming (AVPlayer)

use std::path::PathBuf;

use axum::{
    extract::{Path, Query, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use chrono::{DateTime, Utc};
use deadpool_postgres::{Config as PgConfig, Pool, Runtime};
use serde::{Deserialize, Serialize};
use tower::ServiceExt;
use tower_http::services::ServeFile;

#[derive(Clone)]
struct App {
    pool: Pool,
    photos_dir: PathBuf,
}

#[tokio::main]
async fn main() {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/atlas".into());
    let photos_dir = PathBuf::from(std::env::var("PHOTOS_DIR").unwrap_or(format!("{home}/photos")));
    let password = std::fs::read_to_string(format!("{home}/atlas/backend/docker/.env"))
        .ok()
        .and_then(|s| {
            s.lines()
                .find_map(|l| l.strip_prefix("POSTGRES_PASSWORD=").map(str::to_string))
        })
        .expect("POSTGRES_PASSWORD in backend/docker/.env");

    let mut cfg = PgConfig::new();
    cfg.host = Some("127.0.0.1".into());
    cfg.dbname = Some("atlas".into());
    cfg.user = Some("atlas".into());
    cfg.password = Some(password);
    let pool = cfg
        .create_pool(Some(Runtime::Tokio1), tokio_postgres::NoTls)
        .expect("pg pool");

    let app = App { pool, photos_dir };
    let router = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/api/stats", get(stats))
        .route("/api/timeline/summary", get(summary))
        .route("/api/timeline", get(timeline))
        .route("/api/albums", get(albums))
        .route("/api/albums/{id}/assets", get(album_assets))
        .route("/api/search", get(search))
        .route("/api/assets/{id}/thumb/{size}", get(thumb))
        .route("/api/assets/{id}/original", get(original))
        .route("/api/assets/{id}/stream", get(stream))
        .with_state(app);

    let addr = "0.0.0.0:8788";
    println!("atlas-photos on {addr}");
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, router).await.unwrap();
}

// ---------------------------------------------------------------- queries ---

#[derive(Serialize)]
struct Asset {
    id: String,
    #[serde(rename = "type")]
    kind: String,
    taken_at: Option<DateTime<Utc>>,
    width: Option<i32>,
    height: Option<i32>,
    duration_s: Option<f64>,
}

fn asset_from(r: &tokio_postgres::Row) -> Asset {
    Asset {
        id: r.get(0),
        kind: r.get(1),
        taken_at: r.get(2),
        width: r.get(3),
        height: r.get(4),
        duration_s: r.get(5),
    }
}

const ASSET_COLS: &str = "id, type, taken_at, width, height, duration_s";

// deleted (Trash) and private (Locked Folder) assets stay out of the main
// timeline and search — the Locked Folder is reachable only via its album
// (Face-ID gated in the app).
const EXCLUDE_HIDDEN: &str = "AND NOT EXISTS (SELECT 1 FROM album_assets aa \
     JOIN albums al ON al.id = aa.album_id WHERE aa.asset_id = assets.id \
     AND al.title IN ('Trash','Papierkorb','Bin','Locked Folder','Gesperrter Ordner'))";

async fn stats(State(app): State<App>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let r = c
        .query_one(
            "SELECT count(*),
                    count(*) FILTER (WHERE type='video'),
                    coalesce(sum(size_bytes),0)::bigint,
                    min(taken_at), max(taken_at)
             FROM assets",
            &[],
        )
        .await?;
    let albums: i64 = c.query_one("SELECT count(*) FROM albums", &[]).await?.get(0);
    Ok(Json(serde_json::json!({
        "total": r.get::<_, i64>(0),
        "videos": r.get::<_, i64>(1),
        "bytes": r.get::<_, i64>(2),
        "oldest": r.get::<_, Option<DateTime<Utc>>>(3),
        "newest": r.get::<_, Option<DateTime<Utc>>>(4),
        "albums": albums,
    })))
}

async fn summary(State(app): State<App>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!(
                "SELECT to_char(taken_at AT TIME ZONE 'UTC', 'YYYY-MM') AS m, count(*)
                 FROM assets WHERE taken_at IS NOT NULL {EXCLUDE_HIDDEN}
                 GROUP BY 1 ORDER BY 1 DESC"
            ),
            &[],
        )
        .await?;
    let months: Vec<_> = rows
        .iter()
        .map(|r| serde_json::json!({"month": r.get::<_, String>(0), "count": r.get::<_, i64>(1)}))
        .collect();
    Ok(Json(serde_json::json!({ "months": months })))
}

#[derive(Deserialize)]
struct TimelineQ {
    before: Option<DateTime<Utc>>,
    limit: Option<i64>,
}

async fn timeline(State(app): State<App>, Query(q): Query<TimelineQ>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let limit = q.limit.unwrap_or(200).clamp(1, 500);
    let rows = match q.before {
        Some(b) => {
            c.query(
                &format!(
                    "SELECT {ASSET_COLS} FROM assets WHERE taken_at IS NOT NULL AND taken_at < $1
                     {EXCLUDE_HIDDEN} ORDER BY taken_at DESC LIMIT $2"
                ),
                &[&b, &limit],
            )
            .await?
        }
        None => {
            c.query(
                &format!(
                    "SELECT {ASSET_COLS} FROM assets WHERE taken_at IS NOT NULL
                     {EXCLUDE_HIDDEN} ORDER BY taken_at DESC LIMIT $1"
                ),
                &[&limit],
            )
            .await?
        }
    };
    let items: Vec<Asset> = rows.iter().map(asset_from).collect();
    Ok(Json(serde_json::json!({ "items": items })))
}

async fn albums(State(app): State<App>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            "SELECT a.id, a.title, count(aa.asset_id),
                    (SELECT s.id FROM album_assets x JOIN assets s ON s.id = x.asset_id
                     WHERE x.album_id = a.id ORDER BY s.taken_at DESC NULLS LAST LIMIT 1)
             FROM albums a LEFT JOIN album_assets aa ON aa.album_id = a.id
             GROUP BY a.id, a.title ORDER BY max(
                (SELECT s.taken_at FROM assets s WHERE s.id = aa.asset_id)
             ) DESC NULLS LAST",
            &[],
        )
        .await?;
    let list: Vec<_> = rows
        .iter()
        .map(|r| {
            serde_json::json!({
                "id": r.get::<_, i64>(0), "title": r.get::<_, String>(1),
                "count": r.get::<_, i64>(2), "cover": r.get::<_, Option<String>>(3),
            })
        })
        .collect();
    Ok(Json(serde_json::json!({ "albums": list })))
}

async fn album_assets(State(app): State<App>, Path(id): Path<i64>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!(
                "SELECT {ASSET_COLS} FROM assets
                 JOIN album_assets aa ON aa.asset_id = assets.id
                 WHERE aa.album_id = $1 ORDER BY taken_at DESC NULLS LAST LIMIT 2000"
            ),
            &[&id],
        )
        .await?;
    let items: Vec<Asset> = rows.iter().map(asset_from).collect();
    Ok(Json(serde_json::json!({ "items": items })))
}

#[derive(Deserialize)]
struct SearchQ {
    q: String,
}

async fn search(State(app): State<App>, Query(s): Query<SearchQ>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let term = s.q.trim().to_string();
    if term.is_empty() {
        return Ok(Json(serde_json::json!({ "items": [] })));
    }
    let like = format!("%{term}%");
    // v1: names, descriptions, album titles, plain years — CLIP comes later
    let rows = c
        .query(
            &format!(
                "SELECT DISTINCT {ASSET_COLS} FROM assets
                 LEFT JOIN album_assets aa ON aa.asset_id = assets.id
                 LEFT JOIN albums al ON al.id = aa.album_id
                 WHERE (assets.orig_name ILIKE $1
                    OR assets.description ILIKE $1
                    OR al.title ILIKE $1
                    OR to_char(assets.taken_at, 'YYYY') = $2)
                 {EXCLUDE_HIDDEN}
                 ORDER BY taken_at DESC NULLS LAST LIMIT 600"
            ),
            &[&like, &term],
        )
        .await?;
    let items: Vec<Asset> = rows.iter().map(asset_from).collect();
    Ok(Json(serde_json::json!({ "items": items })))
}

// ------------------------------------------------------------------ files ---

async fn thumb(
    State(app): State<App>,
    Path((id, size)): Path<(String, String)>,
    headers: HeaderMap,
) -> Response {
    if !safe_id(&id) || !matches!(size.as_str(), "256" | "1024") {
        return StatusCode::NOT_FOUND.into_response();
    }
    let path = app.photos_dir.join("thumbs").join(format!("{id}.{size}.webp"));
    serve_immutable(path, headers).await
}

async fn asset_path(app: &App, id: &str) -> Option<PathBuf> {
    if !safe_id(id) {
        return None;
    }
    let c = app.pool.get().await.ok()?;
    let row = c
        .query_opt("SELECT orig_path FROM assets WHERE id = $1", &[&id])
        .await
        .ok()??;
    Some(PathBuf::from(row.get::<_, String>(0)))
}

async fn original(State(app): State<App>, Path(id): Path<String>, headers: HeaderMap) -> Response {
    match asset_path(&app, &id).await {
        Some(p) => serve_immutable(p, headers).await,
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn stream(State(app): State<App>, Path(id): Path<String>, headers: HeaderMap) -> Response {
    original(State(app), Path(id), headers).await
}

fn safe_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_hexdigit())
}

/// ServeFile handles Range requests (AVPlayer) + content types; we add the
/// immutable cache header — content-addressed URLs never change.
async fn serve_immutable(path: PathBuf, headers: HeaderMap) -> Response {
    let mut req = axum::http::Request::new(axum::body::Body::empty());
    *req.headers_mut() = headers;
    match ServeFile::new(path).oneshot(req).await {
        Ok(mut resp) => {
            resp.headers_mut().insert(
                header::CACHE_CONTROL,
                HeaderValue::from_static("public, max-age=31536000, immutable"),
            );
            resp.into_response()
        }
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

// ------------------------------------------------------------------ error ---

struct Api(String);

impl<E: std::fmt::Display> From<E> for Api {
    fn from(e: E) -> Self {
        Api(e.to_string())
    }
}

impl IntoResponse for Api {
    fn into_response(self) -> Response {
        (StatusCode::INTERNAL_SERVER_ERROR, self.0).into_response()
    }
}
