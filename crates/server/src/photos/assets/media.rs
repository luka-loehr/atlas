//! An asset's bytes: thumbnails, the grid tile, the original and the
//! stream a player should open.

use std::path::PathBuf;

use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::{ApiError, ApiResult, App, AppState, media, util};

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

/// The grid tile (imaging::make_tile), made on the first request and kept
/// beside the thumbnails. Immutable like them: when the thumbnails are made
/// again, the tile is removed and the asset's thumbhash changes, so the
/// apps ask again.
pub async fn tile(
    State(app): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    if !util::is_content_id(&id) {
        return Err(ApiError::NotFound);
    }
    let path = app.cfg.tile_path(&id);
    if !tokio::fs::try_exists(&path).await.unwrap_or(false) {
        let thumb = app.cfg.thumb_path(&id, 2048);
        if !tokio::fs::try_exists(&thumb).await.unwrap_or(false) {
            return Err(ApiError::NotFound);
        }
        let out = path.clone();
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let bytes = crate::imaging::make_tile(&thumb)?;
            crate::imaging::write_atomic(&out, &bytes)
        })
        .await
        .map_err(|e| ApiError::Internal(anyhow::anyhow!("tile: {e}")))?
        .map_err(ApiError::Internal)?;
    }
    Ok(media::immutable_file(path, headers).await)
}

async fn original_path(app: &App, id: &str) -> ApiResult<PathBuf> {
    if !util::is_content_id(id) {
        return Err(ApiError::NotFound);
    }
    let c = app.pool.get().await?;
    let row = c
        .query_opt("SELECT orig_path FROM assets WHERE id = $1", &[&id])
        .await?
        .ok_or(ApiError::NotFound)?;
    util::confine(
        &app.cfg.photos_dir,
        std::path::Path::new(row.get::<_, &str>(0)),
    )
    .await
    .ok_or(ApiError::NotFound)
}

pub async fn original(
    State(app): State<AppState>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> ApiResult<Response> {
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
    Query(q): Query<VideoQuery>,
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
