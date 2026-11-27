//! Core object operations: streaming upload (`put`), zero-copy Range-capable
//! download (`get`/`head`), `stat`, `list` (S3 ListObjectsV2 semantics + search),
//! server-side `copy`, single & batch `delete`, and unreferenced blob GC.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use atlas_common::crypto::{md5_hex, sha256_hex};
use atlas_common::models::{ListObjectsResponse, ObjectInfo, PutObjectResponse};
use atlas_common::s3::{
    STREAMING_SHA256_PAYLOAD, STREAMING_UNSIGNED_PAYLOAD_TRAILER, decode_aws_chunked_bytes,
};
use atlas_common::validate::normalize_object_key;
use axum::body::Body;
use axum::http::{HeaderMap, HeaderValue, Request, StatusCode, header};
use axum::response::{IntoResponse, Response};
use chrono::Utc;
use futures_util::StreamExt;
use md5::Md5;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use tokio_postgres::Row;
use tower::ServiceExt;
use tower_http::services::ServeFile;

use super::bridge::{ingest_media_bucket_object, sync_files_object_to_drive};
use super::buckets::{bucket_exists, enforce_quotas};
use crate::drive::mime_for;
use crate::iam::Principal;
use crate::{ApiError, ApiResult, App, util};

pub const OBJECT_COLS: &str = "o.bucket, o.key, o.size_bytes, o.etag, o.sha256, o.content_type, o.custom_metadata, o.asset_id, o.drive_file_id, o.created_at, o.updated_at";

pub fn object_from_row(r: &Row) -> ObjectInfo {
    let meta_val: Value = r.get(6);
    let mut metadata = BTreeMap::new();
    if let Some(obj) = meta_val.as_object() {
        for (k, v) in obj {
            if let Some(s) = v.as_str() {
                metadata.insert(k.clone(), s.to_string());
            } else {
                metadata.insert(k.clone(), v.to_string());
            }
        }
    }
    ObjectInfo {
        bucket: r.get(0),
        key: r.get(1),
        size: r.get(2),
        etag: r.get(3),
        sha256: r.get(4),
        content_type: r.get(5),
        metadata,
        asset_id: r.get(7),
        drive_file_id: r.get(8),
        snippet: None,
        created_at: r.get(9),
        updated_at: r.get(10),
    }
}

/// Extracts `x-amz-meta-*` headers into a clean lowercase key/value map (max 32 entries, 4 KB total).
pub fn extract_custom_metadata(headers: &HeaderMap) -> ApiResult<BTreeMap<String, String>> {
    let mut meta = BTreeMap::new();
    let mut total = 0usize;
    for (name, val) in headers {
        if let Some(suffix) = name.as_str().strip_prefix("x-amz-meta-") {
            let clean_key = suffix.trim().to_ascii_lowercase();
            if clean_key.is_empty() || meta.len() >= 32 {
                continue;
            }
            let val_str = val
                .to_str()
                .map_err(|_| ApiError::BadRequest("non-ASCII x-amz-meta header"))?
                .trim();
            total += clean_key.len() + val_str.len();
            if total > 4096 {
                return Err(ApiError::BadRequest("custom metadata exceeds 4 KB limit"));
            }
            meta.insert(clean_key, val_str.to_string());
        }
    }
    Ok(meta)
}

pub struct StreamedTemp {
    pub path: PathBuf,
    pub sha256: String,
    pub md5: String,
    pub size: u64,
}

