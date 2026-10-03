//! Single assets: detail, media, upload, state changes.

use std::path::PathBuf;

use atlas_core::queue;
use axum::Json;
use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::{IntoResponse, Response};
use chrono::{DateTime, Utc};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;

use super::{Ids, IdsValue, local_seconds};
use crate::{ApiError, ApiResult, App, AppState, media, util};

// ------------------------------------------------------------------ detail ---

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
    let people: Vec<Value> = c
        .query(
            "SELECT f.id, p.id, p.display_name
             FROM faces f JOIN persons p ON p.id = f.person_id
             WHERE f.asset_id = $1 ORDER BY f.quality DESC NULLS LAST",
            &[&id],
        )
        .await?
        .iter()
        .map(|f| json!({ "face": f.get::<_, i64>(0), "id": f.get::<_, i64>(1), "name": f.get::<_, Option<String>>(2) }))
        .collect();
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
    let tags: Vec<String> = c
        .query("SELECT DISTINCT tag FROM tags WHERE asset_id = $1 ORDER BY tag", &[&id])
        .await?
        .iter()
        .map(|t| t.get(0))
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
        "albums": albums,
        "tags": tags,
    })))
}

// ------------------------------------------------------------------- media ---

pub async fn thumb(
    State(app): State<AppState>,
    Path((id, size)): Path<(String, u32)>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    if !util::is_content_id(&id) || !matches!(size, 512 | 2048) {
        return Err(ApiError::NotFound);
    }
    Ok(media::immutable_file(app.cfg.thumb_path(&id, size), headers).await)
}

async fn original_path(app: &App, id: &str) -> ApiResult<PathBuf> {
    if !util::is_content_id(id) {
        return Err(ApiError::NotFound);
    }
    let c = app.pool.get().await?;
    let row = c.query_opt("SELECT orig_path FROM assets WHERE id = $1", &[&id]).await?.ok_or(ApiError::NotFound)?;
    util::confine(&app.cfg.photos_dir, std::path::Path::new(row.get::<_, &str>(0)))
        .await
        .ok_or(ApiError::NotFound)
}

pub async fn original(State(app): State<AppState>, Path(id): Path<String>, headers: HeaderMap) -> ApiResult<Response> {
    Ok(media::immutable_file(original_path(&app, &id).await?, headers).await)
}

#[derive(Deserialize)]
pub struct VideoQuery {
    /// `original` forces the source file even when a rendition exists.
    quality: Option<String>,
}

/// The stream a player should open: the 1080p rendition when the worker has
/// made one (large or high-bitrate sources), otherwise the original.
pub async fn video(
    State(app): State<AppState>,
    Path(id): Path<String>,
    axum::extract::Query(q): axum::extract::Query<VideoQuery>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    if !util::is_content_id(&id) {
        return Err(ApiError::NotFound);
    }
    if q.quality.as_deref() != Some("original") {
        let preview = app.cfg.preview_path(&id);
        if tokio::fs::try_exists(&preview).await.unwrap_or(false) {
            return Ok(media::immutable_file(preview, headers).await);
        }
    }
    Ok(media::immutable_file(original_path(&app, &id).await?, headers).await)
}

// ------------------------------------------------------------------ upload ---

#[derive(Deserialize)]
pub struct Hashes {
    hashes: Vec<String>,
}

/// Which of these content hashes the library already has, so a client only
/// uploads what is new.
pub async fn exists(State(app): State<AppState>, Json(b): Json<Hashes>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let have: Vec<String> = c
        .query("SELECT id FROM assets WHERE id = ANY($1)", &[&b.hashes])
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    Ok(Json(json!({ "have": have })))
}

/// A request body written to disk as it arrives, hashed on the way: memory
/// use is one chunk, whatever the upload's size.
pub struct Received {
    pub path: PathBuf,
    pub hash: String,
    pub size: u64,
}

pub async fn receive(body: Body, dir: &std::path::Path, limit: u64) -> ApiResult<Received> {
    tokio::fs::create_dir_all(dir).await?;
    let path = dir.join(util::temp_name("upload"));
    let mut file = tokio::fs::File::create(&path).await?;
    let mut hasher = Sha256::new();
    let mut size = 0u64;
    let mut stream = body.into_data_stream();
    let result: ApiResult<()> = async {
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|_| ApiError::BadRequest("upload interrupted"))?;
            size += chunk.len() as u64;
            if size > limit {
                return Err(ApiError::TooLarge);
            }
            hasher.update(&chunk);
            file.write_all(&chunk).await?;
        }
        file.sync_all().await?;
        Ok(())
    }
    .await;
    if let Err(e) = result {
        drop(file);
        let _ = tokio::fs::remove_file(&path).await;
        return Err(e);
    }
    Ok(Received { path, hash: util::hex(&hasher.finalize()), size })
}

