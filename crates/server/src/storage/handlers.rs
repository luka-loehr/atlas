//! Native JSON & streaming HTTP handlers under `/v1/buckets`.

use atlas_common::crypto::{
    generate_access_key_id, generate_prefixed_id, generate_secret_key, open_secret, seal_secret,
    sha256_bytes,
};
use atlas_common::models::{
    BatchDeleteRequest, BatchDeleteResponse, BucketInfo, CopyObjectRequest, CreateBucketRequest,
    ListObjectsResponse, ObjectInfo, PresignRequest, PresignResponse, PutObjectResponse,
};
use atlas_common::s3::{MAX_PRESIGN_EXPIRES_SECS, presign_url};
use atlas_common::validate::{normalize_object_key, uri_encode};
use axum::Json;
use axum::body::Body;
use axum::extract::{Extension, Path, Query, State};
use axum::http::{HeaderMap, header};
use axum::response::Response;
use chrono::{Duration, Utc};
use serde::Deserialize;
use serde_json::{Value, json};

use super::buckets;
use super::objects::{self, ListParams};
use crate::iam::Principal;
use crate::{ApiError, ApiResult, App, AppState};

pub async fn list_buckets(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
) -> ApiResult<Json<Value>> {
    let list = buckets::list_buckets(&app, &p).await?;
    Ok(Json(json!({ "buckets": list })))
}

pub async fn create_bucket(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Json(req): Json<CreateBucketRequest>,
) -> ApiResult<Json<BucketInfo>> {
    Ok(Json(buckets::create_bucket(&app, &p, &req).await?))
}

pub async fn get_bucket(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(bucket): Path<String>,
) -> ApiResult<Json<BucketInfo>> {
    Ok(Json(buckets::get_bucket(&app, &p, &bucket).await?))
}

pub async fn delete_bucket(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(bucket): Path<String>,
) -> ApiResult<Json<Value>> {
    buckets::delete_bucket(&app, &p, &bucket).await?;
    Ok(Json(json!({ "deleted": true, "bucket": bucket })))
}

#[derive(Deserialize, Default)]
pub struct ListQuery {
    #[serde(default)]
    pub prefix: String,
    pub delimiter: Option<String>,
    pub cursor: Option<String>,
    pub start_after: Option<String>,
    pub limit: Option<usize>,
    pub q: Option<String>,
}

pub async fn list_objects(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(bucket): Path<String>,
    Query(q): Query<ListQuery>,
) -> ApiResult<Json<ListObjectsResponse>> {
    let params = ListParams {
        prefix: q.prefix,
        delimiter: q.delimiter,
        start_after: q.cursor.or(q.start_after),
        max_keys: q.limit.unwrap_or(1000),
        search_query: q.q,
    };
    Ok(Json(
        objects::list_objects(&app, &p, &bucket, params).await?,
    ))
}

pub async fn put_object(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path((bucket, key)): Path<(String, String)>,
    headers: HeaderMap,
    body: Body,
) -> ApiResult<Json<PutObjectResponse>> {
    Ok(Json(
        objects::put_object_streaming(&app, &p, &bucket, &key, &headers, body).await?,
    ))
}

pub async fn get_object(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path((bucket, key)): Path<(String, String)>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    objects::serve_object(&app, &p, &bucket, &key, headers, false).await
}

pub async fn head_object(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path((bucket, key)): Path<(String, String)>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    objects::serve_object(&app, &p, &bucket, &key, headers, true).await
}

pub async fn stat_object(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path((bucket, key)): Path<(String, String)>,
) -> ApiResult<Json<ObjectInfo>> {
    Ok(Json(objects::stat_object(&app, &p, &bucket, &key).await?))
}

pub async fn delete_object(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path((bucket, key)): Path<(String, String)>,
) -> ApiResult<Json<Value>> {
    let deleted = objects::delete_objects(&app, &p, &bucket, &[key]).await?;
    Ok(Json(json!({ "deleted": deleted })))
}

pub async fn batch_delete(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(bucket): Path<String>,
    Json(req): Json<BatchDeleteRequest>,
) -> ApiResult<Json<BatchDeleteResponse>> {
    let deleted = objects::delete_objects(&app, &p, &bucket, &req.keys).await?;
    Ok(Json(BatchDeleteResponse { deleted }))
}

pub async fn copy_object(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(dst_bucket): Path<String>,
    Json(req): Json<CopyObjectRequest>,
) -> ApiResult<Json<PutObjectResponse>> {
    Ok(Json(
        objects::copy_object(
            &app,
            &p,
            &req.src_bucket,
            &req.src_key,
            &dst_bucket,
            &req.dst_key,
            req.metadata,
        )
        .await?,
    ))
}

