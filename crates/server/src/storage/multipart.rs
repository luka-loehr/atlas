//! Streaming S3 Multipart Upload lifecycle (`create`, `upload_part`, `complete`,
//! `abort`, `list_uploads`, `list_parts`).

use std::collections::BTreeMap;
use std::path::PathBuf;

use atlas_common::crypto::{generate_prefixed_id, hex_decode, md5_hex};
use atlas_common::models::PutObjectResponse;
use atlas_common::validate::normalize_object_key;
use axum::body::Body;
use axum::http::HeaderMap;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::buckets::bucket_exists;
use super::objects::{commit_object_from_temp, extract_custom_metadata, stream_body_to_temp};
use crate::drive::mime_for;
use crate::iam::Principal;
use crate::{ApiError, ApiResult, App, util};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MultipartUploadInfo {
    pub upload_id: String,
    pub bucket: String,
    pub key: String,
    pub content_type: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MultipartPartInfo {
    pub part_number: i32,
    pub etag: String,
    pub sha256: String,
    pub size: i64,
    pub created_at: DateTime<Utc>,
}

fn upload_dir(app: &App, upload_id: &str) -> PathBuf {
    app.cfg.multipart_dir().join(upload_id)
}

pub async fn create_multipart(
    app: &App,
    principal: &Principal,
    bucket: &str,
    raw_key: &str,
    headers: &HeaderMap,
) -> ApiResult<MultipartUploadInfo> {
    let key = normalize_object_key(raw_key).ok_or(ApiError::BadRequest("invalid object key"))?;
    principal.require_bucket(bucket, "write")?;
    if bucket_exists(app, bucket).await?.is_none() {
        return Err(ApiError::NotFound);
    }

    let upload_id = generate_prefixed_id("mpu", 12)?;
    let meta = extract_custom_metadata(headers)?;
    let meta_json = serde_json::to_value(&meta).unwrap_or(Value::Object(Default::default()));
    let content_type = headers
        .get(axum::http::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
        .filter(|s| !s.is_empty() && *s != "binary/octet-stream")
        .map(str::to_string)
        .unwrap_or_else(|| mime_for(&key).to_string());

    tokio::fs::create_dir_all(upload_dir(app, &upload_id)).await?;

    let c = app.pool.get().await?;
    let row = c
        .query_one(
            "INSERT INTO multipart_uploads (upload_id, bucket, key, content_type, custom_metadata, owner_account_id)
             VALUES ($1, $2, $3, $4, $5, $6)
             RETURNING created_at",
            &[
                &upload_id,
                &bucket,
                &key,
                &content_type,
                &meta_json,
                &principal.account_id,
            ],
        )
        .await?;

    Ok(MultipartUploadInfo {
        upload_id,
        bucket: bucket.to_string(),
        key,
        content_type,
        created_at: row.get(0),
    })
}

#[allow(clippy::too_many_arguments)]
pub async fn upload_part(
    app: &App,
    principal: &Principal,
    bucket: &str,
    raw_key: &str,
    upload_id: &str,
    part_number: i32,
    headers: &HeaderMap,
    body: Body,
) -> ApiResult<MultipartPartInfo> {
    if !(1..=10000).contains(&part_number) {
        return Err(ApiError::BadRequest(
            "partNumber must be between 1 and 10000",
        ));
    }
    let key = normalize_object_key(raw_key).ok_or(ApiError::BadRequest("invalid object key"))?;
    principal.require_bucket(bucket, "write")?;

    let c = app.pool.get().await?;
    let up = c
        .query_opt(
            "SELECT bucket, key FROM multipart_uploads WHERE upload_id = $1",
            &[&upload_id],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    let (up_bucket, up_key): (String, String) = (up.get(0), up.get(1));
    if up_bucket != bucket || up_key != key {
        return Err(ApiError::NotFound);
    }
    drop(c);

    let dir = upload_dir(app, upload_id);
    let streamed = stream_body_to_temp(body, headers, &dir, app.cfg.max_upload).await?;
    let final_part_path = dir.join(format!("part-{part_number:05}"));
    tokio::fs::rename(&streamed.path, &final_part_path).await?;
    let etag = format!("\"{}\"", streamed.md5);

    let c = app.pool.get().await?;
    let row = c
        .query_one(
            "INSERT INTO multipart_parts (upload_id, part_number, sha256, etag, size_bytes, temp_path)
             VALUES ($1, $2, $3, $4, $5, $6)
             ON CONFLICT (upload_id, part_number) DO UPDATE
               SET sha256 = EXCLUDED.sha256,
                   etag = EXCLUDED.etag,
                   size_bytes = EXCLUDED.size_bytes,
                   temp_path = EXCLUDED.temp_path,
                   created_at = now()
             RETURNING created_at",
            &[
                &upload_id,
                &part_number,
                &streamed.sha256,
                &etag,
                &(streamed.size as i64),
                &final_part_path.to_string_lossy().as_ref(),
            ],
        )
        .await?;

    Ok(MultipartPartInfo {
        part_number,
        etag,
        sha256: streamed.sha256,
        size: streamed.size as i64,
        created_at: row.get(0),
    })
}

/// Concatenates uploaded parts in ascending order into a content-addressed object,
/// computing both overall SHA-256 and standard S3 multipart ETag `"{md5_of_md5s}-{count}"`.
pub async fn complete_multipart(
    app: &App,
    principal: &Principal,
    bucket: &str,
    raw_key: &str,
    upload_id: &str,
    requested_parts: Option<&[(i32, String)]>,
) -> ApiResult<PutObjectResponse> {
    let key = normalize_object_key(raw_key).ok_or(ApiError::BadRequest("invalid object key"))?;
    principal.require_bucket(bucket, "write")?;

    let c = app.pool.get().await?;
    let up = c
        .query_opt(
            "SELECT bucket, key, content_type, custom_metadata
               FROM multipart_uploads WHERE upload_id = $1",
            &[&upload_id],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    let (up_bucket, up_key, content_type, meta_val): (String, String, String, Value) =
        (up.get(0), up.get(1), up.get(2), up.get(3));
    if up_bucket != bucket || up_key != key {
        return Err(ApiError::NotFound);
    }

    let part_rows = c
        .query(
            "SELECT part_number, etag, size_bytes, temp_path
               FROM multipart_parts
              WHERE upload_id = $1
              ORDER BY part_number ASC",
            &[&upload_id],
        )
        .await?;
    drop(c);

    if part_rows.is_empty() {
        return Err(ApiError::BadRequest("multipart upload has no parts"));
    }

    let mut by_num: BTreeMap<i32, (String, i64, String)> = BTreeMap::new();
    for r in part_rows {
        by_num.insert(r.get(0), (r.get(1), r.get(2), r.get(3)));
    }

    let ordered: Vec<(i32, String, String)> = if let Some(req_list) = requested_parts
        && !req_list.is_empty()
    {
        let mut prev = 0;
        let mut out = Vec::with_capacity(req_list.len());
        for (pn, req_etag) in req_list {
            if *pn <= prev {
                return Err(ApiError::BadRequest(
                    "parts must be in strictly ascending order",
                ));
            }
            prev = *pn;
            let Some((stored_etag, _, path)) = by_num.get(pn) else {
                return Err(ApiError::BadRequest("referenced part was not uploaded"));
            };
            let clean_req = req_etag.trim().trim_matches('"');
            let clean_stored = stored_etag.trim().trim_matches('"');
            if !clean_req.is_empty() && !clean_req.eq_ignore_ascii_case(clean_stored) {
                return Err(ApiError::BadRequest("part ETag mismatch"));
            }
            out.push((*pn, stored_etag.clone(), path.clone()));
        }
        out
    } else {
        by_num
            .into_iter()
            .map(|(pn, (etag, _, path))| (pn, etag, path))
            .collect()
    };

    // Stream parts sequentially into incoming temp file while computing overall SHA-256 & S3 Multipart ETag
    let temp_dir = app.cfg.blobs_dir().join(".incoming");
    tokio::fs::create_dir_all(&temp_dir).await?;
    let combined_temp = temp_dir.join(util::temp_name("mpucomplete"));
    let mut out_file = tokio::fs::File::create(&combined_temp).await?;
    let mut sha = Sha256::new();
    let mut concat_md5_raw = Vec::with_capacity(ordered.len() * 16);
    let mut total_size = 0u64;
    let mut buf = vec![0u8; 256 * 1024];

    for (_pn, part_etag, part_path) in &ordered {
        let raw_md5 = hex_decode(part_etag.trim_matches('"')).unwrap_or_default();
        concat_md5_raw.extend_from_slice(&raw_md5);

        let mut pf = tokio::fs::File::open(part_path)
            .await
            .map_err(|_| ApiError::BadRequest("missing uploaded part file"))?;
        loop {
            let n = pf.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            total_size += n as u64;
            if total_size > app.cfg.max_upload {
                drop(out_file);
                let _ = tokio::fs::remove_file(&combined_temp).await;
                return Err(ApiError::TooLarge);
            }
            sha.update(&buf[..n]);
            out_file.write_all(&buf[..n]).await?;
        }
    }
    out_file.sync_all().await?;
    drop(out_file);

    let full_sha = util::hex(&sha.finalize());
    let mpu_etag = format!("\"{}-{}\"", md5_hex(&concat_md5_raw), ordered.len());

    let mut meta = BTreeMap::new();
    if let Some(obj) = meta_val.as_object() {
        for (k, v) in obj {
            if let Some(s) = v.as_str() {
                meta.insert(k.clone(), s.to_string());
            }
        }
    }

    let result = commit_object_from_temp(
        app,
        principal,
        bucket,
        &key,
        &combined_temp,
        &full_sha,
        &mpu_etag,
        total_size,
        Some(&content_type),
        meta,
    )
    .await;
    let _ = tokio::fs::remove_file(&combined_temp).await;
    let placed = result?;

    // Clean up multipart DB rows and temp folder
    let c = app.pool.get().await?;
    c.execute(
        "DELETE FROM multipart_uploads WHERE upload_id = $1",
        &[&upload_id],
    )
    .await?;
    drop(c);
    let _ = tokio::fs::remove_dir_all(upload_dir(app, upload_id)).await;

    Ok(placed)
}

pub async fn abort_multipart(
    app: &App,
    principal: &Principal,
    bucket: &str,
    raw_key: &str,
    upload_id: &str,
) -> ApiResult<()> {
    let key = normalize_object_key(raw_key).ok_or(ApiError::NotFound)?;
    principal.require_bucket(bucket, "write")?;
    let c = app.pool.get().await?;
    let n = c
        .execute(
            "DELETE FROM multipart_uploads WHERE upload_id = $1 AND bucket = $2 AND key = $3",
            &[&upload_id, &bucket, &key],
        )
        .await?;
    drop(c);
    let _ = tokio::fs::remove_dir_all(upload_dir(app, upload_id)).await;
    if n == 0 {
        return Err(ApiError::NotFound);
    }
    Ok(())
}

pub async fn list_multipart_uploads(
    app: &App,
    principal: &Principal,
    bucket: &str,
) -> ApiResult<Vec<MultipartUploadInfo>> {
    principal.require_bucket(bucket, "read")?;
    let c = app.pool.get().await?;
    let rows = c
        .query(
            "SELECT upload_id, bucket, key, content_type, created_at
               FROM multipart_uploads
              WHERE bucket = $1
              ORDER BY created_at ASC
              LIMIT 1000",
            &[&bucket],
        )
        .await?;
    Ok(rows
        .iter()
        .map(|r| MultipartUploadInfo {
            upload_id: r.get(0),
            bucket: r.get(1),
            key: r.get(2),
            content_type: r.get(3),
            created_at: r.get(4),
        })
        .collect())
}

pub async fn list_parts(
    app: &App,
    principal: &Principal,
    bucket: &str,
    raw_key: &str,
    upload_id: &str,
) -> ApiResult<Vec<MultipartPartInfo>> {
    let key = normalize_object_key(raw_key).ok_or(ApiError::NotFound)?;
    principal.require_bucket(bucket, "read")?;
    let c = app.pool.get().await?;
    let exists = c
        .query_opt(
            "SELECT 1 FROM multipart_uploads WHERE upload_id = $1 AND bucket = $2 AND key = $3",
            &[&upload_id, &bucket, &key],
        )
        .await?
        .is_some();
    if !exists {
        return Err(ApiError::NotFound);
    }
    let rows = c
        .query(
            "SELECT part_number, etag, sha256, size_bytes, created_at
               FROM multipart_parts
              WHERE upload_id = $1
              ORDER BY part_number ASC",
            &[&upload_id],
        )
        .await?;
    Ok(rows
        .iter()
        .map(|r| MultipartPartInfo {
            part_number: r.get(0),
            etag: r.get(1),
            sha256: r.get(2),
            size: r.get(3),
            created_at: r.get(4),
        })
        .collect())
}
