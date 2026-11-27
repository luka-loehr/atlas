//! Full S3 wire-compatible HTTP handlers mounted under `/s3`.

use std::collections::HashMap;

use atlas_common::crypto::generate_prefixed_id;
use atlas_common::models::{BucketKind, CreateBucketRequest};
use atlas_common::validate::{parse_query_pairs, percent_decode_utf8};
use axum::body::{Body, to_bytes};
use axum::extract::{Extension, Path, Request, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, Uri, header};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};

use super::xml;
use crate::iam::{self, Principal};
use crate::storage::{buckets, multipart, objects};
use crate::{ApiError, AppState};

fn new_request_id() -> String {
    generate_prefixed_id("req", 6).unwrap_or_else(|_| "req_atlas".into())
}

fn query_map(uri: &Uri) -> HashMap<String, String> {
    parse_query_pairs(uri.query()).into_iter().collect()
}

/// Middleware for `/s3` routes: authenticates via SigV4 header, SigV4 presigned URL,
/// Bearer token, or `X-Atlas-Key`, returning standard S3 XML error responses on failure.
pub async fn require_s3_auth(
    State(app): State<AppState>,
    mut req: Request,
    next: Next,
) -> Response {
    let req_id = new_request_id();
    let method = req.method().clone();
    let uri = req.uri().clone();
    let headers = req.headers().clone();

    let (principal, rl_headers) =
        match iam::authenticate_request(&app, &method, &uri, &headers).await {
            Ok(pair) => pair,
            Err(e) => return xml::api_error_to_s3(e, uri.path(), &req_id, false),
        };

    req.extensions_mut().insert(principal);
    let mut resp = next.run(req).await;
    if let Ok(v) = HeaderValue::from_str(&req_id) {
        resp.headers_mut().entry("x-amz-request-id").or_insert(v);
    }
    if let Some((limit, remaining)) = rl_headers {
        if let Ok(v) = HeaderValue::from_str(&limit.to_string()) {
            resp.headers_mut().insert("x-ratelimit-limit", v);
        }
        if let Ok(v) = HeaderValue::from_str(&remaining.to_string()) {
            resp.headers_mut().insert("x-ratelimit-remaining", v);
        }
    }
    resp
}

/// `GET /s3` or `GET /s3/` -> `ListBuckets`.
pub async fn list_buckets(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    uri: Uri,
) -> Response {
    let req_id = new_request_id();
    match buckets::list_buckets(&app, &p).await {
        Ok(list) => xml::xml_response(
            StatusCode::OK,
            xml::render_list_buckets(&list, &p.account_id),
            &req_id,
        ),
        Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, true),
    }
}

/// `HEAD /s3/{bucket}` -> `HeadBucket`.
pub async fn head_bucket(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(bucket): Path<String>,
    uri: Uri,
) -> Response {
    let req_id = new_request_id();
    match buckets::get_bucket(&app, &p, &bucket).await {
        Ok(_) => {
            let mut resp = StatusCode::OK.into_response();
            if let Ok(v) = HeaderValue::from_str(&app.cfg.s3_region) {
                resp.headers_mut().insert("x-amz-bucket-region", v);
            }
            resp
        }
        Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, true),
    }
}

/// `PUT /s3/{bucket}` -> `CreateBucket`.
pub async fn create_bucket(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(bucket): Path<String>,
    uri: Uri,
) -> Response {
    let req_id = new_request_id();
    let req = CreateBucketRequest {
        name: bucket.clone(),
        kind: BucketKind::General,
        quota_bytes: None,
    };
    match buckets::create_bucket(&app, &p, &req).await {
        Ok(_) => {
            let mut resp = StatusCode::OK.into_response();
            if let Ok(v) = HeaderValue::from_str(&format!("/s3/{bucket}")) {
                resp.headers_mut().insert(header::LOCATION, v);
            }
            resp
        }
        Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, true),
    }
}

/// `DELETE /s3/{bucket}` -> `DeleteBucket`.
pub async fn delete_bucket(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(bucket): Path<String>,
    uri: Uri,
) -> Response {
    let req_id = new_request_id();
    match buckets::delete_bucket(&app, &p, &bucket).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, true),
    }
}

