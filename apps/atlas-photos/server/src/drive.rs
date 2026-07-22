//! Drive — the "Dateien" domain of the Storage app. Folder tree + content-
//! addressed blobs (SHA-256, like assets). Blobs live at {drive_dir}/blobs/
//! <hash>; identical bytes are stored once and removal is refcounted against
//! the drive_files rows.
//!
//!   GET  /api/drive/list?folder=ID        breadcrumb + child folders + files
//!   GET  /api/drive/recent                newest files across all folders
//!   GET  /api/drive/search?q=             name match across all folders
//!   GET  /api/drive/stats                 totals for the account sheet
//!   GET  /api/drive/blob/{hash}/{name}    immutable download (Range-capable)
//!   POST /api/drive/upload                raw body, X-Filename/X-Folder-Id
//!   POST /api/drive/folders               {parent_id?, name} — mkdir -p style
//!   POST /api/drive/folders/{id}/rename   {name}
//!   POST /api/drive/folders/{id}/delete   PERMANENT subtree delete + blob GC
//!   POST /api/drive/files/{id}/rename     {name}
//!   POST /api/drive/move                  {files:[], folders:[], to: ID|null}
//!   GET/POST /api/drive/trash             list / move ids into trash
//!   POST /api/drive/restore               {ids}
//!   POST /api/drive/delete                {ids} PERMANENT + blob GC
//!   POST /api/drive/trash/empty

use std::path::PathBuf;

use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use tower::ServiceExt;
use tower_http::services::ServeFile;

use crate::{safe_id, sha256_hex, Api, App};

fn blob_path(app: &App, hash: &str) -> PathBuf {
    app.drive_dir.join("blobs").join(hash)
}

// ------------------------------------------------------------------ reads ---

#[derive(Deserialize)]
pub struct ListQ {
    folder: Option<i64>,
}

const FILE_COLS: &str = "id, name, hash, size_bytes, mime, modified_at";

fn file_json(r: &tokio_postgres::Row) -> serde_json::Value {
    serde_json::json!({
        "id": r.get::<_, i64>(0),
        "name": r.get::<_, String>(1),
        "hash": r.get::<_, String>(2),
        "size": r.get::<_, i64>(3),
        "mime": r.get::<_, Option<String>>(4),
        "modified_at": r.get::<_, Option<DateTime<Utc>>>(5),
    })
}

/// One folder level: breadcrumb up to the root, child folders (with recursive
/// item/byte totals), files. `folder` absent = root.
pub async fn list(State(app): State<App>, Query(q): Query<ListQ>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;

    let path: Vec<serde_json::Value> = match q.folder {
        None => vec![],
        Some(id) => c
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
            .await?
            .iter()
            .map(|r| serde_json::json!({"id": r.get::<_, i64>(0), "name": r.get::<_, String>(1)}))
            .collect(),
    };

    // child folders with subtree totals (files under the child, any depth)
    let folders: Vec<serde_json::Value> = c
        .query(
            "WITH RECURSIVE tree AS (
                 SELECT id, id AS top FROM drive_folders WHERE parent_id IS NOT DISTINCT FROM $1
               UNION ALL
                 SELECT c.id, t.top FROM drive_folders c JOIN tree t ON c.parent_id = t.id
             )
             SELECT d.id, d.name,
                    (SELECT count(*) FROM drive_files fl JOIN tree t ON fl.folder_id = t.id
                      WHERE t.top = d.id AND fl.trashed_at IS NULL),
                    (SELECT coalesce(sum(fl.size_bytes), 0) FROM drive_files fl JOIN tree t ON fl.folder_id = t.id
                      WHERE t.top = d.id AND fl.trashed_at IS NULL)::bigint
             FROM drive_folders d
             WHERE d.parent_id IS NOT DISTINCT FROM $1
             ORDER BY lower(d.name)",
            &[&q.folder],
        )
        .await?
        .iter()
        .map(|r| {
            serde_json::json!({
                "id": r.get::<_, i64>(0), "name": r.get::<_, String>(1),
                "items": r.get::<_, i64>(2), "bytes": r.get::<_, i64>(3),
            })
        })
        .collect();

    let files: Vec<_> = c
        .query(
            &format!(
                "SELECT {FILE_COLS} FROM drive_files
                 WHERE folder_id IS NOT DISTINCT FROM $1 AND trashed_at IS NULL
                 ORDER BY lower(name)"
            ),
            &[&q.folder],
        )
        .await?
        .iter()
        .map(file_json)
        .collect();

    Ok(Json(serde_json::json!({ "path": path, "folders": folders, "files": files })))
}

