//! The drive's trash: files wait here as long as trashed photos do, then
//! go for good with their blobs.

use axum::Json;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;
use serde_json::{Value, json};

use super::blobs::collect_blobs;
use super::{FILE_COLS, file_json};
use crate::{ApiResult, App, AppState, media};

#[derive(Deserialize)]
pub(super) struct FileIds {
    ids: Vec<i64>,
}

pub(super) async fn list(State(app): State<AppState>, headers: HeaderMap) -> ApiResult<Response> {
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

pub(super) async fn put(
    State(app): State<AppState>,
    Json(b): Json<FileIds>,
) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let n = c
        .execute(
            "UPDATE drive_files SET trashed_at = now() WHERE id = ANY($1)",
            &[&b.ids],
        )
        .await?;
    Ok(Json(json!({ "updated": n })))
}

pub(super) async fn restore(
    State(app): State<AppState>,
    Json(b): Json<FileIds>,
) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let n = c
        .execute(
            "UPDATE drive_files SET trashed_at = NULL WHERE id = ANY($1)",
            &[&b.ids],
        )
        .await?;
    Ok(Json(json!({ "updated": n })))
}

pub(super) async fn delete(
    State(app): State<AppState>,
    Json(b): Json<FileIds>,
) -> ApiResult<Json<Value>> {
    Ok(Json(json!({ "deleted": purge(&app, &b.ids).await? })))
}

pub(super) async fn empty(State(app): State<AppState>) -> ApiResult<Json<Value>> {
    let ids: Vec<i64> = {
        let c = app.pool.get().await?;
        c.query(
            "SELECT id FROM drive_files WHERE trashed_at IS NOT NULL",
            &[],
        )
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect()
    };
    Ok(Json(json!({ "deleted": purge(&app, &ids).await? })))
}

/// Remove drive files that have been in the trash for longer than the
/// photo library keeps its trash.
pub async fn purge_expired(app: &App) -> ApiResult<u64> {
    let ids: Vec<i64> = {
        let c = app.pool.get().await?;
        c.query(
            "SELECT id FROM drive_files WHERE trashed_at < now() - make_interval(days => $1)",
            &[&crate::photos::assets::TRASH_DAYS],
        )
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect()
    };
    purge(app, &ids).await
}

async fn purge(app: &App, ids: &[i64]) -> ApiResult<u64> {
    if ids.is_empty() {
        return Ok(0);
    }
    let c = app.pool.get().await?;
    let hashes: Vec<String> = c
        .query(
            "SELECT DISTINCT hash FROM drive_files WHERE id = ANY($1)",
            &[&ids],
        )
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    let owners: Vec<String> = ids.iter().map(i64::to_string).collect();
    c.execute(
        "DELETE FROM ingest_jobs WHERE owner_type = 'drive_file' AND owner_id = ANY($1)",
        &[&owners],
    )
    .await?;
    let n = c
        .execute("DELETE FROM drive_files WHERE id = ANY($1)", &[&ids])
        .await?;
    drop(c);
    collect_blobs(app, &hashes).await?;
    Ok(n)
}
