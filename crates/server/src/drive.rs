//! Drive: a folder tree over content-addressed blobs.
//!
//! Blobs live at <drive>/blobs/<sha256>; rows reference them by hash, so the
//! same bytes under two names are stored once, and a blob is removed when
//! its last row goes.
//!
//!   GET    /v1/drive/folders/{id|root}     breadcrumb, child folders, files
//!   POST   /v1/drive/folders               {parent_id?, name}, mkdir -p style
//!   PATCH  /v1/drive/folders/{id}          {name}
//!   DELETE /v1/drive/folders/{id}          permanent, whole subtree
//!   PUT    /v1/drive/files                 streaming upload
//!   PATCH  /v1/drive/files/{id}            {name}
//!   GET    /v1/drive/files/{id}/thumb      WebP preview of images and PDFs
//!   GET    /v1/drive/blobs/{hash}/{name}   the bytes, immutable, Range-capable
//!   GET    /v1/drive/recent                newest files anywhere
//!   GET    /v1/drive/search?q=             names, then extracted text
//!   POST   /v1/drive/move                  {files, folders, to}
//!   GET    /v1/drive/trash                 trashed files
//!   POST   /v1/drive/{trash,restore,delete}  {ids}
//!   POST   /v1/drive/trash/empty

use std::path::PathBuf;

use atlas_core::queue;
use axum::body::Body;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, HeaderValue, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, patch, post, put};
use axum::{Json, Router};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio_postgres::Row;

use crate::photos::assets::{check_claimed_hash, header_time, receive};
use crate::{ApiError, ApiResult, App, AppState, imaging, media, util};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/drive/folders", post(folder_create))
        .route("/drive/folders/{id}", get(list).patch(folder_rename).delete(folder_delete))
        .route("/drive/files", put(upload))
        .route("/drive/files/{id}", patch(file_rename))
        .route("/drive/files/{id}/thumb", get(thumb))
        .route("/drive/blobs/{hash}/{name}", get(blob))
        .route("/drive/recent", get(recent))
        .route("/drive/search", get(search))
        .route("/drive/move", post(mv))
        .route("/drive/trash", get(trash_list).post(trash_put))
        .route("/drive/trash/empty", post(trash_empty))
        .route("/drive/restore", post(restore))
        .route("/drive/delete", post(delete))
}

fn blob_path(app: &App, hash: &str) -> PathBuf {
    app.cfg.blobs_dir().join(hash)
}

const FILE_COLS: &str = "df.id, df.name, df.hash, df.size_bytes, df.mime, df.modified_at, df.folder_id";

fn file_json(r: &Row) -> Value {
    json!({
        "id": r.get::<_, i64>(0),
        "name": r.get::<_, String>(1),
        "hash": r.get::<_, String>(2),
        "size": r.get::<_, i64>(3),
        "mime": r.get::<_, Option<String>>(4),
        "modified_at": r.get::<_, Option<DateTime<Utc>>>(5),
        "folder_id": r.get::<_, Option<i64>>(6),
    })
}

/// "root" or a folder id.
fn folder_ref(raw: &str) -> ApiResult<Option<i64>> {
    if raw == "root" {
        return Ok(None);
    }
    raw.parse().map(Some).map_err(|_| ApiError::NotFound)
}

// ------------------------------------------------------------------- reads ---

