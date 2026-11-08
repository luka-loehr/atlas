//! Adding to the library: which content it already has, and the upload
//! itself.

use atlas_core::queue;
use axum::Json;
use axum::body::Body;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::{IntoResponse, Response};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::upload::{Received, check_claimed_hash, header_time, receive};
use crate::{ApiResult, App, AppState, util};

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
pub async fn upload(
    State(app): State<AppState>,
    headers: HeaderMap,
    body: Body,
) -> ApiResult<Response> {
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
    if c.query_opt("SELECT 1 FROM assets WHERE id = $1", &[id])
        .await?
        .is_some()
    {
        return Ok(false);
    }
    let name = util::client_filename(headers.get("x-filename").and_then(|v| v.to_str().ok()));
    let ext = util::media_ext(&name);
    let taken = header_time(headers, "x-taken-at");
    let source = headers
        .get("x-source")
        .and_then(|v| v.to_str().ok())
        .filter(|s| {
            !s.is_empty()
                && s.len() <= 32
                && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        })
        .unwrap_or("iphone");

    let month = taken
        .map(|t| t.format("%Y/%m").to_string())
        .unwrap_or_else(|| "0000/00".into());
    let dir = app.cfg.originals_dir().join(month);
    tokio::fs::create_dir_all(&dir).await?;
    let dest = dir.join(format!("{id}.{ext}"));
    tokio::fs::rename(&received.path, &dest).await?;

    let kind = if util::is_video_ext(ext) {
        "video"
    } else {
        "photo"
    };
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
    // embeddings and faces read the thumbnail: the thumbnail job queues them
    queue::enqueue(&c, queue::THUMB, "asset", id, queue::PRIORITY_INTERACTIVE).await?;
    queue::enqueue(
        &c,
        queue::META,
        "asset",
        id,
        queue::PRIORITY_INTERACTIVE + 10,
    )
    .await?;
    app.jobs_wake.notify_waiters();
    Ok(inserted > 0)
}