pub async fn recent(State(app): State<App>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let files: Vec<_> = c
        .query(
            &format!(
                "SELECT {FILE_COLS} FROM drive_files
                 WHERE trashed_at IS NULL
                 ORDER BY modified_at DESC NULLS LAST LIMIT 30"
            ),
            &[],
        )
        .await?
        .iter()
        .map(file_json)
        .collect();
    Ok(Json(serde_json::json!({ "files": files })))
}

#[derive(Deserialize)]
pub struct SearchQ {
    q: String,
}

/// Case-insensitive match context: ±60 chars around the first occurrence.
/// Char-aligned lowercase (first mapping only) so byte offsets can't drift.
fn snippet(text: &str, term: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let lc: Vec<char> = chars.iter().map(|c| c.to_lowercase().next().unwrap_or(*c)).collect();
    let t: Vec<char> = term.chars().map(|c| c.to_lowercase().next().unwrap_or(c)).collect();
    if t.is_empty() || t.len() > lc.len() {
        return String::new();
    }
    let Some(p) = lc.windows(t.len()).position(|w| w == &t[..]) else {
        return String::new();
    };
    let start = p.saturating_sub(60);
    let end = (p + t.len() + 60).min(chars.len());
    let body: String = chars[start..end].iter().collect();
    format!(
        "{}{}{}",
        if start > 0 { "…" } else { "" },
        body.split_whitespace().collect::<Vec<_>>().join(" "),
        if end < chars.len() { "…" } else { "" },
    )
}

/// Search across all folders: filename matches first, then content matches
/// (extracted text, see ingest/extract_drive_text.py) with a match snippet.
pub async fn search(State(app): State<App>, Query(s): Query<SearchQ>) -> Result<Json<serde_json::Value>, Api> {
    let term = s.q.trim();
    if term.is_empty() {
        return Ok(Json(serde_json::json!({ "files": [], "folders": [] })));
    }
    let like = format!("%{}%", crate::like_escape(term));
    let c = app.pool.get().await?;
    let mut files: Vec<_> = c
        .query(
            "SELECT df.id, df.name, df.hash, df.size_bytes, df.mime, df.modified_at, fo.name
             FROM drive_files df
             LEFT JOIN drive_folders fo ON fo.id = df.folder_id
             WHERE df.name ILIKE $1 AND df.trashed_at IS NULL
             ORDER BY lower(df.name) LIMIT 200",
            &[&like],
        )
        .await?
        .iter()
        .map(|r| {
            let mut j = file_json(r);
            j["folder"] = serde_json::json!(r.get::<_, Option<String>>(6));
            j
        })
        .collect();
    let content_rows = c
        .query(
            "SELECT df.id, df.name, df.hash, df.size_bytes, df.mime, df.modified_at, fo.name, df.text
             FROM drive_files df
             LEFT JOIN drive_folders fo ON fo.id = df.folder_id
             WHERE df.text ILIKE $1 AND df.name NOT ILIKE $1 AND df.trashed_at IS NULL
             ORDER BY df.modified_at DESC LIMIT 50",
            &[&like],
        )
        .await?;
    for r in &content_rows {
        let mut j = file_json(r);
        j["folder"] = serde_json::json!(r.get::<_, Option<String>>(6));
        j["snippet"] = serde_json::json!(snippet(r.get::<_, &str>(7), term));
        files.push(j);
    }
    let folders: Vec<_> = c
        .query(
            "SELECT id, name FROM drive_folders WHERE name ILIKE $1 ORDER BY lower(name) LIMIT 50",
            &[&like],
        )
        .await?
        .iter()
        .map(|r| serde_json::json!({"id": r.get::<_, i64>(0), "name": r.get::<_, String>(1)}))
        .collect();
    Ok(Json(serde_json::json!({ "files": files, "folders": folders })))
}

pub async fn stats(State(app): State<App>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let r = c
        .query_one(
            "SELECT count(*), coalesce(sum(size_bytes), 0)::bigint,
                    (SELECT count(*) FROM drive_folders)
             FROM drive_files WHERE trashed_at IS NULL",
            &[],
        )
        .await?;
    Ok(Json(serde_json::json!({
        "files": r.get::<_, i64>(0),
        "bytes": r.get::<_, i64>(1),
        "folders": r.get::<_, i64>(2),
    })))
}