/// One folder level: the path down from the root, child folders with their
/// recursive totals, and the files.
async fn list(State(app): State<AppState>, Path(folder): Path<String>, headers: HeaderMap) -> ApiResult<Response> {
    let folder = folder_ref(&folder)?;
    let c = app.pool.get().await?;

    let path: Vec<Value> = match folder {
        None => vec![],
        Some(id) => {
            let rows = c
                .query(
                    "WITH RECURSIVE up AS (
                         SELECT id, parent_id, name, 0 AS depth FROM drive_folders WHERE id = $1
                       UNION ALL
                         SELECT f.id, f.parent_id, f.name, up.depth + 1
                         FROM drive_folders f JOIN up ON f.id = up.parent_id
                     )
                     SELECT id, name FROM up ORDER BY depth DESC",
                    &[&id],
                )
                .await?;
            if rows.is_empty() {
                return Err(ApiError::NotFound);
            }
            rows.iter().map(|r| json!({ "id": r.get::<_, i64>(0), "name": r.get::<_, String>(1) })).collect()
        }
    };

    let folders: Vec<Value> = c
        .query(
            "WITH RECURSIVE tree AS (
                 SELECT id, id AS top FROM drive_folders WHERE parent_id IS NOT DISTINCT FROM $1
               UNION ALL
                 SELECT c.id, t.top FROM drive_folders c JOIN tree t ON c.parent_id = t.id
             ), totals AS (
                 SELECT t.top, count(fl.id) AS items, coalesce(sum(fl.size_bytes), 0)::bigint AS bytes
                 FROM tree t LEFT JOIN drive_files fl ON fl.folder_id = t.id AND fl.trashed_at IS NULL
                 GROUP BY t.top
             )
             SELECT d.id, d.name, totals.items, totals.bytes, d.created_at
             FROM drive_folders d JOIN totals ON totals.top = d.id
             ORDER BY lower(d.name)",
            &[&folder],
        )
        .await?
        .iter()
        .map(|r| {
            json!({
                "id": r.get::<_, i64>(0), "name": r.get::<_, String>(1),
                "items": r.get::<_, i64>(2), "bytes": r.get::<_, i64>(3),
                "created_at": r.get::<_, Option<DateTime<Utc>>>(4),
            })
        })
        .collect();

    let files: Vec<Value> = c
        .query(
            &format!(
                "SELECT {FILE_COLS} FROM drive_files df
                 WHERE df.folder_id IS NOT DISTINCT FROM $1 AND df.trashed_at IS NULL
                 ORDER BY lower(df.name)"
            ),
            &[&folder],
        )
        .await?
        .iter()
        .map(file_json)
        .collect();

    Ok(media::json_validated(&headers, &json!({ "path": path, "folders": folders, "files": files })))
}

async fn recent(State(app): State<AppState>, headers: HeaderMap) -> ApiResult<Response> {
    let c = app.pool.get().await?;
    let files: Vec<Value> = c
        .query(
            &format!(
                "SELECT {FILE_COLS} FROM drive_files df
                 WHERE df.trashed_at IS NULL ORDER BY df.modified_at DESC NULLS LAST LIMIT 40"
            ),
            &[],
        )
        .await?
        .iter()
        .map(file_json)
        .collect();
    Ok(media::json_validated(&headers, &json!({ "files": files })))
}

#[derive(Deserialize)]
struct SearchQuery {
    q: String,
}

/// Up to 60 characters either side of the first case-insensitive match.
fn snippet(text: &str, term: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let fold = |c: &char| c.to_lowercase().next().unwrap_or(*c);
    let lowered: Vec<char> = chars.iter().map(fold).collect();
    let needle: Vec<char> = term.chars().map(|c| fold(&c)).collect();
    if needle.is_empty() || needle.len() > lowered.len() {
        return String::new();
    }
    let Some(at) = lowered.windows(needle.len()).position(|w| w == needle.as_slice()) else {
        return String::new();
    };
    let start = at.saturating_sub(60);
    let end = (at + needle.len() + 60).min(chars.len());
    let body: String = chars[start..end].iter().collect();
    format!(
        "{}{}{}",
        if start > 0 { "…" } else { "" },
        body.split_whitespace().collect::<Vec<_>>().join(" "),
        if end < chars.len() { "…" } else { "" },
    )
}