/// `GET /s3/{bucket}` -> `ListObjectsV2`, `ListObjects` (v1), `GetBucketLocation`,
/// `GetBucketVersioning`, or `ListMultipartUploads` (`?uploads`).
pub async fn get_bucket(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(bucket): Path<String>,
    uri: Uri,
) -> Response {
    let req_id = new_request_id();
    let q = query_map(&uri);

    if q.contains_key("location") {
        if let Err(e) = buckets::get_bucket(&app, &p, &bucket).await {
            return xml::api_error_to_s3(e, uri.path(), &req_id, true);
        }
        let body = format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
             <LocationConstraint xmlns=\"{}\">{}</LocationConstraint>",
            xml::S3_NS,
            xml::xml_escape(&app.cfg.s3_region)
        );
        return xml::xml_response(StatusCode::OK, body, &req_id);
    }

    if q.contains_key("versioning") {
        if let Err(e) = buckets::get_bucket(&app, &p, &bucket).await {
            return xml::api_error_to_s3(e, uri.path(), &req_id, true);
        }
        let body = format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
             <VersioningConfiguration xmlns=\"{}\"/>",
            xml::S3_NS
        );
        return xml::xml_response(StatusCode::OK, body, &req_id);
    }

    if q.contains_key("uploads") {
        return match multipart::list_multipart_uploads(&app, &p, &bucket).await {
            Ok(uploads) => xml::xml_response(
                StatusCode::OK,
                xml::render_list_multipart_uploads(&bucket, &uploads),
                &req_id,
            ),
            Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, true),
        };
    }

    let is_v2 = q.get("list-type").map(String::as_str) == Some("2");
    let prefix = q.get("prefix").cloned().unwrap_or_default();
    let delimiter = q.get("delimiter").cloned().filter(|s| !s.is_empty());
    let max_keys = q
        .get("max-keys")
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(1000)
        .clamp(1, 1000);
    let continuation_token = q.get("continuation-token").cloned();
    let start_after = q.get("start-after").cloned();
    let marker = q.get("marker").cloned();

    let cursor = if is_v2 {
        continuation_token.clone().or_else(|| start_after.clone())
    } else {
        marker.clone()
    };

    let params = objects::ListParams {
        prefix,
        delimiter,
        start_after: cursor,
        max_keys,
        search_query: None,
    };

    match objects::list_objects(&app, &p, &bucket, params).await {
        Ok(res) => {
            let body = if is_v2 {
                xml::render_list_objects_v2(
                    &res,
                    max_keys,
                    continuation_token.as_deref(),
                    start_after.as_deref(),
                )
            } else {
                xml::render_list_objects_v1(&res, max_keys, marker.as_deref())
            };
            xml::xml_response(StatusCode::OK, body, &req_id)
        }
        Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, true),
    }
}

/// `POST /s3/{bucket}` -> `DeleteObjects` (`?delete`).
pub async fn post_bucket(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(bucket): Path<String>,
    uri: Uri,
    body: Body,
) -> Response {
    let req_id = new_request_id();
    let q = query_map(&uri);
    if !q.contains_key("delete") {
        return xml::s3_error_response(
            StatusCode::BAD_REQUEST,
            "InvalidRequest",
            "Unsupported bucket POST operation (expected ?delete).",
            uri.path(),
            &req_id,
        );
    }

    let bytes = match to_bytes(body, 2 * 1024 * 1024).await {
        Ok(b) => b,
        Err(_) => return xml::api_error_to_s3(ApiError::TooLarge, uri.path(), &req_id, true),
    };
    let text = match std::str::from_utf8(&bytes) {
        Ok(s) => s,
        Err(_) => {
            return xml::api_error_to_s3(
                ApiError::BadRequest("invalid UTF-8 XML"),
                uri.path(),
                &req_id,
                true,
            );
        }
    };
    let (keys, quiet) = match xml::parse_delete_objects_xml(text) {
        Ok(v) => v,
        Err(e) => return xml::api_error_to_s3(e, uri.path(), &req_id, true),
    };
    match objects::delete_objects(&app, &p, &bucket, &keys).await {
        Ok(deleted) => xml::xml_response(
            StatusCode::OK,
            xml::render_delete_result(&deleted, quiet),
            &req_id,
        ),
        Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, true),
    }
}

