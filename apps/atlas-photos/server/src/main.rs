//! atlas-photos — timeline / thumbs / originals / video streaming, plus
//! search, persons, albums, state mutations and iPhone upload. The full route
//! table lives in `main()`; a few of the read endpoints:
//!
//!   GET /api/stats                       library totals (for the account sheet)
//!   GET /api/timeline/summary            [{month:"2024-07", count}]
//!   GET /api/timeline?before=&limit=     newest-first cursor pages
//!   GET /api/albums                      [{id, title, count, cover}]
//!   GET /api/albums/:id/assets
//!   GET /api/search?q=                   persons + places + tags + filename +
//!                                        year, with Qwen3-VL semantic fill-in
//!   GET /api/assets/:id/thumb/512|2048   WebP, Cache-Control: immutable
//!   GET /api/assets/:id/original
//!   GET /api/assets/:id/stream           Range streaming (AVPlayer)

mod countries;
mod drive;

use std::path::PathBuf;

use axum::{
    body::Bytes,
    extract::{DefaultBodyLimit, Path, Query, Request, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use deadpool_postgres::{Config as PgConfig, Pool, Runtime};
use serde::{Deserialize, Serialize};
use tower::ServiceExt;
use tower_http::services::ServeFile;

#[derive(Clone)]
pub(crate) struct App {
    pub(crate) pool: Pool,
    photos_dir: PathBuf,
    pub(crate) drive_dir: PathBuf,
    /// ATLAS_PHOTOS_TOKEN — when set, every route (except /health) requires it.
    token: Option<String>,
}

#[tokio::main]
async fn main() {
    let home = std::env::var("HOME").expect("HOME must be set");
    // PHOTOS_DIR / DRIVE_DIR: library roots (default $HOME/photos, $HOME/drive)
    let photos_dir = PathBuf::from(std::env::var("PHOTOS_DIR").unwrap_or(format!("{home}/photos")));
    let drive_dir = PathBuf::from(std::env::var("DRIVE_DIR").unwrap_or(format!("{home}/drive")));
    // POSTGRES_PASSWORD directly from the environment, or parsed from the
    // PG_ENV_FILE secrets file (default: $HOME/atlas/backend/docker/.env,
    // the backend compose secrets file — same convention as pipeline/db.py).
    let password = std::env::var("POSTGRES_PASSWORD")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            let env_file = std::env::var("PG_ENV_FILE")
                .unwrap_or(format!("{home}/atlas/backend/docker/.env"));
            std::fs::read_to_string(&env_file)
                .ok()
                .and_then(|s| {
                    s.lines()
                        .find_map(|l| l.strip_prefix("POSTGRES_PASSWORD=").map(str::to_string))
                })
                .unwrap_or_else(|| {
                    panic!("set POSTGRES_PASSWORD (or a POSTGRES_PASSWORD= line in {env_file})")
                })
        });

    // PGHOST / PGPORT / PGDATABASE / PGUSER, mirroring pipeline/db.py
    let mut cfg = PgConfig::new();
    cfg.host = Some(std::env::var("PGHOST").unwrap_or_else(|_| "127.0.0.1".into()));
    cfg.port = std::env::var("PGPORT").ok().and_then(|p| p.parse().ok());
    cfg.dbname = Some(std::env::var("PGDATABASE").unwrap_or_else(|_| "atlas".into()));
    cfg.user = Some(std::env::var("PGUSER").unwrap_or_else(|_| "atlas".into()));
    cfg.password = Some(password);
    let pool = cfg
        .create_pool(Some(Runtime::Tokio1), tokio_postgres::NoTls)
        .expect("pg pool");

    // ATLAS_PHOTOS_TOKEN: optional bearer token. When set, ALL routes except
    // /health require "Authorization: Bearer <token>" or a ?token=<token>
    // query parameter (for direct media URLs). Unset = open access — only
    // acceptable on a private, trusted network (e.g. a tailnet).
    let token = std::env::var("ATLAS_PHOTOS_TOKEN").ok().filter(|t| !t.is_empty());
    if token.is_none() {
        println!("WARNING: ATLAS_PHOTOS_TOKEN not set — API is unauthenticated (tailnet-only mode)");
    }

    // ATLAS_PHOTOS_MAX_UPLOAD: upload body cap in MiB (default 512). Upload
    // bodies are fully buffered in RAM, so keep this within what the box can spare.
    let max_upload: usize = std::env::var("ATLAS_PHOTOS_MAX_UPLOAD")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(512)
        * 1024
        * 1024;

    let app = App { pool, photos_dir, drive_dir, token };
    let router = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/api/stats", get(stats))
        .route("/api/heatmap", get(heatmap))
        .route("/api/timeline/summary", get(summary))
        .route("/api/timeline", get(timeline))
        .route("/api/albums", get(albums))
        .route("/api/albums/{id}/assets", get(album_assets))
        .route("/api/search", get(search))
        .route("/api/assets/{id}/thumb/{size}", get(thumb))
        .route("/api/assets/{id}/original", get(original))
        .route("/api/assets/{id}/stream", get(stream))
        .route("/api/assets/{id}/info", get(asset_info))
        // experimental: UMAP vector map (static bundle under photos/vecmap)
        .route("/map", get(map_index))
        .route("/map/{*path}", get(map_asset))
        .route("/api/persons", get(persons))
        .route("/api/persons/{id}/assets", get(person_assets))
        .route("/api/persons/{id}/rename", post(person_rename))
        .route("/api/persons/{id}/cover", post(person_cover))
        .route("/api/assets/{id}/faces", get(asset_faces))
        .route("/api/faces/{id}/crop", get(face_crop))
        // archived / trashed / locked buckets (same asset JSON shape as timeline)
        .route("/api/archive", get(archive))
        .route("/api/trash", get(trash_list))
        .route("/api/locked", get(locked))
        // batch state mutations — JSON body {ids:[...] (,value:bool)}
        .route("/api/mutate/favorite", post(mutate_favorite))
        .route("/api/mutate/archive", post(mutate_archive))
        .route("/api/mutate/trash", post(mutate_trash))
        .route("/api/mutate/restore", post(mutate_restore))
        .route("/api/mutate/lock", post(mutate_lock))
        .route("/api/mutate/delete", post(mutate_delete))
        .route("/api/trash/empty", post(trash_empty))
        // sync / upload
        .route("/api/exists", post(exists))
        .route(
            "/api/upload",
            post(upload).layer(DefaultBodyLimit::max(max_upload)),
        )
        // drive — the "Dateien" domain (folder tree + content-addressed blobs)
        .route("/api/drive/list", get(drive::list))
        .route("/api/drive/recent", get(drive::recent))
        .route("/api/drive/search", get(drive::search))
        .route("/api/drive/stats", get(drive::stats))
        .route("/api/drive/blob/{hash}/{name}", get(drive::blob))
        .route(
            "/api/drive/upload",
            post(drive::upload).layer(DefaultBodyLimit::max(max_upload)),
        )
        .route("/api/drive/folders", post(drive::folder_create))
        .route("/api/drive/folders/{id}/rename", post(drive::folder_rename))
        .route("/api/drive/folders/{id}/delete", post(drive::folder_delete))
        .route("/api/drive/files/{id}/rename", post(drive::file_rename))
        .route("/api/drive/move", post(drive::mv))
        .route("/api/drive/trash", get(drive::trash_list).post(drive::trash_put))
        .route("/api/drive/restore", post(drive::restore))
        .route("/api/drive/delete", post(drive::delete))
        .route("/api/drive/trash/empty", post(drive::trash_empty))
        .with_state(app.clone())
        .layer(middleware::from_fn_with_state(app, require_token));

    // ATLAS_PHOTOS_BIND: listen address (default 0.0.0.0:8788). Without
    // ATLAS_PHOTOS_TOKEN there is NO auth — expose only on a trusted network
    // (tailnet) or bind 127.0.0.1 behind an authenticating reverse proxy.
    let addr = std::env::var("ATLAS_PHOTOS_BIND").unwrap_or_else(|_| "0.0.0.0:8788".into());
    println!("atlas-photos on {addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, router).await.unwrap();
}

// ------------------------------------------------------------------- auth ---

/// Constant-time byte comparison so the token can't be guessed via timing.
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// If ATLAS_PHOTOS_TOKEN is set, require "Authorization: Bearer <token>" or
/// ?token=<token> (URL-safe tokens only) on every route except /health.
/// Unset token = fully open (documented tailnet-only mode).
async fn require_token(State(app): State<App>, req: Request, next: Next) -> Response {
    let Some(expected) = app.token.as_deref() else {
        return next.run(req).await;
    };
    if req.uri().path() == "/health" {
        return next.run(req).await;
    }
    let header_ok = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|t| ct_eq(t.trim().as_bytes(), expected.as_bytes()))
        .unwrap_or(false);
    let query_ok = header_ok
        || req
            .uri()
            .query()
            .map(|q| {
                q.split('&')
                    .filter_map(|kv| kv.strip_prefix("token="))
                    .any(|t| ct_eq(t.as_bytes(), expected.as_bytes()))
            })
            .unwrap_or(false);
    if header_ok || query_ok {
        next.run(req).await
    } else {
        (StatusCode::UNAUTHORIZED, "unauthorized").into_response()
    }
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
    favorite: bool,
}