/// The claimed hash is an integrity check only: the id is always what the
/// server computed from the bytes it received.
pub fn check_claimed_hash(headers: &HeaderMap, actual: &str) -> ApiResult<()> {
    match headers.get("x-content-hash").and_then(|v| v.to_str().ok()).map(|h| h.trim().to_ascii_lowercase()) {
        Some(claimed) if !claimed.is_empty() && claimed != actual => Err(ApiError::BadRequest("X-Content-Hash mismatch")),
        _ => Ok(()),
    }
}

pub fn header_time(headers: &HeaderMap, name: &str) -> Option<DateTime<Utc>> {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.trim().parse::<i64>().ok())
        .and_then(|secs| DateTime::from_timestamp(secs, 0))
}

/// PUT /v1/assets — the raw file as the body.
///
///   X-Filename       original name (percent-encoded UTF-8)
///   X-Taken-At       capture time, unix seconds (optional)
///   X-Content-Hash   SHA-256 the client computed (optional, verified)
///   X-Source         where it comes from (default "iphone")
///
/// The asset id is the SHA-256 of the received bytes, so the same content
/// collapses to one asset whichever path it arrives by. Stored at
/// originals/YYYY/MM/<id>.<ext>; the thumbnail, metadata, embedding and face
/// jobs are queued, the first two ahead of any backlog.
pub async fn upload(State(app): State<AppState>, headers: HeaderMap, body: Body) -> ApiResult<Response> {
    let received = receive(body, &app.cfg.incoming_dir(), app.cfg.max_upload).await?;
    let id = received.hash.clone();
    let outcome = store_upload(&app, &headers, &received).await;
    if !matches!(outcome, Ok(true)) {
        let _ = tokio::fs::remove_file(&received.path).await;
    }
    let created = outcome?;
    Ok(Json(json!({ "id": id, "exists": !created })).into_response())
}

/// Returns whether a new asset was created (the temp file was then moved).
async fn store_upload(app: &App, headers: &HeaderMap, received: &Received) -> ApiResult<bool> {
    check_claimed_hash(headers, &received.hash)?;
    let id = &received.hash;
    let c = app.pool.get().await?;
    if c.query_opt("SELECT 1 FROM assets WHERE id = $1", &[id]).await?.is_some() {
        return Ok(false);
    }
    let name = util::client_filename(headers.get("x-filename").and_then(|v| v.to_str().ok()));
    let ext = util::media_ext(&name);
    let taken = header_time(headers, "x-taken-at");
    let source = headers
        .get("x-source")
        .and_then(|v| v.to_str().ok())
        .filter(|s| !s.is_empty() && s.len() <= 32 && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'))
        .unwrap_or("iphone");

    let month = taken.map(|t| t.format("%Y/%m").to_string()).unwrap_or_else(|| "0000/00".into());
    let dir = app.cfg.originals_dir().join(month);
    tokio::fs::create_dir_all(&dir).await?;
    let dest = dir.join(format!("{id}.{ext}"));
    tokio::fs::rename(&received.path, &dest).await?;

    let kind = if util::is_video_ext(ext) { "video" } else { "photo" };
    let inserted = c
        .execute(
            "INSERT INTO assets (id, type, taken_at, taken_src, orig_path, orig_name, size_bytes, source)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (id) DO NOTHING",
            &[
                id,
                &kind,
                &taken,
                &taken.map(|_| "upload"),
                &dest.to_string_lossy().as_ref(),
                &name,
                &(received.size as i64),
                &source,
            ],
        )
        .await?;
    queue::enqueue(&c, queue::THUMB, "asset", id, queue::PRIORITY_INTERACTIVE).await?;
    queue::enqueue(&c, queue::META, "asset", id, queue::PRIORITY_INTERACTIVE + 10).await?;
    queue::enqueue(&c, queue::EMBED, "asset", id, queue::PRIORITY_DEFAULT).await?;
    queue::enqueue(&c, queue::FACES, "asset", id, queue::PRIORITY_DEFAULT).await?;
    app.jobs_wake.notify_waiters();
    Ok(inserted > 0)
}

// ------------------------------------------------------------------- state ---

pub async fn favorite(State(app): State<AppState>, Json(b): Json<IdsValue>) -> ApiResult<Json<Value>> {
    set_flag(&app, "favorite", &b).await
}

pub async fn archive(State(app): State<AppState>, Json(b): Json<IdsValue>) -> ApiResult<Json<Value>> {
    set_flag(&app, "archived", &b).await
}

pub async fn lock(State(app): State<AppState>, Json(b): Json<IdsValue>) -> ApiResult<Json<Value>> {
    set_flag(&app, "locked", &b).await
}

/// `column` is one of three literals above, never client input.
async fn set_flag(app: &App, column: &str, b: &IdsValue) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let n = c
        .execute(&format!("UPDATE assets SET {column} = $2 WHERE id = ANY($1)"), &[&b.ids, &b.value])
        .await?;
    Ok(Json(json!({ "updated": n })))
}