/// Folders and files by name first, then files whose extracted text matches,
/// each with the passage that matched.
async fn search(State(app): State<AppState>, Query(q): Query<SearchQuery>) -> ApiResult<Json<Value>> {
    let term = q.q.trim();
    if term.is_empty() {
        return Ok(Json(json!({ "files": [], "folders": [] })));
    }
    let like = format!("%{}%", util::like_escape(term));
    let c = app.pool.get().await?;
    let with_folder = |r: &Row| {
        let mut file = file_json(r);
        file["folder"] = json!(r.get::<_, Option<String>>(7));
        file
    };
    let mut files: Vec<Value> = c
        .query(
            &format!(
                "SELECT {FILE_COLS}, fo.name FROM drive_files df
                 LEFT JOIN drive_folders fo ON fo.id = df.folder_id
                 WHERE df.name ILIKE $1 AND df.trashed_at IS NULL
                 ORDER BY lower(df.name) LIMIT 200"
            ),
            &[&like],
        )
        .await?
        .iter()
        .map(with_folder)
        .collect();
    for r in c
        .query(
            &format!(
                "SELECT {FILE_COLS}, fo.name, df.text FROM drive_files df
                 LEFT JOIN drive_folders fo ON fo.id = df.folder_id
                 WHERE df.text ILIKE $1 AND df.name NOT ILIKE $1 AND df.trashed_at IS NULL
                 ORDER BY df.modified_at DESC NULLS LAST LIMIT 60"
            ),
            &[&like],
        )
        .await?
        .iter()
    {
        let mut file = with_folder(r);
        file["snippet"] = json!(snippet(r.get::<_, &str>(8), term));
        files.push(file);
    }
    let folders: Vec<Value> = c
        .query(
            "SELECT id, name, parent_id FROM drive_folders WHERE name ILIKE $1 ORDER BY lower(name) LIMIT 60",
            &[&like],
        )
        .await?
        .iter()
        .map(|r| json!({ "id": r.get::<_, i64>(0), "name": r.get::<_, String>(1), "parent_id": r.get::<_, Option<i64>>(2) }))
        .collect();
    Ok(Json(json!({ "files": files, "folders": folders })))
}

// ------------------------------------------------------------------- blobs ---

/// Content type from the display name: the blob path itself has no extension.
pub fn mime_for(name: &str) -> &'static str {
    match util::lower_ext(name).as_str() {
        "pdf" => "application/pdf",
        "txt" | "md" | "log" => "text/plain; charset=utf-8",
        "html" | "htm" => "text/html; charset=utf-8",
        "csv" => "text/csv",
        "json" => "application/json",
        "xml" => "application/xml",
        "zip" => "application/zip",
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "heic" => "image/heic",
        "svg" => "image/svg+xml",
        "mp3" => "audio/mpeg",
        "m4a" | "aac" => "audio/mp4",
        "wav" => "audio/wav",
        "ogg" | "oga" => "audio/ogg",
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        "webm" => "video/webm",
        "doc" => "application/msword",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" => "application/vnd.ms-excel",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" => "application/vnd.ms-powerpoint",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        _ => "application/octet-stream",
    }
}

/// Types a browser may render inline. Everything that can run script on
/// this origin (HTML, SVG, XML) is forced to download instead.
fn inline_safe(mime: &str) -> bool {
    (mime.starts_with("image/") && mime != "image/svg+xml")
        || mime.starts_with("video/")
        || mime.starts_with("audio/")
        || matches!(mime, "application/pdf" | "text/plain; charset=utf-8" | "text/csv" | "application/json")
}

