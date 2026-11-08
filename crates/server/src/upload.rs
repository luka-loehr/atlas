//! Streaming uploads, shared by the photo library and the drive: the body
//! goes to disk as it arrives, hashed on the way, and the client's own
//! headers are read with suspicion.

use std::path::{Path, PathBuf};

use axum::body::Body;
use axum::http::HeaderMap;
use chrono::{DateTime, Utc};
use futures_util::StreamExt;
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;

use crate::{ApiError, ApiResult, util};

/// A request body written to disk as it arrives, hashed on the way: memory
/// use is one chunk, whatever the upload's size.
pub struct Received {
    pub path: PathBuf,
    pub hash: String,
    pub size: u64,
}

pub async fn receive(body: Body, dir: &Path, limit: u64) -> ApiResult<Received> {
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
    Ok(Received {
        path,
        hash: util::hex(&hasher.finalize()),
        size,
    })
}

/// The claimed hash is an integrity check only: the id is always what the
/// server computed from the bytes it received.
pub fn check_claimed_hash(headers: &HeaderMap, actual: &str) -> ApiResult<()> {
    match headers
        .get("x-content-hash")
        .and_then(|v| v.to_str().ok())
        .map(|h| h.trim().to_ascii_lowercase())
    {
        Some(claimed) if !claimed.is_empty() && claimed != actual => {
            Err(ApiError::BadRequest("X-Content-Hash mismatch"))
        }
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