pub async fn trash(State(app): State<AppState>, Json(b): Json<Ids>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let n = c.execute("UPDATE assets SET trashed_at = now() WHERE id = ANY($1)", &[&b.ids]).await?;
    Ok(Json(json!({ "updated": n })))
}

/// Back into the timeline from wherever it was: trash, archive or locked.
pub async fn restore(State(app): State<AppState>, Json(b): Json<Ids>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let n = c
        .execute(
            "UPDATE assets SET archived = false, trashed_at = NULL, locked = false WHERE id = ANY($1)",
            &[&b.ids],
        )
        .await?;
    Ok(Json(json!({ "updated": n })))
}

pub async fn delete(State(app): State<AppState>, Json(b): Json<Ids>) -> ApiResult<Json<Value>> {
    Ok(Json(json!({ "deleted": purge(&app, &b.ids).await? })))
}

pub async fn empty_trash(State(app): State<AppState>) -> ApiResult<Json<Value>> {
    let ids: Vec<String> = {
        let c = app.pool.get().await?;
        c.query("SELECT id FROM assets WHERE trashed_at IS NOT NULL", &[]).await?.iter().map(|r| r.get(0)).collect()
    };
    Ok(Json(json!({ "deleted": purge(&app, &ids).await? })))
}

/// How long trashed photos and files are kept before they are removed for good.
pub const TRASH_DAYS: i32 = 30;

/// Remove photos that have been in the trash for longer than [`TRASH_DAYS`].
pub async fn purge_expired(app: &App) -> ApiResult<u64> {
    let ids: Vec<String> = {
        let c = app.pool.get().await?;
        c.query(
            "SELECT id FROM assets WHERE trashed_at < now() - make_interval(days => $1)",
            &[&TRASH_DAYS],
        )
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect()
    };
    purge(app, &ids).await
}

/// Permanent: rows, the original, every derived file. Child rows that carry
/// no foreign key (edges, embeddings, queue rows) are removed by hand: ids
/// are content hashes, so anything left behind would silently re-attach to
/// the same bytes uploaded again, and a stale vector would stay searchable.
async fn purge(app: &App, ids: &[String]) -> ApiResult<u64> {
    if ids.is_empty() {
        return Ok(0);
    }
    let mut c = app.pool.get().await?;
    let originals = c.query("SELECT id, orig_path FROM assets WHERE id = ANY($1)", &[&ids]).await?;
    let faces: Vec<i64> = c
        .query("SELECT id FROM faces WHERE asset_id = ANY($1)", &[&ids])
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();

    let tx = c.transaction().await?;
    for statement in [
        "DELETE FROM edges WHERE src_type = 'asset' AND src_id = ANY($1)",
        "DELETE FROM embeddings WHERE owner_type = 'asset' AND owner_id = ANY($1)",
        "DELETE FROM ingest_jobs WHERE owner_type = 'asset' AND owner_id = ANY($1)",
    ] {
        tx.execute(statement, &[&ids]).await?;
    }
    // faces, tags and album links follow through ON DELETE CASCADE
    let deleted = tx.execute("DELETE FROM assets WHERE id = ANY($1)", &[&ids]).await?;
    tx.commit().await?;

    // files go after the commit: a failed transaction must not orphan rows
    for row in &originals {
        let id: String = row.get(0);
        let original: String = row.get(1);
        match util::confine(&app.cfg.photos_dir, std::path::Path::new(&original)).await {
            Some(path) => {
                let _ = tokio::fs::remove_file(path).await;
            }
            None => tracing::warn!("purge: {original} is missing or outside the library, left alone"),
        }
        for derived in [app.cfg.thumb_path(&id, 512), app.cfg.thumb_path(&id, 2048), app.cfg.preview_path(&id)] {
            let _ = tokio::fs::remove_file(derived).await;
        }
    }
    for face in faces {
        let _ = tokio::fs::remove_file(app.cfg.faces_dir().join(format!("{face}.webp"))).await;
    }
    Ok(deleted)
}