fn asset_from(r: &tokio_postgres::Row) -> Asset {
    Asset {
        id: r.get(0),
        kind: r.get(1),
        taken_at: r.get(2),
        width: r.get(3),
        height: r.get(4),
        duration_s: r.get(5),
        favorite: r.get(6),
    }
}

const ASSET_COLS: &str =
    "assets.id, assets.type, assets.taken_at, assets.width, assets.height, assets.duration_s, assets.favorite";

// archived / trashed / locked assets each live in their own view
// (/api/archive, /api/trash, /api/locked) and stay out of the main timeline,
// search, summary and stats. Column filter over the partial index (002) instead
// of the old album anti-join. Columns are qualified so the search join is
// unambiguous (albums also has an `id`).
const VISIBLE: &str =
    "AND NOT assets.archived AND assets.trashed_at IS NULL AND NOT assets.locked";

async fn stats(State(app): State<App>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let r = c
        .query_one(
            "SELECT count(*),
                    count(*) FILTER (WHERE type='video'),
                    coalesce(sum(size_bytes),0)::bigint,
                    min(taken_at), max(taken_at)
             FROM assets
             WHERE NOT archived AND trashed_at IS NULL AND NOT locked",
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
                 FROM assets WHERE taken_at IS NOT NULL {VISIBLE}
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
    // high cap so the app can bulk-load the whole (lightweight) timeline once —
    // the scrubber needs every section present for a stable, full-range scale
    let limit = q.limit.unwrap_or(200).clamp(1, 100_000);
    let rows = match q.before {
        Some(b) => {
            c.query(
                &format!(
                    "SELECT {ASSET_COLS} FROM assets WHERE taken_at IS NOT NULL AND taken_at < $1
                     {VISIBLE} ORDER BY taken_at DESC LIMIT $2"
                ),
                &[&b, &limit],
            )
            .await?
        }
        None => {
            c.query(
                &format!(
                    "SELECT {ASSET_COLS} FROM assets WHERE taken_at IS NOT NULL
                     {VISIBLE} ORDER BY taken_at DESC LIMIT $1"
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

/// GitHub-style Aktivitäts-Heatmap: Foto-Anzahl pro Tag, letzte ~53 Wochen.
async fn heatmap(State(app): State<App>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            "SELECT to_char(taken_at::date, 'YYYY-MM-DD') AS d, count(*)::int AS n
             FROM assets
             WHERE taken_at IS NOT NULL
               AND taken_at > now() - interval '372 days'
               AND NOT archived AND trashed_at IS NULL AND NOT locked
             GROUP BY 1 ORDER BY 1",
            &[],
        )
        .await?;
    let items: Vec<_> = rows
        .iter()
        .map(|r| serde_json::json!({ "d": r.get::<_, String>(0), "n": r.get::<_, i32>(1) }))
        .collect();
    Ok(Json(serde_json::json!({ "items": items })))
}

#[derive(Deserialize)]
struct SearchQ {
    q: String,
}

/// Escape LIKE metacharacters so user input can't act as a pattern.
pub(crate) fn like_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
}


/// POST to the local Qwen3-VL-Embedding text-embedding sidecar (embed-api).
/// ATLAS_EMBED_API_ADDR: sidecar host:port (default 127.0.0.1:8093, matching
/// embed_api.py's EMBED_API_PORT). Any failure — sidecar down, timeout, bad
/// JSON — degrades to None and the search falls back to structured-only results.
async fn text_embedding(q: &str) -> Option<Vec<f32>> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let addr =
        std::env::var("ATLAS_EMBED_API_ADDR").unwrap_or_else(|_| "127.0.0.1:8093".into());
    let body = serde_json::json!({ "text": q }).to_string();
    let req = format!(
        "POST /embed HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n{}",
        addr,
        body.len(),
        body
    );
    let fut = async {
        let mut s = tokio::net::TcpStream::connect(addr.as_str()).await.ok()?;
        s.write_all(req.as_bytes()).await.ok()?;
        let mut buf = Vec::new();
        s.read_to_end(&mut buf).await.ok()?;
        let text = String::from_utf8_lossy(&buf);
        let json = &text[text.find("\r\n\r\n")? + 4..];
        let v: serde_json::Value = serde_json::from_str(json.trim()).ok()?;
        v.get("vec")?
            .as_array()?
            .iter()
            .map(|x| x.as_f64().map(|f| f as f32))
            .collect::<Option<Vec<f32>>>()
    };
    // Qwen3-VL-Embedding-2B runs CPU-only in the sidecar: ~1-3 s per query, and
    // slower while the GPU re-embed pipeline is hammering the box. 6 s ceiling so
    // a real query never gets cut off; a wedged sidecar still degrades cleanly.
    match tokio::time::timeout(std::time::Duration::from_millis(6000), fut).await {
        Ok(Some(v)) if v.len() == 2048 => Some(v),
        _ => None,
    }
}

/// Unified search: person names, places (incl. "Kroatien" -> cc), tags,
/// captions, albums, filenames, years — plus Qwen3-VL semantic ranking when
/// the structured hits are thin. Response keeps the v1 `items` key and adds
/// `persons` chips.
async fn search(State(app): State<App>, Query(s): Query<SearchQ>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let term = s.q.trim().to_string();
    if term.is_empty() {
        return Ok(Json(serde_json::json!({ "items": [], "persons": [] })));
    }
    let like = format!("%{}%", like_escape(&term));
    let tag_prefix = format!("{}%", like_escape(&term));
    let cc = countries::country_code(&term);

    // 1) matching persons (chips + their photos rank first)
    let prows = c
        .query(
            "SELECT p.id, p.display_name, p.cover_face_id,
                    count(DISTINCT f.asset_id) AS photos
             FROM persons p
             JOIN faces f ON f.person_id = p.id
             WHERE p.merged_into IS NULL AND p.display_name ILIKE $1
             GROUP BY p.id, p.display_name, p.cover_face_id
             ORDER BY photos DESC LIMIT 6",
            &[&like],
        )
        .await?;
    let person_ids: Vec<i64> = prows.iter().map(|r| r.get(0)).collect();
    let persons: Vec<_> = prows
        .iter()
        .map(|r| {
            serde_json::json!({
                "id": r.get::<_, i64>(0),
                "name": r.get::<_, Option<String>>(1),
                "cover_face": r.get::<_, Option<i64>>(2),
                "photos": r.get::<_, i64>(3),
            })
        })
        .collect();

    // 2) structured hits, ranked: person > place > tag > caption/album/name/year
    let rows = c
        .query(
            &format!(
                "WITH hits AS (
                     SELECT f.asset_id AS id, 0 AS prio
                     FROM faces f WHERE f.person_id = ANY($3)
                   UNION
                     SELECT e.src_id, 1
                     FROM edges e JOIN places p ON p.id::text = e.dst_id
                     WHERE e.rel = 'taken_at' AND e.dst_type = 'place'
                       AND (p.name ILIKE $1 OR p.admin1 ILIKE $1
                            OR ($4::text IS NOT NULL AND p.cc = $4))
                   UNION
                     SELECT t.asset_id, 2 FROM tags t WHERE t.tag ILIKE $2
                   UNION
                     SELECT a2.id, 3
                     FROM assets a2
                     LEFT JOIN album_assets aa ON aa.asset_id = a2.id
                     LEFT JOIN albums al ON al.id = aa.album_id
                     WHERE a2.orig_name ILIKE $1
                        OR al.title ILIKE $1 OR to_char(a2.taken_at, 'YYYY') = $5
                 )
                 SELECT {ASSET_COLS}, min(h.prio) AS prio
                 FROM assets JOIN hits h ON h.id = assets.id
                 WHERE true {VISIBLE}
                 GROUP BY assets.id
                 ORDER BY min(h.prio), assets.taken_at DESC NULLS LAST
                 LIMIT 600"
            ),
            &[&like, &tag_prefix, &person_ids, &cc, &term],
        )
        .await?;
    let mut items: Vec<Asset> = rows.iter().map(asset_from).collect();

    // 3) semantic search via Qwen3-VL-Embedding — runs for any query that isn't
    //    already a huge exact-match set, and contributes GENEROUSLY: a content
    //    query like "disco" should surface every photo AND video that looks the
    //    part, not just the few that happen to carry the tag. Structured hits
    //    still rank first; semantic (photos + videos, same vector space) fills in.
    //
    //    Zero-loss retrieval: an EXACT full-precision float32 cosine scan over
    //    every qwen3vl vector — no ANN index, no approximation. At this library
    //    size (~27k × 2048-dim) the exact scan is a few tens of ms, utterly
    //    dwarfed by the 1-3 s CPU query embedding, so an HNSW index would buy
    //    nothing but a recall gap. The ranking you see is bit-exact.
    if items.len() < 150 {
        if let Some(vec) = text_embedding(&term).await {
            let vstr = format!(
                "[{}]",
                vec.iter().map(|f| f.to_string()).collect::<Vec<_>>().join(",")
            );
            let srows = c
                .query(
                    &format!(
                        "SELECT {ASSET_COLS}, (e.vec <=> $1::text::vector) AS dist
                         FROM embeddings e JOIN assets ON assets.id = e.owner_id
                         WHERE e.model = 'qwen3vl' {VISIBLE}
                         ORDER BY e.vec <=> $1::text::vector
                         LIMIT 200",
                    ),
                    &[&vstr],
                )
                .await?;
            if let Some(best) = srows.first().map(|r| r.get::<_, f64>(r.len() - 1)) {
                // relative window off the best hit — keeps results that sit
                // within a cosine-distance margin of the top match. Starting
                // point for Qwen's distribution; tune against real queries
                // ("Hund", "disco") once the re-embed completes.
                let cutoff = best + 0.25;
                let mut added = 0;
                let seen: std::collections::HashSet<String> =
                    items.iter().map(|a| a.id.clone()).collect();
                for r in &srows {
                    let dist: f64 = r.get(r.len() - 1);
                    if dist > cutoff || added >= 140 {
                        break;
                    }
                    let a = asset_from(r);
                    if !seen.contains(&a.id) {
                        items.push(a);
                        added += 1;
                    }
                }
            }
        }
    }

    Ok(Json(serde_json::json!({ "items": items, "persons": persons })))
}

// ----------------------------------------------------- archive/trash/lock ---

// Buckets are mutually exclusive: trash wins over everything, archive excludes
// locked, locked excludes trashed. Same asset JSON shape as the timeline.
async fn archive(State(app): State<App>) -> Result<Json<serde_json::Value>, Api> {
    list_where(&app, "archived AND trashed_at IS NULL AND NOT locked", "taken_at DESC NULLS LAST").await
}

async fn trash_list(State(app): State<App>) -> Result<Json<serde_json::Value>, Api> {
    list_where(&app, "trashed_at IS NOT NULL", "trashed_at DESC").await
}

async fn locked(State(app): State<App>) -> Result<Json<serde_json::Value>, Api> {
    list_where(&app, "locked AND trashed_at IS NULL", "taken_at DESC NULLS LAST").await
}

/// `pred` / `order` are server-controlled constants (never user input).
async fn list_where(app: &App, pred: &str, order: &str) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!("SELECT {ASSET_COLS} FROM assets WHERE {pred} ORDER BY {order} LIMIT 5000"),
            &[],
        )
        .await?;
    let items: Vec<Asset> = rows.iter().map(asset_from).collect();
    Ok(Json(serde_json::json!({ "items": items })))
}