/// The name in the URL only decides the content type and the download name;
/// the content is addressed by hash alone.
async fn blob(State(app): State<AppState>, Path((hash, name)): Path<(String, String)>, headers: HeaderMap) -> Response {
    if !util::is_content_id(&hash) {
        return ApiError::NotFound.into_response();
    }
    let mut resp = media::immutable_file(blob_path(&app, &hash), headers).await;
    if !resp.status().is_success() {
        return resp;
    }
    let mime = mime_for(&name);
    resp.headers_mut().insert(header::CONTENT_TYPE, HeaderValue::from_static(mime));
    let disposition = if inline_safe(mime) { "inline" } else { "attachment" };
    // RFC 5987 filename* keeps umlauts; the plain one is the ASCII fallback
    let ascii: String = name.chars().map(|ch| if ch.is_ascii() && ch != '"' && ch != '\\' { ch } else { '_' }).collect();
    let encoded: String = name
        .bytes()
        .map(|b| match b {
            b'0'..=b'9' | b'a'..=b'z' | b'A'..=b'Z' | b'.' | b'-' | b'_' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect();
    if let Ok(v) = HeaderValue::from_str(&format!("{disposition}; filename=\"{ascii}\"; filename*=UTF-8''{encoded}")) {
        resp.headers_mut().insert(header::CONTENT_DISPOSITION, v);
    }
    resp
}

/// A 512px WebP of an image or of a PDF's first page, made on first request
/// and kept next to the blobs. Keyed by content, so it is immutable.
async fn thumb(State(app): State<AppState>, Path(id): Path<i64>, headers: HeaderMap) -> ApiResult<Response> {
    let c = app.pool.get().await?;
    let row = c.query_opt("SELECT hash, name FROM drive_files WHERE id = $1", &[&id]).await?.ok_or(ApiError::NotFound)?;
    drop(c);
    let (hash, name): (String, String) = (row.get(0), row.get(1));
    if !util::is_content_id(&hash) {
        return Err(ApiError::NotFound);
    }
    let dest = app.cfg.drive_thumbs_dir().join(format!("{hash}.webp"));
    if !tokio::fs::try_exists(&dest).await.unwrap_or(false) {
        let source = blob_path(&app, &hash);
        let ext = util::lower_ext(&name);
        let out = dest.clone();
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let decoded = if ext == "pdf" {
                imaging::decode_bytes(&first_pdf_page(&source)?)?
            } else if util::IMAGE_EXTS.contains(&ext.as_str()) {
                imaging::decode(&source)?
            } else {
                anyhow::bail!("no preview for .{ext}");
            };
            let small = imaging::fit(&decoded.rgb, imaging::GRID)?;
            imaging::write_atomic(&out, &imaging::encode_webp(&small, 80.0, decoded.icc.as_deref()))
        })
        .await?
        .map_err(|_| ApiError::NotFound)?;
    }
    Ok(media::immutable_file(dest, headers).await)
}

fn first_pdf_page(pdf: &std::path::Path) -> anyhow::Result<Vec<u8>> {
    let out = std::process::Command::new("pdftoppm")
        .args(["-png", "-singlefile", "-f", "1", "-l", "1", "-scale-to", "1024"])
        .arg(pdf) // no output root: the page goes to stdout
        .output()?;
    anyhow::ensure!(out.status.success() && !out.stdout.is_empty(), "pdftoppm failed");
    Ok(out.stdout)
}

/// Remove blobs (and their previews) that no row references any more.
async fn collect_blobs(app: &App, hashes: &[String]) -> ApiResult<()> {
    if hashes.is_empty() {
        return Ok(());
    }
    let c = app.pool.get().await?;
    let referenced: Vec<String> = c
        .query("SELECT DISTINCT hash FROM drive_files WHERE hash = ANY($1)", &[&hashes])
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    for hash in hashes.iter().filter(|h| !referenced.contains(h) && util::is_content_id(h)) {
        let _ = tokio::fs::remove_file(blob_path(app, hash)).await;
        let _ = tokio::fs::remove_file(app.cfg.drive_thumbs_dir().join(format!("{hash}.webp"))).await;
    }
    Ok(())
}

// ------------------------------------------------------------------ upload ---

/// PUT /v1/drive/files — the raw file as the body.
///
///   X-Filename       display name (percent-encoded UTF-8)
///   X-Folder-Id      target folder (absent = root)
///   X-Modified-At    unix seconds (optional, default now)
///   X-Content-Hash   SHA-256 the client computed (optional, verified)
///
/// A file of the same name in the same folder is replaced, as on any
/// filesystem; its old blob goes if that was the last reference.
async fn upload(State(app): State<AppState>, headers: HeaderMap, body: Body) -> ApiResult<Json<Value>> {
    let received = receive(body, &app.cfg.blobs_dir().join(".incoming"), app.cfg.max_upload).await?;
    let outcome = store_upload(&app, &headers, &received.path, &received.hash, received.size).await;
    let _ = tokio::fs::remove_file(&received.path).await; // already moved on success
    outcome
}