// ------------------------------------------------------------------ blobs ---

/// Content type from the display name's extension — ServeFile can't guess it
/// from the extension-less blob path. Short list; octet-stream otherwise.
fn ext_mime(name: &str) -> &'static str {
    let ext = std::path::Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
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

/// Immutable, Range-capable blob download. The URL carries the display name
/// only for the content type and so shared/downloaded copies get a real
/// filename — content is addressed purely by hash.
pub async fn blob(
    State(app): State<App>,
    Path((hash, name)): Path<(String, String)>,
    headers: HeaderMap,
) -> Response {
    if !safe_id(&hash) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let mut req = axum::http::Request::new(axum::body::Body::empty());
    *req.headers_mut() = headers;
    match ServeFile::new(blob_path(&app, &hash)).oneshot(req).await {
        Ok(mut resp) => {
            resp.headers_mut().insert(
                header::CACHE_CONTROL,
                HeaderValue::from_static("public, max-age=31536000, immutable"),
            );
            if let Ok(v) = HeaderValue::from_str(ext_mime(&name)) {
                resp.headers_mut().insert(header::CONTENT_TYPE, v);
            }
            // RFC 5987 filename* so umlauts survive; plain fallback for the rest
            let ascii: String = name
                .chars()
                .map(|ch| if ch.is_ascii() && ch != '"' && ch != '\\' { ch } else { '_' })
                .collect();
            let encoded: String = name
                .bytes()
                .map(|b| match b {
                    b'0'..=b'9' | b'a'..=b'z' | b'A'..=b'Z' | b'.' | b'-' | b'_' => (b as char).to_string(),
                    _ => format!("%{b:02X}"),
                })
                .collect();
            if let Ok(v) = HeaderValue::from_str(&format!(
                "inline; filename=\"{ascii}\"; filename*=UTF-8''{encoded}"
            )) {
                resp.headers_mut().insert(header::CONTENT_DISPOSITION, v);
            }
            resp.into_response()
        }
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

/// Delete the blob file iff no drive_files row references the hash anymore.
async fn gc_blobs(app: &App, hashes: &[String]) -> Result<(), Api> {
    if hashes.is_empty() {
        return Ok(());
    }
    let c = app.pool.get().await?;
    let still: Vec<String> = c
        .query("SELECT DISTINCT hash FROM drive_files WHERE hash = ANY($1)", &[&hashes])
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    for h in hashes {
        if !still.contains(h) && safe_id(h) {
            let _ = tokio::fs::remove_file(blob_path(app, h)).await;
        }
    }
    Ok(())
}

// ----------------------------------------------------------------- upload ---

/// Raw-body upload, mirroring /api/upload for photos: the server hashes the
/// exact received bytes; X-Content-Hash is only an integrity check. Same
/// folder + same name overwrites that row (filesystem semantics) — the old
/// blob is GC'd if it was the last reference. Headers: X-Filename,
/// X-Folder-Id (absent = root), X-Content-Hash?, X-Modified-At? (unix secs).
pub async fn upload(State(app): State<App>, headers: HeaderMap, body: Bytes) -> Result<Response, Api> {
    let hash = sha256_hex(&body);
    if let Some(h) = headers.get("x-content-hash").and_then(|v| v.to_str().ok()) {
        let claimed = h.trim().to_ascii_lowercase();
        if !claimed.is_empty() && claimed != hash {
            return Ok((StatusCode::BAD_REQUEST, "X-Content-Hash mismatch").into_response());
        }
    }
    let name = headers
        .get("x-filename")
        .and_then(|v| v.to_str().ok())
        .map(|s| {
            // header values are latin-1 on the wire; the app percent-encodes
            percent_decode(s)
        })
        .and_then(|s| s.rsplit(['/', '\\']).next().map(str::to_string))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "upload".into());
    let folder: Option<i64> = headers
        .get("x-folder-id")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.trim().parse().ok());
    let modified: DateTime<Utc> = headers
        .get("x-modified-at")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.trim().parse::<i64>().ok())
        .and_then(|secs| DateTime::<Utc>::from_timestamp(secs, 0))
        .unwrap_or_else(Utc::now);

    let c = app.pool.get().await?;
    if let Some(f) = folder {
        if c.query_opt("SELECT 1 FROM drive_folders WHERE id = $1", &[&f]).await?.is_none() {
            return Ok((StatusCode::BAD_REQUEST, "unknown folder").into_response());
        }
    }

    let dest = blob_path(&app, &hash);
    if tokio::fs::metadata(&dest).await.is_err() {
        tokio::fs::create_dir_all(dest.parent().unwrap()).await?;
        tokio::fs::write(&dest, &body).await?;
    }

    let size = body.len() as i64;
    let mime = ext_mime(&name);
    let existing = c
        .query_opt(
            "SELECT id, hash FROM drive_files
             WHERE folder_id IS NOT DISTINCT FROM $1 AND name = $2 AND trashed_at IS NULL",
            &[&folder, &name],
        )
        .await?;
    let (id, replaced, old_hash): (i64, bool, Option<String>) = match existing {
        Some(r) => {
            let id: i64 = r.get(0);
            let old: String = r.get(1);
            c.execute(
                "UPDATE drive_files SET hash=$2, size_bytes=$3, mime=$4, modified_at=$5, source='iphone'
                 WHERE id = $1",
                &[&id, &hash, &size, &mime, &modified],
            )
            .await?;
            (id, true, (old != hash).then_some(old))
        }
        None => {
            let r = c
                .query_one(
                    "INSERT INTO drive_files (folder_id, name, hash, size_bytes, mime, modified_at, source)
                     VALUES ($1, $2, $3, $4, $5, $6, 'iphone') RETURNING id",
                    &[&folder, &name, &hash, &size, &mime, &modified],
                )
                .await?;
            (r.get(0), false, None)
        }
    };
    drop(c);
    if let Some(old) = old_hash {
        gc_blobs(&app, &[old]).await?;
    }
    // best-effort: fill drive_files.text so the new file is content-searchable
    tokio::spawn(async move {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/atlas".into());
        let _ = tokio::process::Command::new("python3")
            .arg(format!("{home}/atlas/apps/atlas-photos/ingest/extract_drive_text.py"))
            .arg("--file-id")
            .arg(id.to_string())
            .output()
            .await;
    });
    Ok(Json(serde_json::json!({ "id": id, "hash": hash, "replaced": replaced })).into_response())
}