// --------------------------------------------------------------- mutations ---

#[derive(Deserialize)]
struct Ids {
    ids: Vec<String>,
}

#[derive(Deserialize)]
struct IdsVal {
    ids: Vec<String>,
    value: bool,
}

async fn mutate_favorite(State(app): State<App>, Json(b): Json<IdsVal>) -> Result<Json<serde_json::Value>, Api> {
    set_bool(&app, "favorite", &b.ids, b.value).await
}

async fn mutate_archive(State(app): State<App>, Json(b): Json<IdsVal>) -> Result<Json<serde_json::Value>, Api> {
    set_bool(&app, "archived", &b.ids, b.value).await
}

async fn mutate_lock(State(app): State<App>, Json(b): Json<IdsVal>) -> Result<Json<serde_json::Value>, Api> {
    set_bool(&app, "locked", &b.ids, b.value).await
}

/// `col` is a server-controlled column name (never user input).
async fn set_bool(app: &App, col: &str, ids: &Vec<String>, value: bool) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let n = c
        .execute(&format!("UPDATE assets SET {col} = $2 WHERE id = ANY($1)"), &[ids, &value])
        .await?;
    Ok(Json(serde_json::json!({ "updated": n })))
}

/// Full per-asset detail for the viewer info sheet: metadata + place (via the
/// geocode edge) + pipeline tags + the EXIF subset stored by the meta worker.
async fn asset_info(State(app): State<App>, Path(id): Path<String>) -> Result<Response, Api> {
    if !safe_id(&id) {
        return Ok(StatusCode::BAD_REQUEST.into_response());
    }
    let c = app.pool.get().await?;
    let Some(r) = c
        .query_opt(
            "SELECT id, taken_at, orig_name, camera, width, height, size_bytes,
                    lat, lon, favorite, duration_s, exif
             FROM assets WHERE id = $1",
            &[&id],
        )
        .await?
    else {
        return Ok(StatusCode::NOT_FOUND.into_response());
    };
    let place: Option<String> = c
        .query_opt(
            "SELECT p.name || COALESCE(', ' || p.admin1, '')
             FROM edges e JOIN places p ON p.id::text = e.dst_id
             WHERE e.src_type='asset' AND e.src_id=$1
               AND e.rel='taken_at' AND e.dst_type='place'
             LIMIT 1",
            &[&id],
        )
        .await?
        .map(|row| row.get(0));
    let tags: Vec<String> = c
        .query("SELECT tag FROM tags WHERE asset_id = $1 ORDER BY tag", &[&id])
        .await?
        .iter()
        .map(|row| row.get(0))
        .collect();
    let exif: Option<serde_json::Value> = r.get(11);
    Ok(Json(serde_json::json!({
        "id": r.get::<_, String>(0),
        "taken_at": r.get::<_, Option<DateTime<Utc>>>(1),
        "orig_name": r.get::<_, Option<String>>(2),
        "camera": r.get::<_, Option<String>>(3),
        "width": r.get::<_, Option<i32>>(4),
        "height": r.get::<_, Option<i32>>(5),
        "size_bytes": r.get::<_, Option<i64>>(6),
        "lat": r.get::<_, Option<f64>>(7),
        "lon": r.get::<_, Option<f64>>(8),
        "favorite": r.get::<_, bool>(9),
        "duration_s": r.get::<_, Option<f64>>(10),
        "place": place,
        "tags": tags,
        "exif": exif,
    }))
    .into_response())
}