async fn store_upload(
    app: &App,
    headers: &HeaderMap,
    temp: &std::path::Path,
    hash: &str,
    size: u64,
) -> ApiResult<Json<Value>> {
    check_claimed_hash(headers, hash)?;
    let name = util::client_filename(headers.get("x-filename").and_then(|v| v.to_str().ok()));
    let folder: Option<i64> = headers.get("x-folder-id").and_then(|v| v.to_str().ok()).and_then(|s| s.trim().parse().ok());
    let modified = header_time(headers, "x-modified-at").unwrap_or_else(Utc::now);

    let c = app.pool.get().await?;
    if let Some(folder) = folder
        && c.query_opt("SELECT 1 FROM drive_folders WHERE id = $1", &[&folder]).await?.is_none()
    {
        return Err(ApiError::BadRequest("unknown folder"));
    }

    let dest = blob_path(app, hash);
    if !tokio::fs::try_exists(&dest).await.unwrap_or(false) {
        tokio::fs::rename(temp, &dest).await?;
    }

    let mime = mime_for(&name);
    let size = size as i64;
    let existing = c
        .query_opt(
            "SELECT id, hash FROM drive_files
             WHERE folder_id IS NOT DISTINCT FROM $1 AND name = $2 AND trashed_at IS NULL",
            &[&folder, &name],
        )
        .await?;
    let (id, replaced, orphan) = match existing {
        Some(row) => {
            let id: i64 = row.get(0);
            let old: String = row.get(1);
            c.execute(
                "UPDATE drive_files
                 SET hash = $2, size_bytes = $3, mime = $4, modified_at = $5, source = 'iphone', text = NULL
                 WHERE id = $1",
                &[&id, &hash, &size, &mime, &modified],
            )
            .await?;
            (id, true, (old != hash).then_some(old))
        }
        None => {
            let row = c
                .query_one(
                    "INSERT INTO drive_files (folder_id, name, hash, size_bytes, mime, modified_at, source)
                     VALUES ($1, $2, $3, $4, $5, $6, 'iphone') RETURNING id",
                    &[&folder, &name, &hash, &size, &mime, &modified],
                )
                .await?;
            (row.get(0), false, None)
        }
    };
    // make the new content searchable
    queue::requeue(&c, queue::DRIVE_TEXT, "drive_file", &id.to_string(), queue::PRIORITY_INTERACTIVE).await?;
    drop(c);
    app.jobs_wake.notify_waiters();
    if let Some(old) = orphan {
        collect_blobs(app, &[old]).await?;
    }
    Ok(Json(json!({ "id": id, "hash": hash, "replaced": replaced })))
}

// --------------------------------------------------------------- mutations ---

#[derive(Deserialize)]
struct NewFolder {
    parent_id: Option<i64>,
    name: String,
}

#[derive(Deserialize)]
struct Rename {
    name: String,
}

/// A name that is one path component: no separators, not a dot entry.
fn clean_name(raw: &str) -> ApiResult<&str> {
    let name = raw.trim();
    if name.is_empty() || name.chars().count() > 255 || name.contains(['/', '\\']) || name == "." || name == ".." {
        return Err(ApiError::BadRequest("invalid name"));
    }
    Ok(name)
}