/// Streams an HTTP request body to disk (decoding `aws-chunked` if `x-amz-content-sha256`
/// uses `STREAMING-AWS4-HMAC-SHA256-PAYLOAD`), computing both SHA-256 and MD5 on the fly.
pub async fn stream_body_to_temp(
    body: Body,
    headers: &HeaderMap,
    temp_dir: &Path,
    max_bytes: u64,
) -> ApiResult<StreamedTemp> {
    tokio::fs::create_dir_all(temp_dir).await?;
    let path = temp_dir.join(util::temp_name("s3put"));

    let is_aws_chunked = headers
        .get("x-amz-content-sha256")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v == STREAMING_SHA256_PAYLOAD || v == STREAMING_UNSIGNED_PAYLOAD_TRAILER)
        || headers
            .get(header::CONTENT_ENCODING)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.contains("aws-chunked"));

    if is_aws_chunked {
        // Stream into bounded buffer or chunk-frame state machine
        let mut raw = Vec::new();
        let mut stream = body.into_data_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|_| ApiError::BadRequest("upload stream interrupted"))?;
            if (raw.len() + chunk.len()) as u64 > max_bytes.saturating_add(16 * 1024 * 1024) {
                return Err(ApiError::TooLarge);
            }
            raw.extend_from_slice(&chunk);
        }
        let decoded = decode_aws_chunked_bytes(&raw)
            .map_err(|_| ApiError::BadRequest("malformed aws-chunked body"))?;
        if decoded.len() as u64 > max_bytes {
            return Err(ApiError::TooLarge);
        }
        let sha256 = sha256_hex(&decoded);
        let md5 = md5_hex(&decoded);
        tokio::fs::write(&path, &decoded).await?;
        return Ok(StreamedTemp {
            path,
            sha256,
            md5,
            size: decoded.len() as u64,
        });
    }

    let mut file = tokio::fs::File::create(&path).await?;
    let mut sha = Sha256::new();
    let mut md5 = Md5::new();
    let mut size = 0u64;
    let mut stream = body.into_data_stream();

    let res: ApiResult<()> = async {
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|_| ApiError::BadRequest("upload stream interrupted"))?;
            size += chunk.len() as u64;
            if size > max_bytes {
                return Err(ApiError::TooLarge);
            }
            sha.update(&chunk);
            md5.update(&chunk);
            file.write_all(&chunk).await?;
        }
        file.sync_all().await?;
        Ok(())
    }
    .await;

    if let Err(e) = res {
        drop(file);
        let _ = tokio::fs::remove_file(&path).await;
        return Err(e);
    }

    let sha_hex = util::hex(&sha.finalize());
    let md5_hex_str = util::hex(&md5.finalize());

    // Verify optional integrity headers if supplied by client
    if let Some(claimed_sha) = headers
        .get("x-amz-content-sha256")
        .or_else(|| headers.get("x-content-hash"))
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim().to_ascii_lowercase())
        && claimed_sha.len() == 64
        && claimed_sha != sha_hex
    {
        let _ = tokio::fs::remove_file(&path).await;
        return Err(ApiError::BadRequest("SHA-256 content digest mismatch"));
    }

    Ok(StreamedTemp {
        path,
        sha256: sha_hex,
        md5: md5_hex_str,
        size,
    })
}