async fn mutate_trash(State(app): State<App>, Json(b): Json<Ids>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let n = c
        .execute("UPDATE assets SET trashed_at = now() WHERE id = ANY($1)", &[&b.ids])
        .await?;
    Ok(Json(serde_json::json!({ "updated": n })))
}

async fn mutate_restore(State(app): State<App>, Json(b): Json<Ids>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let n = c
        .execute(
            "UPDATE assets SET archived = false, trashed_at = NULL, locked = false WHERE id = ANY($1)",
            &[&b.ids],
        )
        .await?;
    Ok(Json(serde_json::json!({ "updated": n })))
}

async fn mutate_delete(State(app): State<App>, Json(b): Json<Ids>) -> Result<Json<serde_json::Value>, Api> {
    let n = purge(&app, &b.ids).await?;
    Ok(Json(serde_json::json!({ "deleted": n })))
}

async fn trash_empty(State(app): State<App>) -> Result<Json<serde_json::Value>, Api> {
    let ids: Vec<String> = {
        let c = app.pool.get().await?;
        c.query("SELECT id FROM assets WHERE trashed_at IS NOT NULL", &[])
            .await?
            .iter()
            .map(|r| r.get(0))
            .collect()
    };
    let n = purge(&app, &ids).await?;
    Ok(Json(serde_json::json!({ "deleted": n })))
}

