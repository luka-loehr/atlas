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

use axum::Router;
use axum::routing::{get, patch, post, put};
use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use tokio_postgres::Row;

use crate::{ApiError, ApiResult, App, AppState};

mod blobs;
mod browse;
mod organize;
mod trash;
mod upload;

pub use blobs::mime_for;
pub use trash::purge_expired;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/drive/folders", post(organize::folder_create))
        .route("/drive/folders/{id}", get(browse::list).patch(organize::folder_rename).delete(organize::folder_delete))
        .route("/drive/files", put(upload::upload))
        .route("/drive/files/{id}", patch(organize::file_rename))
        .route("/drive/files/{id}/thumb", get(blobs::thumb))
        .route("/drive/blobs/{hash}/{name}", get(blobs::blob))
        .route("/drive/recent", get(browse::recent))
        .route("/drive/search", get(browse::search))
        .route("/drive/move", post(organize::mv))
        .route("/drive/trash", get(trash::list).post(trash::put))
        .route("/drive/trash/empty", post(trash::empty))
        .route("/drive/restore", post(trash::restore))
        .route("/drive/delete", post(trash::delete))
}

pub(super) fn blob_path(app: &App, hash: &str) -> PathBuf {
    app.cfg.blobs_dir().join(hash)
}

pub(super) const FILE_COLS: &str = "df.id, df.name, df.hash, df.size_bytes, df.mime, df.modified_at, df.folder_id";

pub(super) fn file_json(r: &Row) -> Value {
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
pub(super) fn folder_ref(raw: &str) -> ApiResult<Option<i64>> {
    if raw == "root" {
        return Ok(None);
    }
    raw.parse().map(Some).map_err(|_| ApiError::NotFound)
}