/// Stores a completed temporary file (`temp_path`) as `(bucket, raw_key)`, handling
/// content-addressed blob deduplication, `media` asset ingestion, and `files` drive sync.
#[allow(clippy::too_many_arguments)]
pub async fn commit_object_from_temp(
    app: &App,
    principal: &Principal,
    bucket: &str,
    raw_key: &str,
    temp_path: &Path,
    sha256: &str,
    etag: &str,
    size: u64,
    content_type_override: Option<&str>,
    custom_metadata: BTreeMap<String, String>,
) -> ApiResult<PutObjectResponse> {
    let key = normalize_object_key(raw_key).ok_or(ApiError::BadRequest("invalid object key"))?;
    principal.require_bucket(bucket, "write")?;
    let Some(_kind) = bucket_exists(app, bucket).await? else {
        return Err(ApiError::NotFound);
    };
    enforce_quotas(app, principal, bucket, size).await?;

    let content_type = content_type_override
        .map(str::trim)
        .filter(|s| !s.is_empty() && *s != "binary/octet-stream")
        .map(str::to_string)
        .unwrap_or_else(|| mime_for(&key).to_string());

    // 1. If bucket == "media", ingest supported photos/videos into `assets`
    let asset_id = if bucket == "media" {
        ingest_media_bucket_object(app, &key, sha256, size, temp_path, None).await?
    } else {
        None
    };

    // 2. If not backed solely by `assets`, move into content-addressed `<blobs_dir>/<sha256>`
    if asset_id.is_none() {
        tokio::fs::create_dir_all(app.cfg.blobs_dir()).await?;
        let blob_dest = app.cfg.blobs_dir().join(sha256);
        if !tokio::fs::try_exists(&blob_dest).await.unwrap_or(false) {
            tokio::fs::rename(temp_path, &blob_dest).await?;
        }
    }
    let _ = tokio::fs::remove_file(temp_path).await;

    // 3. If bucket == "files", sync into `drive_folders` + `drive_files` + text extraction queue
    let now = Utc::now();
    let drive_file_id = if bucket == "files" {
        sync_files_object_to_drive(app, &key, sha256, size as i64, &content_type, now).await?
    } else {
        None
    };

    let meta_json =
        serde_json::to_value(&custom_metadata).unwrap_or(Value::Object(Default::default()));
    let c = app.pool.get().await?;
    let prev_sha: Option<String> = c
        .query_opt(
            "SELECT sha256 FROM objects WHERE bucket = $1 AND key = $2",
            &[&bucket, &key],
        )
        .await?
        .map(|r| r.get(0));

    c.execute(
        "INSERT INTO objects (
            bucket, key, sha256, etag, size_bytes, content_type,
            custom_metadata, asset_id, drive_file_id, owner_account_id, trashed_at, updated_at
         )
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NULL, $11)
         ON CONFLICT (bucket, key) DO UPDATE
           SET sha256 = EXCLUDED.sha256,
               etag = EXCLUDED.etag,
               size_bytes = EXCLUDED.size_bytes,
               content_type = EXCLUDED.content_type,
               custom_metadata = EXCLUDED.custom_metadata,
               asset_id = EXCLUDED.asset_id,
               drive_file_id = EXCLUDED.drive_file_id,
               owner_account_id = EXCLUDED.owner_account_id,
               trashed_at = NULL,
               updated_at = EXCLUDED.updated_at",
        &[
            &bucket,
            &key,
            &sha256,
            &etag,
            &(size as i64),
            &content_type,
            &meta_json,
            &asset_id,
            &drive_file_id,
            &principal.account_id,
            &now,
        ],
    )
    .await?;
    drop(c);

    if let Some(old) = prev_sha
        && old != sha256
    {
        gc_unreferenced_blobs(app, &[old]).await?;
    }

    Ok(PutObjectResponse {
        bucket: bucket.to_string(),
        key,
        size: size as i64,
        etag: etag.to_string(),
        sha256: sha256.to_string(),
        content_type,
        asset_id,
        drive_file_id,
    })
}

pub async fn put_object_streaming(
    app: &App,
    principal: &Principal,
    bucket: &str,
    raw_key: &str,
    headers: &HeaderMap,
    body: Body,
) -> ApiResult<PutObjectResponse> {
    let key = normalize_object_key(raw_key).ok_or(ApiError::BadRequest("invalid object key"))?;
    principal.require_bucket(bucket, "write")?;
    if bucket_exists(app, bucket).await?.is_none() {
        return Err(ApiError::NotFound);
    }

    let meta = extract_custom_metadata(headers)?;
    let temp_dir = app.cfg.blobs_dir().join(".incoming");
    let streamed = stream_body_to_temp(body, headers, &temp_dir, app.cfg.max_upload).await?;
    let etag = format!("\"{}\"", streamed.md5);
    let ct = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok());

    let res = commit_object_from_temp(
        app,
        principal,
        bucket,
        &key,
        &streamed.path,
        &streamed.sha256,
        &etag,
        streamed.size,
        ct,
        meta,
    )
    .await;
    let _ = tokio::fs::remove_file(&streamed.path).await;
    res
}