/// PERMANENT: deletes DB rows + original files + both thumbs. File removal is
/// best-effort (a missing file is not an error). Child rows are cleaned first so
/// this works whether or not the FKs are ON DELETE CASCADE.
async fn purge(app: &App, ids: &Vec<String>) -> Result<u64, Api> {
    if ids.is_empty() {
        return Ok(0);
    }
    let c = app.pool.get().await?;
    let rows = c
        .query("SELECT id, orig_path FROM assets WHERE id = ANY($1)", &[ids])
        .await?;
    let thumbs = app.photos_dir.join("thumbs");
    for r in &rows {
        let id: String = r.get(0);
        let orig: String = r.get(1);
        // defense in depth: only ever delete files inside the photos root
        match confine(&app.photos_dir, std::path::Path::new(&orig)).await {
            Some(p) => {
                let _ = tokio::fs::remove_file(&p).await;
            }
            None => eprintln!("purge: skipping missing or outside-root path: {orig}"),
        }
        let _ = tokio::fs::remove_file(thumbs.join(format!("{id}.512.webp"))).await;
        let _ = tokio::fs::remove_file(thumbs.join(format!("{id}.2048.webp"))).await;
    }
    // Clean EVERY child row. embeddings/tags/edges are keyed off the asset the
    // same way faces/album_assets are — miss any and, because ids are content-
    // addressed SHA256, re-uploading identical bytes silently re-attaches the
    // stale rows to the "new" asset. embeddings especially: leftover vectors
    // stay in the exact-scan search space forever. Errors are logged, not
    // swallowed, so a schema drift like this surfaces instead of leaking.
    for stmt in [
        "DELETE FROM album_assets WHERE asset_id = ANY($1)",
        "DELETE FROM faces WHERE asset_id = ANY($1)",
        "DELETE FROM tags WHERE asset_id = ANY($1)",
        "DELETE FROM edges WHERE src_type = 'asset' AND src_id = ANY($1)",
        "DELETE FROM embeddings WHERE owner_type = 'asset' AND owner_id = ANY($1)",
        "DELETE FROM ingest_jobs WHERE owner_type = 'asset' AND owner_id = ANY($1)",
    ] {
        if let Err(e) = c.execute(stmt, &[ids]).await {
            eprintln!("purge: child cleanup failed [{stmt}]: {e}");
        }
    }
    let n = c.execute("DELETE FROM assets WHERE id = ANY($1)", &[ids]).await?;
    Ok(n)
}

