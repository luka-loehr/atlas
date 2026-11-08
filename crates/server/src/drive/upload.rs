//! Uploading a file into the tree.

use atlas_core::queue;
use axum::Json;
use axum::body::Body;
use axum::extract::State;
use axum::http::HeaderMap;
use chrono::Utc;
use serde_json::{Value, json};

use super::blobs::{collect_blobs, mime_for};
use super::blob_path;
use crate::upload::{check_claimed_hash, header_time, receive};
use crate::{ApiError, ApiResult, App, AppState, util};

/// PUT /v1/drive/files — the raw file as the body.
///
///   X-Filename       display name (percent-encoded UTF-8)
///   X-Folder-Id      target folder (absent = root)
///   X-Modified-At    unix seconds (optional, default now)
///   X-Content-Hash   SHA-256 the client computed (optional, verified)
///
/// A file of the same name in the same folder is replaced, as on any
/// filesystem; its old blob goes if that was the last reference.
pub(super) async fn upload(State(app): State<AppState>, headers: HeaderMap, body: Body) -> ApiResult<Json<Value>> {
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