/// Parses `x-amz-copy-source` (`/bucket/key` or `bucket/key`, optionally `?versionId=...`).
fn parse_copy_source(raw: &str) -> Result<(String, String), ApiError> {
    let without_query = raw.split('?').next().unwrap_or(raw);
    let trimmed = without_query.trim().trim_start_matches('/');
    // Handle optional `/s3/bucket/key` prefix if client included mount prefix
    let trimmed = trimmed.strip_prefix("s3/").unwrap_or(trimmed);
    let (src_bucket_enc, src_key_enc) = trimmed
        .split_once('/')
        .ok_or(ApiError::BadRequest("invalid x-amz-copy-source header"))?;
    let src_bucket = percent_decode_utf8(src_bucket_enc)
        .ok_or(ApiError::BadRequest("invalid x-amz-copy-source bucket"))?;
    let src_key = percent_decode_utf8(src_key_enc)
        .ok_or(ApiError::BadRequest("invalid x-amz-copy-source key"))?;
    Ok((src_bucket, src_key))
}

/// `PUT /s3/{bucket}/{*key}` -> `UploadPart`, `CopyObject`, or `PutObject`.
pub async fn put_object(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path((bucket, key)): Path<(String, String)>,
    uri: Uri,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let req_id = new_request_id();
    let q = query_map(&uri);

    // 1. UploadPart (`?uploadId=...&partNumber=...`)
    if let (Some(upload_id), Some(pn_str)) = (q.get("uploadId"), q.get("partNumber")) {
        let Ok(part_num) = pn_str.parse::<i32>() else {
            return xml::api_error_to_s3(
                ApiError::BadRequest("invalid partNumber"),
                uri.path(),
                &req_id,
                false,
            );
        };
        return match multipart::upload_part(
            &app, &p, &bucket, &key, upload_id, part_num, &headers, body,
        )
        .await
        {
            Ok(part) => {
                let mut resp = StatusCode::OK.into_response();
                if let Ok(v) = HeaderValue::from_str(&part.etag) {
                    resp.headers_mut().insert(header::ETAG, v);
                }
                resp
            }
            Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, false),
        };
    }

    // 2. CopyObject (`x-amz-copy-source`)
    if let Some(copy_src) = headers
        .get("x-amz-copy-source")
        .and_then(|v| v.to_str().ok())
    {
        let (src_bucket, src_key) = match parse_copy_source(copy_src) {
            Ok(v) => v,
            Err(e) => return xml::api_error_to_s3(e, uri.path(), &req_id, false),
        };
        let replace_meta = headers
            .get("x-amz-metadata-directive")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|d| d.eq_ignore_ascii_case("REPLACE"));
        let meta_override = if replace_meta {
            match objects::extract_custom_metadata(&headers) {
                Ok(m) => Some(m),
                Err(e) => return xml::api_error_to_s3(e, uri.path(), &req_id, false),
            }
        } else {
            None
        };

        return match objects::copy_object(
            &app,
            &p,
            &src_bucket,
            &src_key,
            &bucket,
            &key,
            meta_override,
        )
        .await
        {
            Ok(res) => xml::xml_response(StatusCode::OK, xml::render_copy_result(&res), &req_id),
            Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, false),
        };
    }

    // 3. Standard PutObject
    match objects::put_object_streaming(&app, &p, &bucket, &key, &headers, body).await {
        Ok(res) => {
            let mut resp = StatusCode::OK.into_response();
            if let Ok(v) = HeaderValue::from_str(&res.etag) {
                resp.headers_mut().insert(header::ETAG, v);
            }
            if let Ok(v) = HeaderValue::from_str(&res.sha256) {
                resp.headers_mut().insert("x-atlas-sha256", v);
            }
            if let Some(ref aid) = res.asset_id
                && let Ok(v) = HeaderValue::from_str(aid)
            {
                resp.headers_mut().insert("x-atlas-asset-id", v);
            }
            resp
        }
        Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, false),
    }
}