/// Minimal %XX decoder for the X-Filename header (UTF-8 names).
fn percent_decode(s: &str) -> String {
    let mut out = Vec::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if let (Some(h), Some(l)) = (
                bytes.get(i + 1).and_then(|b| (*b as char).to_digit(16)),
                bytes.get(i + 2).and_then(|b| (*b as char).to_digit(16)),
            ) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

// -------------------------------------------------------------- mutations ---

#[derive(Deserialize)]
pub struct NewFolder {
    parent_id: Option<i64>,
    name: String,
}

/// mkdir -p semantics: creating an existing (parent, name) returns its id.
pub async fn folder_create(State(app): State<App>, Json(b): Json<NewFolder>) -> Result<Json<serde_json::Value>, Api> {
    let name = b.name.trim();
    if name.is_empty() {
        return Err(Api("empty name".into()));
    }
    let c = app.pool.get().await?;
    let r = c
        .query_one(
            "INSERT INTO drive_folders (parent_id, name) VALUES ($1, $2)
             ON CONFLICT (parent_id, name) DO UPDATE SET name = EXCLUDED.name
             RETURNING id",
            &[&b.parent_id, &name],
        )
        .await?;
    Ok(Json(serde_json::json!({ "id": r.get::<_, i64>(0) })))
}

#[derive(Deserialize)]
pub struct Rename {
    name: String,
}

pub async fn folder_rename(
    State(app): State<App>,
    Path(id): Path<i64>,
    Json(b): Json<Rename>,
) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let n = c
        .execute("UPDATE drive_folders SET name = $2 WHERE id = $1", &[&id, &b.name.trim()])
        .await?;
    Ok(Json(serde_json::json!({ "updated": n })))
}

/// PERMANENT: removes the folder, its whole subtree and every contained file
/// row (FK cascade), then GCs blobs that lost their last reference. The app
/// confirms this with the item count first.
pub async fn folder_delete(State(app): State<App>, Path(id): Path<i64>) -> Result<Json<serde_json::Value>, Api> {
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
    gc_blobs(&app, &hashes).await?;
    Ok(Json(serde_json::json!({ "deleted": n })))
}

pub async fn file_rename(
    State(app): State<App>,
    Path(id): Path<i64>,
    Json(b): Json<Rename>,
) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let n = c
        .execute("UPDATE drive_files SET name = $2 WHERE id = $1", &[&id, &b.name.trim()])
        .await?;
    Ok(Json(serde_json::json!({ "updated": n })))
}