// ------------------------------------------------------------ upload / sync ---

#[derive(Deserialize)]
struct Hashes {
    hashes: Vec<String>,
}

/// Which of the given content hashes the library already has (client dedup).
async fn exists(State(app): State<App>, Json(b): Json<Hashes>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let rows = c
        .query("SELECT id FROM assets WHERE id = ANY($1)", &[&b.hashes])
        .await?;
    let have: Vec<String> = rows.iter().map(|r| r.get(0)).collect();
    Ok(Json(serde_json::json!({ "have": have })))
}

const VIDEO_EXTS: &[&str] = &["mp4", "mov", "m4v", "3gp", "avi", "mkv", "webm", "mts"];
const IMAGE_EXTS: &[&str] =
    &["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tif", "tiff", "dng", "avif"];

/// Extension actually stored on disk for uploads: lowercase alnum, <= 5 chars
/// AND on the known media whitelist — anything else becomes "bin" so a client
/// can't plant script-capable files (.html/.svg) that ServeFile would later
/// serve with an active Content-Type.
fn safe_ext(name: &str) -> &'static str {
    let ext = std::path::Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if ext.len() <= 5 && ext.chars().all(|c| c.is_ascii_alphanumeric()) {
        for w in IMAGE_EXTS.iter().chain(VIDEO_EXTS) {
            if *w == ext {
                return w;
            }
        }
    }
    "bin"
}