/// Ensures an active SigV4 keypair is available to sign a presigned URL:
/// uses the caller's own API key when authenticated with one, or auto-provisions
/// a dedicated internal owner presigning key when called with master `ATLAS_TOKEN`.
async fn resolve_signing_credentials(app: &App, p: &Principal) -> ApiResult<(String, String)> {
    if let Some(ref ak) = p.access_key_id
        && let Some(cached) = app
            .iam
            .cache
            .lookup(
                &app.pool,
                &app.cfg.token,
                app.cfg.default_key_rps,
                app.cfg.default_key_burst,
                ak,
            )
            .await?
    {
        return Ok((cached.access_key_id.clone(), cached.secret_plain.clone()));
    }

    // Master owner token: reuse or create 'system-presign' key on 'owner' account
    let c = app.pool.get().await?;
    if let Some(r) = c
        .query_opt(
            "SELECT access_key_id, sealed_secret
               FROM api_keys
              WHERE account_id = 'owner' AND name = 'system-presign' AND revoked_at IS NULL
              LIMIT 1",
            &[],
        )
        .await?
    {
        let ak: String = r.get(0);
        let sealed: Vec<u8> = r.get(1);
        if let Ok(plain) = open_secret(&app.cfg.token, ak.as_bytes(), &sealed)
            && let Ok(sk) = String::from_utf8(plain)
        {
            return Ok((ak, sk));
        }
    }

    let id = generate_prefixed_id("key", 8)?;
    let ak = generate_access_key_id()?;
    let sk = generate_secret_key()?;
    let sealed = seal_secret(&app.cfg.token, ak.as_bytes(), sk.as_bytes())?;
    let sha = sha256_bytes(sk.as_bytes()).to_vec();
    let scopes: Vec<String> = vec!["read".into(), "write".into()];
    let all_buckets: Vec<String> = vec!["*".into()];
    c.execute(
        "INSERT INTO api_keys (id, access_key_id, name, account_id, sealed_secret, secret_sha256, scopes, buckets)
         VALUES ($1, $2, 'system-presign', 'owner', $3, $4, $5, $6)",
        &[&id, &ak, &sealed, &sha, &scopes, &all_buckets],
    )
    .await?;
    app.iam.cache.invalidate();
    Ok((ak, sk))
}

pub async fn presign(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(bucket): Path<String>,
    headers: HeaderMap,
    Json(req): Json<PresignRequest>,
) -> ApiResult<Json<PresignResponse>> {
    let method = req.method.trim().to_ascii_uppercase();
    let needed_scope = match method.as_str() {
        "GET" | "HEAD" => "read",
        "PUT" => "write",
        "DELETE" => "delete",
        _ => {
            return Err(ApiError::BadRequest(
                "presign method must be GET, HEAD, PUT or DELETE",
            ));
        }
    };
    p.require_bucket(&bucket, needed_scope)?;
    if !(1..=MAX_PRESIGN_EXPIRES_SECS).contains(&req.expires_in_secs) {
        return Err(ApiError::BadRequest(
            "expires_in_secs must be between 1 and 604800",
        ));
    }
    let key = normalize_object_key(&req.key).ok_or(ApiError::BadRequest("invalid object key"))?;
    let (ak, sk) = resolve_signing_credentials(&app, &p).await?;

    let host = headers
        .get(header::HOST)
        .and_then(|v| v.to_str().ok())
        .unwrap_or(&app.cfg.bind);
    let scheme = headers
        .get("x-forwarded-proto")
        .and_then(|v| v.to_str().ok())
        .filter(|s| *s == "https" || *s == "http")
        .unwrap_or("http");
    let base_url = format!("{scheme}://{host}");
    let raw_path = format!(
        "/s3/{}/{}",
        uri_encode(&bucket, true),
        uri_encode(&key, false)
    );

    let now = Utc::now();
    let url = presign_url(
        &base_url,
        &raw_path,
        &method,
        &ak,
        &sk,
        &app.cfg.s3_region,
        req.expires_in_secs,
        now,
    )
    .map_err(|_| ApiError::BadRequest("failed to construct presigned URL"))?;

    Ok(Json(PresignResponse {
        url,
        method,
        bucket,
        key,
        expires_in_secs: req.expires_in_secs,
        expires_at: now + Duration::seconds(req.expires_in_secs as i64),
    }))
}