#[derive(Deserialize)]
pub struct Move {
    #[serde(default)]
    files: Vec<i64>,
    #[serde(default)]
    folders: Vec<i64>,
    to: Option<i64>,
}

/// Move files and/or folders into `to` (null = root). A folder must not move
/// into itself or a descendant.
pub async fn mv(State(app): State<App>, Json(b): Json<Move>) -> Result<Response, Api> {
    let c = app.pool.get().await?;
    if let Some(target) = b.to {
        if c.query_opt("SELECT 1 FROM drive_folders WHERE id = $1", &[&target]).await?.is_none() {
            return Ok((StatusCode::BAD_REQUEST, "unknown folder").into_response());
        }
        if !b.folders.is_empty() {
            let cycle = c
                .query_opt(
                    "WITH RECURSIVE d AS (
                         SELECT id FROM drive_folders WHERE id = ANY($1)
                       UNION ALL
                         SELECT f.id FROM drive_folders f JOIN d ON f.parent_id = d.id
                     )
                     SELECT 1 FROM d WHERE id = $2",
                    &[&b.folders, &target],
                )
                .await?;
            if cycle.is_some() {
                return Ok((StatusCode::BAD_REQUEST, "cannot move a folder into itself").into_response());
            }
        }
    }
    let mut n = 0;
    if !b.files.is_empty() {
        n += c
            .execute("UPDATE drive_files SET folder_id = $2 WHERE id = ANY($1)", &[&b.files, &b.to])
            .await?;
    }
    if !b.folders.is_empty() {
        n += c
            .execute(
                "UPDATE drive_folders SET parent_id = $2 WHERE id = ANY($1)",
                &[&b.folders, &b.to],
            )
            .await?;
    }
    Ok(Json(serde_json::json!({ "updated": n })).into_response())
}

#[derive(Deserialize)]
pub struct Ids {
    ids: Vec<i64>,
}

pub async fn trash_list(State(app): State<App>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let files: Vec<_> = c
        .query(
            &format!(
                "SELECT {FILE_COLS} FROM drive_files
                 WHERE trashed_at IS NOT NULL ORDER BY trashed_at DESC"
            ),
            &[],
        )
        .await?
        .iter()
        .map(file_json)
        .collect();
    Ok(Json(serde_json::json!({ "files": files })))
}

pub async fn trash_put(State(app): State<App>, Json(b): Json<Ids>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let n = c
        .execute("UPDATE drive_files SET trashed_at = now() WHERE id = ANY($1)", &[&b.ids])
        .await?;
    Ok(Json(serde_json::json!({ "updated": n })))
}

pub async fn restore(State(app): State<App>, Json(b): Json<Ids>) -> Result<Json<serde_json::Value>, Api> {
    let c = app.pool.get().await?;
    let n = c
        .execute("UPDATE drive_files SET trashed_at = NULL WHERE id = ANY($1)", &[&b.ids])
        .await?;
    Ok(Json(serde_json::json!({ "updated": n })))
}

/// PERMANENT delete of file rows + blob GC.
pub async fn delete(State(app): State<App>, Json(b): Json<Ids>) -> Result<Json<serde_json::Value>, Api> {
    let n = purge_files(&app, &b.ids).await?;
    Ok(Json(serde_json::json!({ "deleted": n })))
}

pub async fn trash_empty(State(app): State<App>) -> Result<Json<serde_json::Value>, Api> {
    let ids: Vec<i64> = {
        let c = app.pool.get().await?;
        c.query("SELECT id FROM drive_files WHERE trashed_at IS NOT NULL", &[])
            .await?
            .iter()
            .map(|r| r.get(0))
            .collect()
    };
    let n = purge_files(&app, &ids).await?;
    Ok(Json(serde_json::json!({ "deleted": n })))
}

async fn purge_files(app: &App, ids: &Vec<i64>) -> Result<u64, Api> {
    if ids.is_empty() {
        return Ok(0);
    }
    let c = app.pool.get().await?;
    let hashes: Vec<String> = c
        .query("SELECT DISTINCT hash FROM drive_files WHERE id = ANY($1)", &[ids])
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    let n = c.execute("DELETE FROM drive_files WHERE id = ANY($1)", &[ids]).await?;
    drop(c);
    gc_blobs(app, &hashes).await?;
    Ok(n)
}