pub async fn stat_object(
    app: &App,
    principal: &Principal,
    bucket: &str,
    raw_key: &str,
) -> ApiResult<ObjectInfo> {
    let key = normalize_object_key(raw_key).ok_or(ApiError::NotFound)?;
    principal.require_bucket(bucket, "read")?;
    let c = app.pool.get().await?;
    let row = c
        .query_opt(
            &format!(
                "SELECT {OBJECT_COLS}
                   FROM objects o
                  WHERE o.bucket = $1 AND o.key = $2 AND o.trashed_at IS NULL"
            ),
            &[&bucket, &key],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    Ok(object_from_row(&row))
}

async fn resolve_object_disk_path(app: &App, info: &ObjectInfo) -> ApiResult<PathBuf> {
    if let Some(ref asset_id) = info.asset_id {
        let c = app.pool.get().await?;
        if let Some(row) = c
            .query_opt("SELECT orig_path FROM assets WHERE id = $1", &[asset_id])
            .await?
        {
            let orig: String = row.get(0);
            if let Some(confined) = util::confine(&app.cfg.photos_dir, Path::new(&orig)).await {
                return Ok(confined);
            }
        }
    }
    if !util::is_content_id(&info.sha256) {
        return Err(ApiError::NotFound);
    }
    let blob = app.cfg.blobs_dir().join(&info.sha256);
    if tokio::fs::try_exists(&blob).await.unwrap_or(false) {
        Ok(blob)
    } else {
        Err(ApiError::NotFound)
    }
}

fn inline_safe_mime(mime: &str) -> bool {
    (mime.starts_with("image/") && mime != "image/svg+xml")
        || mime.starts_with("video/")
        || mime.starts_with("audio/")
        || matches!(
            mime,
            "application/pdf"
                | "text/plain; charset=utf-8"
                | "text/plain"
                | "text/csv"
                | "application/json"
        )
}

fn append_object_headers(resp: &mut Response, info: &ObjectInfo) {
    let h = resp.headers_mut();
    if let Ok(v) = HeaderValue::from_str(&info.content_type) {
        h.insert(header::CONTENT_TYPE, v);
    }
    if let Ok(v) = HeaderValue::from_str(&info.etag) {
        h.insert(header::ETAG, v);
    }
    if let Ok(v) = HeaderValue::from_str(&info.updated_at.to_rfc2822()) {
        h.insert(header::LAST_MODIFIED, v);
    }
    h.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    h.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    if let Ok(v) = HeaderValue::from_str(&info.sha256) {
        h.insert("x-atlas-sha256", v);
    }
    if let Some(ref aid) = info.asset_id
        && let Ok(v) = HeaderValue::from_str(aid)
    {
        h.insert("x-atlas-asset-id", v);
    }
    for (mk, mv) in &info.metadata {
        if let (Ok(hn), Ok(hv)) = (
            axum::http::HeaderName::from_bytes(format!("x-amz-meta-{mk}").as_bytes()),
            HeaderValue::from_str(mv),
        ) {
            h.insert(hn, hv);
        }
    }

    let file_name = info.key.rsplit('/').next().unwrap_or(&info.key);
    let disp = if inline_safe_mime(&info.content_type) {
        "inline"
    } else {
        "attachment"
    };
    let ascii: String = file_name
        .chars()
        .map(|ch| {
            if ch.is_ascii() && ch != '"' && ch != '\\' && !ch.is_control() {
                ch
            } else {
                '_'
            }
        })
        .collect();
    if let Ok(v) = HeaderValue::from_str(&format!("{disp}; filename=\"{ascii}\"")) {
        h.insert(header::CONTENT_DISPOSITION, v);
    }
}

/// Serves an object (`GET` or `HEAD`) with zero-copy Range support (`206 Partial Content`),
/// `If-None-Match` (`304 Not Modified`), `If-Match` (`412`), and custom `x-amz-meta-*` headers.
pub async fn serve_object(
    app: &App,
    principal: &Principal,
    bucket: &str,
    raw_key: &str,
    req_headers: HeaderMap,
    head_only: bool,
) -> ApiResult<Response> {
    let info = stat_object(app, principal, bucket, raw_key).await?;

    if let Some(if_match) = req_headers
        .get(header::IF_MATCH)
        .and_then(|v| v.to_str().ok())
        && if_match.trim() != "*"
        && !if_match.split(',').any(|c| c.trim() == info.etag)
    {
        return Ok(StatusCode::PRECONDITION_FAILED.into_response());
    }

    if let Some(inm) = req_headers
        .get(header::IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
        && inm
            .split(',')
            .any(|c| c.trim() == info.etag || c.trim() == "*")
    {
        let mut resp = StatusCode::NOT_MODIFIED.into_response();
        append_object_headers(&mut resp, &info);
        return Ok(resp);
    }

    let disk_path = resolve_object_disk_path(app, &info).await?;

    if head_only {
        let mut resp = StatusCode::OK.into_response();
        append_object_headers(&mut resp, &info);
        if let Ok(v) = HeaderValue::from_str(&info.size.to_string()) {
            resp.headers_mut().insert(header::CONTENT_LENGTH, v);
        }
        return Ok(resp);
    }

    // Forward Range header to ServeFile (strip If-None-Match since we already validated our ETag)
    let mut sf_headers = HeaderMap::new();
    if let Some(range) = req_headers.get(header::RANGE) {
        sf_headers.insert(header::RANGE, range.clone());
    }
    let mut sub_req = Request::new(Body::empty());
    *sub_req.headers_mut() = sf_headers;

    match ServeFile::new(disk_path).oneshot(sub_req).await {
        Ok(resp) if resp.status() != StatusCode::NOT_FOUND => {
            let mut resp = resp.into_response();
            append_object_headers(&mut resp, &info);
            Ok(resp)
        }
        _ => Err(ApiError::NotFound),
    }
}

pub struct ListParams {
    pub prefix: String,
    pub delimiter: Option<String>,
    pub start_after: Option<String>,
    pub max_keys: usize,
    pub search_query: Option<String>,
}

/// Lists objects in `bucket` using S3 `ListObjectsV2` semantics (`prefix`, `delimiter`,
/// `start_after`/cursor, `max_keys`) plus optional `q` full-text/key search.
pub async fn list_objects(
    app: &App,
    principal: &Principal,
    bucket: &str,
    params: ListParams,
) -> ApiResult<ListObjectsResponse> {
    principal.require_bucket(bucket, "read")?;
    if bucket_exists(app, bucket).await?.is_none() {
        return Err(ApiError::NotFound);
    }

    let max_keys = params.max_keys.clamp(1, 1000);
    let prefix = params.prefix.trim_start_matches('/').to_string();
    let c = app.pool.get().await?;

    // Search mode (`?q=...`): matches object key OR extracted PDF/doc text in `drive_files`
    if let Some(ref q_raw) = params.search_query {
        let term = q_raw.trim();
        if term.is_empty() {
            return Ok(ListObjectsResponse {
                bucket: bucket.to_string(),
                prefix,
                delimiter: params.delimiter,
                common_prefixes: vec![],
                objects: vec![],
                is_truncated: false,
                next_cursor: None,
            });
        }
        let like = format!("%{}%", util::like_escape(term));
        let prefix_like = format!("{}%", util::like_escape(&prefix));
        let rows = c
            .query(
                &format!(
                    "SELECT {OBJECT_COLS}, df.text
                       FROM objects o
                       LEFT JOIN drive_files df ON df.id = o.drive_file_id
                      WHERE o.bucket = $1
                        AND o.trashed_at IS NULL
                        AND o.key LIKE $2
                        AND (o.key ILIKE $3 OR df.text ILIKE $3)
                      ORDER BY o.updated_at DESC
                      LIMIT $4"
                ),
                &[&bucket, &prefix_like, &like, &(max_keys as i64)],
            )
            .await?;

        let objects = rows
            .iter()
            .map(|r| {
                let mut obj = object_from_row(r);
                if let Some(txt) = r.get::<_, Option<&str>>(11) {
                    let s = crate::drive::fast_snippet(txt, term);
                    if !s.is_empty() {
                        obj.snippet = Some(s);
                    }
                }
                obj
            })
            .collect();

        return Ok(ListObjectsResponse {
            bucket: bucket.to_string(),
            prefix,
            delimiter: None,
            common_prefixes: vec![],
            objects,
            is_truncated: false,
            next_cursor: None,
        });
    }

    let prefix_like = format!("{}%", util::like_escape(&prefix));
    let after = params.start_after.unwrap_or_default();

    // When no delimiter is used, a single indexed range scan with LIMIT max_keys + 1 suffices.
    let Some(ref delim) = params.delimiter.filter(|d| !d.is_empty()) else {
        let fetch = (max_keys + 1) as i64;
        let rows = c
            .query(
                &format!(
                    "SELECT {OBJECT_COLS}
                       FROM objects o
                      WHERE o.bucket = $1
                        AND o.trashed_at IS NULL
                        AND o.key LIKE $2
                        AND o.key > $3
                      ORDER BY o.key ASC
                      LIMIT $4"
                ),
                &[&bucket, &prefix_like, &after, &fetch],
            )
            .await?;

        let is_truncated = rows.len() > max_keys;
        let objects: Vec<ObjectInfo> = rows.iter().take(max_keys).map(object_from_row).collect();
        let next_cursor = is_truncated
            .then(|| objects.last().map(|o| o.key.clone()))
            .flatten();
        return Ok(ListObjectsResponse {
            bucket: bucket.to_string(),
            prefix,
            delimiter: None,
            common_prefixes: vec![],
            objects,
            is_truncated,
            next_cursor,
        });
    };

    // Delimiter mode (typically `/`): fold keys under common prefixes up to `max_keys` combined entries.
    let rows = c
        .query(
            &format!(
                "SELECT {OBJECT_COLS}
                   FROM objects o
                  WHERE o.bucket = $1
                    AND o.trashed_at IS NULL
                    AND o.key LIKE $2
                    AND o.key > $3
                  ORDER BY o.key ASC
                  LIMIT 10000"
            ),
            &[&bucket, &prefix_like, &after],
        )
        .await?;

    let mut common_set = BTreeSet::new();
    let mut objects = Vec::new();
    let mut is_truncated = false;
    let mut next_cursor = None;

    for r in &rows {
        let key: &str = r.get(1);
        let rest = key.strip_prefix(&prefix).unwrap_or(key);
        if let Some(idx) = rest.find(delim.as_str()) {
            let cp = format!("{prefix}{}", &rest[..idx + delim.len()]);
            if !common_set.contains(&cp) {
                if common_set.len() + objects.len() >= max_keys {
                    is_truncated = true;
                    next_cursor = Some(cp);
                    break;
                }
                common_set.insert(cp);
            }
        } else {
            if common_set.len() + objects.len() >= max_keys {
                is_truncated = true;
                next_cursor = objects
                    .last()
                    .map(|o: &ObjectInfo| o.key.clone())
                    .or_else(|| common_set.iter().next_back().cloned());
                break;
            }
            objects.push(object_from_row(r));
        }
    }

    Ok(ListObjectsResponse {
        bucket: bucket.to_string(),
        prefix,
        delimiter: Some(delim.clone()),
        common_prefixes: common_set.into_iter().collect(),
        objects,
        is_truncated,
        next_cursor,
    })
}

/// Server-side zero-reupload `CopyObject` across or within buckets.
pub async fn copy_object(
    app: &App,
    principal: &Principal,
    src_bucket: &str,
    raw_src_key: &str,
    dst_bucket: &str,
    raw_dst_key: &str,
    metadata_override: Option<BTreeMap<String, String>>,
) -> ApiResult<PutObjectResponse> {
    let src_info = stat_object(app, principal, src_bucket, raw_src_key).await?;
    let dst_key =
        normalize_object_key(raw_dst_key).ok_or(ApiError::BadRequest("invalid destination key"))?;
    principal.require_bucket(dst_bucket, "write")?;
    if bucket_exists(app, dst_bucket).await?.is_none() {
        return Err(ApiError::NotFound);
    }
    enforce_quotas(app, principal, dst_bucket, src_info.size.max(0) as u64).await?;

    let src_disk = resolve_object_disk_path(app, &src_info).await?;

    // Ensure blob exists if copying an asset from `media` into a non-media bucket
    let asset_id = if dst_bucket == "media" {
        if src_info.asset_id.is_some() {
            src_info.asset_id.clone()
        } else {
            ingest_media_bucket_object(
                app,
                &dst_key,
                &src_info.sha256,
                src_info.size.max(0) as u64,
                &src_disk,
                None,
            )
            .await?
        }
    } else {
        let blob_dest = app.cfg.blobs_dir().join(&src_info.sha256);
        if !tokio::fs::try_exists(&blob_dest).await.unwrap_or(false) {
            tokio::fs::create_dir_all(app.cfg.blobs_dir()).await?;
            if tokio::fs::hard_link(&src_disk, &blob_dest).await.is_err() {
                let tmp = app.cfg.blobs_dir().join(util::temp_name("copy"));
                tokio::fs::copy(&src_disk, &tmp).await?;
                tokio::fs::rename(&tmp, &blob_dest).await?;
            }
        }
        None
    };

    let now = Utc::now();
    let drive_file_id = if dst_bucket == "files" {
        sync_files_object_to_drive(
            app,
            &dst_key,
            &src_info.sha256,
            src_info.size,
            &src_info.content_type,
            now,
        )
        .await?
    } else {
        None
    };

    let meta = metadata_override.unwrap_or(src_info.metadata);
    let meta_json = serde_json::to_value(&meta).unwrap_or(Value::Object(Default::default()));

    let c = app.pool.get().await?;
    c.execute(
        "INSERT INTO objects (
            bucket, key, sha256, etag, size_bytes, content_type,
            custom_metadata, asset_id, drive_file_id, owner_account_id, trashed_at, updated_at
         )
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NULL, $11)
         ON CONFLICT (bucket, key) DO UPDATE
           SET sha256 = EXCLUDED.sha256,
               etag = EXCLUDED.etag,
               size_bytes = EXCLUDED.size_bytes,
               content_type = EXCLUDED.content_type,
               custom_metadata = EXCLUDED.custom_metadata,
               asset_id = EXCLUDED.asset_id,
               drive_file_id = EXCLUDED.drive_file_id,
               owner_account_id = EXCLUDED.owner_account_id,
               trashed_at = NULL,
               updated_at = EXCLUDED.updated_at",
        &[
            &dst_bucket,
            &dst_key,
            &src_info.sha256,
            &src_info.etag,
            &src_info.size,
            &src_info.content_type,
            &meta_json,
            &asset_id,
            &drive_file_id,
            &principal.account_id,
            &now,
        ],
    )
    .await?;

    Ok(PutObjectResponse {
        bucket: dst_bucket.to_string(),
        key: dst_key,
        size: src_info.size,
        etag: src_info.etag,
        sha256: src_info.sha256,
        content_type: src_info.content_type,
        asset_id,
        drive_file_id,
    })
}