/// Creating a folder that exists returns it.
async fn folder_create(State(app): State<AppState>, Json(b): Json<NewFolder>) -> ApiResult<Json<Value>> {
    let name = clean_name(&b.name)?;
    let c = app.pool.get().await?;
    if let Some(parent) = b.parent_id
        && c.query_opt("SELECT 1 FROM drive_folders WHERE id = $1", &[&parent]).await?.is_none()
    {
        return Err(ApiError::BadRequest("unknown folder"));
    }
    let row = c
        .query_one(
            "INSERT INTO drive_folders (parent_id, name) VALUES ($1, $2)
             ON CONFLICT (parent_id, name) DO UPDATE SET name = EXCLUDED.name
             RETURNING id",
            &[&b.parent_id, &name],
        )
        .await?;
    Ok(Json(json!({ "id": row.get::<_, i64>(0), "name": name })))
}

async fn folder_rename(State(app): State<AppState>, Path(id): Path<String>, Json(b): Json<Rename>) -> ApiResult<Json<Value>> {
    let id = folder_ref(&id)?.ok_or(ApiError::BadRequest("the root cannot be renamed"))?;
    let name = clean_name(&b.name)?;
    let c = app.pool.get().await?;
    let taken = c
        .query_opt(
            "SELECT 1 FROM drive_folders s JOIN drive_folders me ON me.id = $1
             WHERE s.parent_id IS NOT DISTINCT FROM me.parent_id AND s.name = $2 AND s.id <> $1",
            &[&id, &name],
        )
        .await?;
    if taken.is_some() {
        return Err(ApiError::BadRequest("a folder with that name already exists here"));
    }
    let n = c.execute("UPDATE drive_folders SET name = $2 WHERE id = $1", &[&id, &name]).await?;
    Ok(Json(json!({ "updated": n })))
}

/// Permanent: the folder, its whole subtree and every file row in it, then
/// the blobs that lost their last reference.
async fn folder_delete(State(app): State<AppState>, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    let id = folder_ref(&id)?.ok_or(ApiError::BadRequest("the root cannot be deleted"))?;
    let c = app.pool.get().await?;
    let hashes: Vec<String> = c
        .query(
            "WITH RECURSIVE tree AS (
                 SELECT id FROM drive_folders WHERE id = $1
               UNION ALL
                 SELECT f.id FROM drive_folders f JOIN tree t ON f.parent_id = t.id
             )
             SELECT DISTINCT hash FROM drive_files WHERE folder_id IN (SELECT id FROM tree)",
            &[&id],
        )
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    let n = c.execute("DELETE FROM drive_folders WHERE id = $1", &[&id]).await?;
    drop(c);
    collect_blobs(&app, &hashes).await?;
    Ok(Json(json!({ "deleted": n })))
}

async fn file_rename(State(app): State<AppState>, Path(id): Path<i64>, Json(b): Json<Rename>) -> ApiResult<Json<Value>> {
    let name = clean_name(&b.name)?;
    let c = app.pool.get().await?;
    let n = c
        .execute("UPDATE drive_files SET name = $2, mime = $3 WHERE id = $1", &[&id, &name, &mime_for(name)])
        .await?;
    Ok(Json(json!({ "updated": n })))
}

#[derive(Deserialize)]
struct Move {
    #[serde(default)]
    files: Vec<i64>,
    #[serde(default)]
    folders: Vec<i64>,
    /// null = root
    to: Option<i64>,
}

/// A folder cannot move into itself or anything below it.
async fn mv(State(app): State<AppState>, Json(b): Json<Move>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    if let Some(target) = b.to {
        if c.query_opt("SELECT 1 FROM drive_folders WHERE id = $1", &[&target]).await?.is_none() {
            return Err(ApiError::BadRequest("unknown folder"));
        }
        if !b.folders.is_empty() {
            let cycle = c
                .query_opt(
                    "WITH RECURSIVE below AS (
                         SELECT id FROM drive_folders WHERE id = ANY($1)
                       UNION ALL
                         SELECT f.id FROM drive_folders f JOIN below ON f.parent_id = below.id
                     )
                     SELECT 1 FROM below WHERE id = $2",
                    &[&b.folders, &target],
                )
                .await?;
            if cycle.is_some() {
                return Err(ApiError::BadRequest("cannot move a folder into itself"));
            }
        }
    }
    let mut moved = 0;
    if !b.files.is_empty() {
        moved += c.execute("UPDATE drive_files SET folder_id = $2 WHERE id = ANY($1)", &[&b.files, &b.to]).await?;
    }
    if !b.folders.is_empty() {
        moved += c.execute("UPDATE drive_folders SET parent_id = $2 WHERE id = ANY($1)", &[&b.folders, &b.to]).await?;
    }
    Ok(Json(json!({ "moved": moved })))
}

