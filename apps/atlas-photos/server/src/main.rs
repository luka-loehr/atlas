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
    body::Bytes,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
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
        .route("/api/assets/{id}/info", get(asset_info))
        .route("/api/persons", get(persons))
        .route("/api/persons/{id}/assets", get(person_assets))
        .route("/api/persons/{id}/rename", post(person_rename))
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
        .route("/api/mutate/describe", post(mutate_describe))
        .route("/api/trash/empty", post(trash_empty))
        // sync / upload
        .route("/api/exists", post(exists))
        .route(
            "/api/upload",
            post(upload).layer(DefaultBodyLimit::max(1024 * 1024 * 1024)),
        )
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
    let limit = q.limit.unwrap_or(200).clamp(1, 500);
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
                 {VISIBLE}
                 ORDER BY assets.taken_at DESC NULLS LAST LIMIT 600"
            ),
            &[&like, &term],
        )
        .await?;
    let items: Vec<Asset> = rows.iter().map(asset_from).collect();
    Ok(Json(serde_json::json!({ "items": items })))
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

#[derive(Deserialize)]
struct Describe {
    id: String,
    text: String,
}

/// Set/replace the user caption ("Untertitel") of one asset.
async fn mutate_describe(State(app): State<App>, Json(b): Json<Describe>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let text = b.text.trim();
    let val: Option<&str> = if text.is_empty() { None } else { Some(text) };
    let n = c
        .execute("UPDATE assets SET description = $2 WHERE id = $1", &[&b.id, &val])
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
                    lat, lon, caption, description, favorite, duration_s, exif
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
    let exif: Option<serde_json::Value> = r.get(13);
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
        "caption": r.get::<_, Option<String>>(9),
        "description": r.get::<_, Option<String>>(10),
        "favorite": r.get::<_, bool>(11),
        "duration_s": r.get::<_, Option<f64>>(12),
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
        let _ = std::fs::remove_file(&orig);
        let _ = std::fs::remove_file(thumbs.join(format!("{id}.256.webp")));
        let _ = std::fs::remove_file(thumbs.join(format!("{id}.1024.webp")));
    }
    for stmt in [
        "DELETE FROM album_assets WHERE asset_id = ANY($1)",
        "DELETE FROM faces WHERE asset_id = ANY($1)",
        "DELETE FROM embeddings WHERE asset_id = ANY($1)",
        "DELETE FROM ingest_jobs WHERE owner_type = 'asset' AND owner_id = ANY($1)",
    ] {
        let _ = c.execute(stmt, &[ids]).await;
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
    std::fs::create_dir_all(&dir)?;
    let dest = dir.join(format!("{id}_{name}"));
    std::fs::write(&dest, &body)?;

    let ext = std::path::Path::new(&name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let kind = if VIDEO_EXTS.contains(&ext.as_str()) { "video" } else { "photo" };
    let dest_str = dest.to_string_lossy().to_string();
    let size = body.len() as i64;

    c.execute(
        "INSERT INTO assets (id, type, taken_at, orig_path, orig_name, size_bytes, source)
         VALUES ($1, $2, $3, $4, $5, $6, 'iphone') ON CONFLICT (id) DO NOTHING",
        &[&id, &kind, &taken, &dest_str, &name, &size],
    )
    .await?;
    c.execute(
        "INSERT INTO ingest_jobs (kind, owner_type, owner_id)
         VALUES ('thumb', 'asset', $1) ON CONFLICT DO NOTHING",
        &[&id],
    )
    .await?;
    for job in ["meta", "embed", "faces", "caption"] {
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

/// Square avatar crop written by the face worker (photos/faces/<face_id>.webp).
async fn face_crop(State(app): State<App>, Path(id): Path<i64>, headers: HeaderMap) -> Response {
    let path = app.photos_dir.join("faces").join(format!("{id}.webp"));
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

/// Lowercase-hex SHA256 of `bytes` — the canonical content id for the whole
/// system (matches the Python Takeout ingest and the iOS CryptoKit hash).
fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(bytes);
    let mut s = String::with_capacity(64);
    for b in digest {
        s.push_str(&format!("{b:02x}"));
    }
    s
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