/// Deletes one or more objects from `bucket`, syncing `drive_files` if `bucket == "files"`,
/// and garbage-collecting unreferenced content-addressed blobs.
pub async fn delete_objects(
    app: &App,
    principal: &Principal,
    bucket: &str,
    raw_keys: &[String],
) -> ApiResult<Vec<String>> {
    principal.require_bucket(bucket, "delete")?;
    if raw_keys.len() > 1000 {
        return Err(ApiError::BadRequest("at most 1000 keys per batch delete"));
    }
    let clean_keys: Vec<String> = raw_keys
        .iter()
        .filter_map(|k| normalize_object_key(k))
        .collect();
    if clean_keys.is_empty() {
        return Ok(vec![]);
    }

    let c = app.pool.get().await?;
    let rows = c
        .query(
            "DELETE FROM objects
              WHERE bucket = $1 AND key = ANY($2)
              RETURNING key, sha256, drive_file_id",
            &[&bucket, &clean_keys],
        )
        .await?;

    let mut deleted_keys = Vec::with_capacity(rows.len());
    let mut candidate_hashes = Vec::with_capacity(rows.len());
    let mut drive_ids = Vec::new();
    for r in rows {
        deleted_keys.push(r.get::<_, String>(0));
        candidate_hashes.push(r.get::<_, String>(1));
        if let Some(df_id) = r.get::<_, Option<i64>>(2) {
            drive_ids.push(df_id);
        }
    }

    if !drive_ids.is_empty() {
        let owners: Vec<String> = drive_ids.iter().map(i64::to_string).collect();
        c.execute(
            "DELETE FROM ingest_jobs WHERE owner_type = 'drive_file' AND owner_id = ANY($1)",
            &[&owners],
        )
        .await?;
        c.execute("DELETE FROM drive_files WHERE id = ANY($1)", &[&drive_ids])
            .await?;
    }
    drop(c);

    gc_unreferenced_blobs(app, &candidate_hashes).await?;
    Ok(deleted_keys)
}

/// Removes content-addressed blobs from `<blobs_dir>` ONLY when neither `objects`
/// (across all buckets) nor `drive_files` references their SHA-256 anymore.
pub async fn gc_unreferenced_blobs(app: &App, hashes: &[String]) -> ApiResult<()> {
    if hashes.is_empty() {
        return Ok(());
    }
    let c = app.pool.get().await?;
    let referenced: BTreeSet<String> = c
        .query(
            "SELECT hash FROM drive_files WHERE hash = ANY($1)
             UNION
             SELECT sha256 FROM objects WHERE sha256 = ANY($1)",
            &[&hashes],
        )
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    drop(c);

    for hash in hashes {
        if !referenced.contains(hash) && util::is_content_id(hash) {
            let _ = tokio::fs::remove_file(app.cfg.blobs_dir().join(hash)).await;
            let _ = tokio::fs::remove_file(app.cfg.drive_thumbs_dir().join(format!("{hash}.webp")))
                .await;
        }
    }
    Ok(())
}