/// `GET /s3/{bucket}/{*key}` -> `ListParts` (`?uploadId=...`) or `GetObject` (Range-capable).
pub async fn get_object(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path((bucket, key)): Path<(String, String)>,
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    let req_id = new_request_id();
    let q = query_map(&uri);

    if let Some(upload_id) = q.get("uploadId") {
        return match multipart::list_parts(&app, &p, &bucket, &key, upload_id).await {
            Ok(parts) => xml::xml_response(
                StatusCode::OK,
                xml::render_list_parts(&bucket, &key, upload_id, &parts),
                &req_id,
            ),
            Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, false),
        };
    }

    match objects::serve_object(&app, &p, &bucket, &key, headers, false).await {
        Ok(resp) => resp,
        Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, false),
    }
}

/// `HEAD /s3/{bucket}/{*key}` -> `HeadObject`.
pub async fn head_object(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path((bucket, key)): Path<(String, String)>,
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    let req_id = new_request_id();
    match objects::serve_object(&app, &p, &bucket, &key, headers, true).await {
        Ok(resp) => resp,
        Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, false),
    }
}

/// `POST /s3/{bucket}/{*key}` -> `CreateMultipartUpload` (`?uploads`) or `CompleteMultipartUpload` (`?uploadId=...`).
pub async fn post_object(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path((bucket, key)): Path<(String, String)>,
    uri: Uri,
    headers: HeaderMap,
    body: Body,
) -> Response {
    let req_id = new_request_id();
    let q = query_map(&uri);

    if q.contains_key("uploads") {
        return match multipart::create_multipart(&app, &p, &bucket, &key, &headers).await {
            Ok(up) => {
                xml::xml_response(StatusCode::OK, xml::render_initiate_multipart(&up), &req_id)
            }
            Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, false),
        };
    }

    if let Some(upload_id) = q.get("uploadId") {
        let bytes = match to_bytes(body, 4 * 1024 * 1024).await {
            Ok(b) => b,
            Err(_) => return xml::api_error_to_s3(ApiError::TooLarge, uri.path(), &req_id, false),
        };
        let text = match std::str::from_utf8(&bytes) {
            Ok(s) => s,
            Err(_) => {
                return xml::api_error_to_s3(
                    ApiError::BadRequest("invalid UTF-8 XML"),
                    uri.path(),
                    &req_id,
                    false,
                );
            }
        };
        let parts = match xml::parse_complete_multipart_xml(text) {
            Ok(v) => v,
            Err(e) => return xml::api_error_to_s3(e, uri.path(), &req_id, false),
        };
        let req_parts = if parts.is_empty() {
            None
        } else {
            Some(parts.as_slice())
        };
        return match multipart::complete_multipart(&app, &p, &bucket, &key, upload_id, req_parts)
            .await
        {
            Ok(res) => {
                let loc = format!("/s3/{}/{}", res.bucket, res.key);
                xml::xml_response(
                    StatusCode::OK,
                    xml::render_complete_multipart(&res, &loc),
                    &req_id,
                )
            }
            Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, false),
        };
    }

    xml::s3_error_response(
        StatusCode::BAD_REQUEST,
        "InvalidRequest",
        "Expected ?uploads or ?uploadId=...",
        uri.path(),
        &req_id,
    )
}

/// `DELETE /s3/{bucket}/{*key}` -> `AbortMultipartUpload` (`?uploadId=...`) or `DeleteObject`.
pub async fn delete_object(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path((bucket, key)): Path<(String, String)>,
    uri: Uri,
) -> Response {
    let req_id = new_request_id();
    let q = query_map(&uri);

    if let Some(upload_id) = q.get("uploadId") {
        return match multipart::abort_multipart(&app, &p, &bucket, &key, upload_id).await {
            Ok(()) => StatusCode::NO_CONTENT.into_response(),
            Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, false),
        };
    }

    match objects::delete_objects(&app, &p, &bucket, &[key]).await {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => xml::api_error_to_s3(e, uri.path(), &req_id, false),
    }
}