#[derive(Deserialize)]
struct FileIds {
    ids: Vec<i64>,
}

async fn trash_list(State(app): State<AppState>, headers: HeaderMap) -> ApiResult<Response> {
    let c = app.pool.get().await?;
    let files: Vec<Value> = c
        .query(
            &format!("SELECT {FILE_COLS} FROM drive_files df WHERE df.trashed_at IS NOT NULL ORDER BY df.trashed_at DESC"),
            &[],
        )
        .await?
        .iter()
        .map(file_json)
        .collect();
    Ok(media::json_validated(&headers, &json!({ "files": files })))
}

async fn trash_put(State(app): State<AppState>, Json(b): Json<FileIds>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let n = c.execute("UPDATE drive_files SET trashed_at = now() WHERE id = ANY($1)", &[&b.ids]).await?;
    Ok(Json(json!({ "updated": n })))
}

async fn restore(State(app): State<AppState>, Json(b): Json<FileIds>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let n = c.execute("UPDATE drive_files SET trashed_at = NULL WHERE id = ANY($1)", &[&b.ids]).await?;
    Ok(Json(json!({ "updated": n })))
}

async fn delete(State(app): State<AppState>, Json(b): Json<FileIds>) -> ApiResult<Json<Value>> {
    Ok(Json(json!({ "deleted": purge(&app, &b.ids).await? })))
}

async fn trash_empty(State(app): State<AppState>) -> ApiResult<Json<Value>> {
    let ids: Vec<i64> = {
        let c = app.pool.get().await?;
        c.query("SELECT id FROM drive_files WHERE trashed_at IS NOT NULL", &[]).await?.iter().map(|r| r.get(0)).collect()
    };
    Ok(Json(json!({ "deleted": purge(&app, &ids).await? })))
}

async fn purge(app: &App, ids: &[i64]) -> ApiResult<u64> {
    if ids.is_empty() {
        return Ok(0);
    }
    let c = app.pool.get().await?;
    let hashes: Vec<String> = c
        .query("SELECT DISTINCT hash FROM drive_files WHERE id = ANY($1)", &[&ids])
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    let owners: Vec<String> = ids.iter().map(i64::to_string).collect();
    c.execute("DELETE FROM ingest_jobs WHERE owner_type = 'drive_file' AND owner_id = ANY($1)", &[&owners]).await?;
    let n = c.execute("DELETE FROM drive_files WHERE id = ANY($1)", &[&ids]).await?;
    drop(c);
    collect_blobs(app, &hashes).await?;
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snippets_show_the_match_in_context() {
        let text = format!("{} Die Rechnung vom März ist bezahlt. {}", "x ".repeat(80), "y ".repeat(80));
        let s = snippet(&text, "rechnung");
        assert!(s.starts_with('…') && s.ends_with('…'));
        assert!(s.contains("Die Rechnung vom März"));
        assert_eq!(snippet("short", "absent"), "");
    }

    #[test]
    fn script_capable_types_never_render_inline() {
        assert!(inline_safe(mime_for("scan.pdf")));
        assert!(inline_safe(mime_for("photo.JPG")));
        assert!(!inline_safe(mime_for("page.html")));
        assert!(!inline_safe(mime_for("logo.svg")));
        assert!(!inline_safe(mime_for("feed.xml")));
    }

    #[test]
    fn names_are_single_path_components() {
        assert!(clean_name("Steuer 2025").is_ok());
        assert!(clean_name("a/b").is_err());
        assert!(clean_name("..").is_err());
        assert!(clean_name("   ").is_err());
    }
}