/// Raw-body upload. The asset id is the SHA256 of the exact received bytes,
/// computed HERE by the server — never taken from the client. This is what
/// makes dedup work across paths: the Takeout ingest and this upload hash the
/// same bytes with the same function, so identical content always collapses to
/// one id (ON CONFLICT DO NOTHING). The optional X-Content-Hash header is only
/// an integrity check (reject on mismatch). Headers: X-Content-Hash (optional
/// SHA256 for verification), X-Filename (original name), X-Taken-At (unix
/// seconds, optional). Stores bytes at originals/YYYY/MM/<id>_<name>, enqueues a
/// 'thumb' ingest job, source='iphone'. Known content -> {"exists":true}.
async fn upload(State(app): State<App>, headers: HeaderMap, body: Bytes) -> Result<Response, Api> {
    let id = sha256_hex(&body);
    // Optional integrity check: if the client sent a hash, it must match ours.
    if let Some(h) = headers.get("x-content-hash").and_then(|v| v.to_str().ok()) {
        let claimed = h.trim().to_ascii_lowercase();
        if !claimed.is_empty() && claimed != id {
            return Ok((StatusCode::BAD_REQUEST, "X-Content-Hash mismatch").into_response());
        }
    }

    let c = app.pool.get().await?;
    if c.query_opt("SELECT 1 FROM assets WHERE id = $1", &[&id]).await?.is_some() {
        return Ok(Json(serde_json::json!({ "exists": true, "id": id })).into_response());
    }

    let name = headers
        .get("x-filename")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.rsplit(['/', '\\']).next())
        .filter(|s| !s.is_empty())
        .unwrap_or("upload")
        .to_string();

    let taken: Option<DateTime<Utc>> = headers
        .get("x-taken-at")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.trim().parse::<i64>().ok())
        .and_then(|secs| DateTime::<Utc>::from_timestamp(secs, 0));

    let sub = taken
        .map(|t| t.format("%Y/%m").to_string())
        .unwrap_or_else(|| "0000/00".into());
    let dir = app.photos_dir.join("originals").join(sub);
    tokio::fs::create_dir_all(&dir).await?;
    // stored name is fully server-controlled: content id + whitelisted extension
    let ext = safe_ext(&name);
    let dest = dir.join(format!("{id}.{ext}"));
    tokio::fs::write(&dest, &body).await?;

    let kind = if VIDEO_EXTS.contains(&ext) { "video" } else { "photo" };
    let dest_str = dest.to_string_lossy().to_string();
    let size = body.len() as i64;

    c.execute(
        "INSERT INTO assets (id, type, taken_at, orig_path, orig_name, size_bytes, source)
         VALUES ($1, $2, $3, $4, $5, $6, 'iphone') ON CONFLICT (id) DO NOTHING",
        &[&id, &kind, &taken, &dest_str, &name, &size],
    )
    .await?;
    // fresh uploads jump the queue: thumb first (grid shows something within
    // ~a second even mid-backfill), then meta; the AI stages keep default 100
    c.execute(
        "INSERT INTO ingest_jobs (kind, owner_type, owner_id, priority)
         VALUES ('thumb', 'asset', $1, 10) ON CONFLICT DO NOTHING",
        &[&id],
    )
    .await?;
    c.execute(
        "INSERT INTO ingest_jobs (kind, owner_type, owner_id, priority)
         VALUES ('meta', 'asset', $1, 20) ON CONFLICT DO NOTHING",
        &[&id],
    )
    .await?;
    for job in ["embed", "faces", "caption"] {
        c.execute(
            "INSERT INTO ingest_jobs (kind, owner_type, owner_id)
             VALUES ($1, 'asset', $2) ON CONFLICT DO NOTHING",
            &[&job, &id],
        )
        .await?;
    }

    Ok(Json(serde_json::json!({ "exists": false, "id": id })).into_response())
}

// ------------------------------------------------------------------ files ---

async fn thumb(
    State(app): State<App>,
    Path((id, size)): Path<(String, String)>,
    headers: HeaderMap,
) -> Response {
    if !safe_id(&id) || !matches!(size.as_str(), "512" | "2048") {
        return StatusCode::NOT_FOUND.into_response();
    }
    let path = app.photos_dir.join("thumbs").join(format!("{id}.{size}.webp"));
    serve_immutable(path, headers).await
}

// ---------------------------------------------------------------- persons ---

/// People with at least one face, biggest first. cover_face -> /api/faces/{id}/crop.
async fn persons(State(app): State<App>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            "SELECT p.id, p.display_name, p.cover_face_id,
                    count(DISTINCT f.asset_id) AS photos
             FROM persons p
             JOIN faces f ON f.person_id = p.id
             JOIN assets a ON a.id = f.asset_id
             WHERE p.merged_into IS NULL
               AND NOT a.archived AND a.trashed_at IS NULL AND NOT a.locked
             GROUP BY p.id, p.display_name, p.cover_face_id
             ORDER BY photos DESC",
            &[],
        )
        .await?;
    let items: Vec<_> = rows
        .iter()
        .map(|r| {
            serde_json::json!({
                "id": r.get::<_, i64>(0),
                "name": r.get::<_, Option<String>>(1),
                "cover_face": r.get::<_, Option<i64>>(2),
                "photos": r.get::<_, i64>(3),
            })
        })
        .collect();
    Ok(Json(serde_json::json!({ "items": items })))
}

/// One person's photos, newest first (timeline JSON shape).
async fn person_assets(State(app): State<App>, Path(id): Path<i64>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!(
                "SELECT DISTINCT {ASSET_COLS} FROM assets
                 JOIN faces ON faces.asset_id = assets.id
                 WHERE faces.person_id = $1 {VISIBLE}
                 ORDER BY assets.taken_at DESC NULLS LAST"
            ),
            &[&id],
        )
        .await?;
    let items: Vec<Asset> = rows.iter().map(asset_from).collect();
    Ok(Json(serde_json::json!({ "items": items })))
}

#[derive(Deserialize)]
struct Rename {
    name: String,
}

async fn person_rename(
    State(app): State<App>,
    Path(id): Path<i64>,
    Json(b): Json<Rename>,
) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let name = b.name.trim();
    let val: Option<&str> = if name.is_empty() { None } else { Some(name) };
    let n = c
        .execute("UPDATE persons SET display_name = $2 WHERE id = $1", &[&id, &val])
        .await?;
    Ok(Json(serde_json::json!({ "updated": n })))
}

#[derive(Deserialize)]
struct Cover {
    face_id: i64,
}

/// Set a person's avatar to one concrete face crop. The face must belong to
/// that person (or to a cluster merged into it) — otherwise no row updates.
async fn person_cover(
    State(app): State<App>,
    Path(id): Path<i64>,
    Json(b): Json<Cover>,
) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let n = c
        .execute(
            "UPDATE persons SET cover_face_id = $2
             WHERE id = $1 AND EXISTS (
                 SELECT 1 FROM faces f JOIN persons p ON p.id = f.person_id
                 WHERE f.id = $2 AND (p.id = $1 OR p.merged_into = $1))",
            &[&id, &b.face_id],
        )
        .await?;
    Ok(Json(serde_json::json!({ "updated": n })))
}

/// Faces detected on one asset, resolved to their (un-merged) person — feeds
/// the person row in the viewer's info sheet.
async fn asset_faces(
    State(app): State<App>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, Api> {
    if !safe_id(&id) {
        return Ok(Json(serde_json::json!({ "items": [] })));
    }
    let c = app.pool.get().await?;
    let rows = c
        .query(
            "SELECT f.id, COALESCE(p2.id, p.id), COALESCE(p2.display_name, p.display_name)
             FROM faces f
             JOIN persons p ON p.id = f.person_id
             LEFT JOIN persons p2 ON p2.id = p.merged_into
             WHERE f.asset_id = $1
             ORDER BY f.quality DESC NULLS LAST",
            &[&id],
        )
        .await?;
    let items: Vec<_> = rows
        .iter()
        .map(|r| {
            serde_json::json!({
                "face": r.get::<_, i64>(0),
                "person": r.get::<_, i64>(1),
                "name": r.get::<_, Option<String>>(2),
            })
        })
        .collect();
    Ok(Json(serde_json::json!({ "items": items })))
}

/// Square avatar crop written by the face worker (photos/faces/<face_id>.webp).
async fn face_crop(State(app): State<App>, Path(id): Path<i64>, headers: HeaderMap) -> Response {
    let path = app.photos_dir.join("faces").join(format!("{id}.webp"));
    serve_immutable(path, headers).await
}

/// Canonicalize `p` and require it to live under `root` (which is also
/// canonicalized) — symlinks or DB-tampered orig_path values can't escape.
async fn confine(root: &std::path::Path, p: &std::path::Path) -> Option<PathBuf> {
    let canon = tokio::fs::canonicalize(p).await.ok()?;
    let root = tokio::fs::canonicalize(root).await.ok()?;
    canon.starts_with(&root).then_some(canon)
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
    // serve only files that really live inside the photos root
    confine(&app.photos_dir, std::path::Path::new(&row.get::<_, String>(0))).await
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

pub(crate) fn safe_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_hexdigit())
}

/// Lowercase-hex SHA256 of `bytes` — the canonical content id for the whole
/// system (matches the Python Takeout ingest and the iOS CryptoKit hash).
pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(bytes);
    let mut s = String::with_capacity(64);
    for b in digest {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

// -------------------------------------------------------------- vecmap ---

/// EXPERIMENTAL: a UMAP projection of every Qwen3-VL embedding, rendered as a
/// zoomable WebGL mosaic of the real thumbnails. The bundle (map.html,
/// layout.json, tiles/atlas_*.webp) is generated by an external tool that is
/// NOT part of this repo and placed into {photos_dir}/vecmap — without a
/// bundle these routes simply 404. Regenerating is just overwriting those
/// files, so the cache window is deliberately short.
async fn map_index(State(app): State<App>, headers: HeaderMap) -> Response {
    serve_map(app.photos_dir.join("vecmap").join("map.html"), headers).await
}

async fn map_asset(State(app): State<App>, Path(path): Path<String>, headers: HeaderMap) -> Response {
    // only the generated bundle is reachable — no traversal out of vecmap/
    if path.contains("..") || path.starts_with('/') || path.contains('\\') {
        return StatusCode::NOT_FOUND.into_response();
    }
    serve_map(app.photos_dir.join("vecmap").join(path), headers).await
}

async fn serve_map(path: PathBuf, headers: HeaderMap) -> Response {
    let mut req = axum::http::Request::new(axum::body::Body::empty());
    *req.headers_mut() = headers;
    match ServeFile::new(path).oneshot(req).await {
        Ok(mut resp) => {
            resp.headers_mut()
                .insert(header::CACHE_CONTROL, HeaderValue::from_static("public, max-age=60"));
            resp.into_response()
        }
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

/// ServeFile handles Range requests (AVPlayer) + content types; we add the
/// immutable cache header — content-addressed URLs never change — plus
/// nosniff so browsers can't second-guess the served media type.
async fn serve_immutable(path: PathBuf, headers: HeaderMap) -> Response {
    let mut req = axum::http::Request::new(axum::body::Body::empty());
    *req.headers_mut() = headers;
    match ServeFile::new(path).oneshot(req).await {
        Ok(mut resp) => {
            resp.headers_mut().insert(
                header::CACHE_CONTROL,
                HeaderValue::from_static("public, max-age=31536000, immutable"),
            );
            resp.headers_mut()
                .insert(header::X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
            resp.into_response()
        }
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

// ------------------------------------------------------------------ error ---

pub(crate) struct Api(pub(crate) String);

impl<E: std::fmt::Display> From<E> for Api {
    fn from(e: E) -> Self {
        Api(e.to_string())
    }
}

impl IntoResponse for Api {
    fn into_response(self) -> Response {
        // log the detail server-side; never leak paths/SQL/pool errors to clients
        eprintln!("api error: {}", self.0);
        (StatusCode::INTERNAL_SERVER_ERROR, "internal error").into_response()
    }
}
