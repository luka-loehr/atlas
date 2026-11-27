//! End-to-end integration tests for the Atlas CLI API & S3 client against a
//! local mock HTTP + SigV4 S3 server.

use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::sync::{Arc, Mutex};

use atlas_common::crypto::sha256_hex;
use atlas_common::models::{
    AccountInfo, AccountStatus, ApiKeyInfo, BatchDeleteRequest, BatchDeleteResponse, BucketInfo,
    BucketKind, CopyObjectRequest, CreateAccountRequest, CreateBucketRequest, CreateKeyRequest,
    CreateKeyResponse, ListObjectsResponse, MediaSearchItem, MediaSearchResponse, MediaUrls,
    ObjectInfo, PresignRequest, PresignResponse,
};
use atlas_common::s3::{
    EMPTY_SHA256, parse_authorization_header, parse_presigned_query, verify_header_request,
    verify_presigned_request,
};
use atlas_common::validate::parse_query_pairs;
use axum::Router;
use axum::body::Bytes;
use axum::extract::{Path as AxumPath, Query, State};
use axum::http::{HeaderMap, StatusCode, Uri, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, put};
use chrono::Utc;
use serde_json::{Value, json};
use tokio::net::TcpListener;

const TEST_AK: &str = "ATLK23456789ABCDEFGHJKLM";
const TEST_SK: &str = "atls_test_secret_key_for_cli_integration";

#[derive(Clone, Default)]
struct MockState {
    inner: Arc<Mutex<MockDb>>,
}

struct StoredObject {
    data: Vec<u8>,
    content_type: String,
    metadata: BTreeMap<String, String>,
    sha256: String,
    etag: String,
}

struct MultipartSession {
    bucket: String,
    key: String,
    content_type: String,
    parts: BTreeMap<usize, Vec<u8>>,
}

#[derive(Default)]
struct MockDb {
    buckets: BTreeMap<String, BucketInfo>,
    objects: BTreeMap<(String, String), StoredObject>,
    multiparts: HashMap<String, MultipartSession>,
    multipart_completed_count: usize,
    assets: HashMap<String, Vec<u8>>,
    uploaded_asset_sources: Vec<String>,
    keys: BTreeMap<String, ApiKeyInfo>,
    accounts: BTreeMap<String, AccountInfo>,
    disable_online_presign: bool,
}

impl MockDb {
    fn seed_defaults(&mut self) {
        let now = Utc::now();
        self.buckets.insert(
            "files".into(),
            BucketInfo {
                name: "files".into(),
                kind: BucketKind::Files,
                owner_account_id: "acct_owner".into(),
                object_count: 0,
                total_bytes: 0,
                quota_bytes: None,
                public_read: false,
                created_at: now,
            },
        );
    }
}

fn check_bearer(headers: &HeaderMap) -> Result<(), (StatusCode, String)> {
    let expected = format!("Bearer {TEST_AK}:{TEST_SK}");
    match headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
    {
        Some(v) if v == expected || v == "Bearer legacy-token" => Ok(()),
        _ => Err((
            StatusCode::UNAUTHORIZED,
            r#"{"error":"unauthorized"}"#.to_string(),
        )),
    }
}

fn verify_s3_sigv4(
    method: &str,
    uri: &Uri,
    headers: &HeaderMap,
    body: &[u8],
) -> Result<(), (StatusCode, String)> {
    let auth = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| (StatusCode::UNAUTHORIZED, "missing Authorization".into()))?;
    let parsed = parse_authorization_header(auth)
        .map_err(|e| (StatusCode::FORBIDDEN, format!("bad sigv4 header: {e}")))?;
    if parsed.scope.access_key_id != TEST_AK {
        return Err((StatusCode::FORBIDDEN, "unknown access key".into()));
    }
    let mut hmap = BTreeMap::new();
    for (k, v) in headers {
        if let Ok(s) = v.to_str() {
            hmap.insert(k.as_str().to_ascii_lowercase(), s.to_string());
        }
    }
    let payload_hash = if body.is_empty() {
        EMPTY_SHA256.to_string()
    } else {
        sha256_hex(body)
    };
    verify_header_request(
        &parsed,
        TEST_SK,
        method,
        uri.path(),
        uri.query(),
        &hmap,
        &payload_hash,
        Utc::now(),
    )
    .map_err(|e| (StatusCode::FORBIDDEN, format!("sigv4 verify failed: {e}")))
}

async fn start_mock_server() -> (String, MockState) {
    let state = MockState::default();
    state.inner.lock().unwrap().seed_defaults();

    let app = Router::new()
        .route("/v1/server", get(h_server))
        .route("/v1/auth/whoami", get(h_whoami))
        .route("/v1/buckets", get(h_buckets_ls).post(h_buckets_create))
        .route(
            "/v1/buckets/{name}",
            get(h_buckets_info).delete(h_buckets_rm),
        )
        .route("/v1/buckets/{name}/objects", get(h_objects_ls))
        .route(
            "/v1/buckets/{name}/objects/{*key}",
            put(h_object_put_v1)
                .get(h_object_get_v1)
                .delete(h_object_rm_v1),
        )
        .route("/v1/buckets/{name}/stat/{*key}", get(h_object_stat))
        .route("/v1/buckets/{name}/copy", post(h_object_copy))
        .route("/v1/buckets/{name}/delete", post(h_object_batch_delete))
        .route("/v1/buckets/{name}/presign", post(h_object_presign))
        .route(
            "/s3/{bucket}/{*key}",
            put(h_s3_put)
                .get(h_s3_get)
                .post(h_s3_post)
                .delete(h_s3_delete),
        )
        .route("/v1/drive/search", get(h_drive_search))
        .route("/v1/media/search", get(h_media_search))
        .route("/v1/media/similar/{id}", get(h_media_similar))
        .route("/v1/assets/exists", post(h_assets_exists))
        .route("/v1/assets", put(h_assets_upload))
        .route("/v1/assets/{id}/original", get(h_asset_original))
        .route("/v1/assets/{id}/thumb/{size}", get(h_asset_thumb))
        .route("/v1/people", get(h_people))
        .route("/v1/albums", get(h_albums))
        .route("/v1/stats", get(h_stats))
        .route("/v1/keys", get(h_keys_ls).post(h_keys_create))
        .route("/v1/keys/{id}/revoke", post(h_keys_revoke))
        .route("/v1/keys/{id}", delete(h_keys_rm))
        .route("/v1/accounts", get(h_accounts_ls).post(h_accounts_create))
        .route(
            "/v1/accounts/{id}",
            get(h_accounts_info).delete(h_accounts_rm),
        )
        .route("/openapi.json", get(h_openapi))
        .with_state(state.clone());

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (format!("http://{addr}"), state)
}

async fn h_server(headers: HeaderMap) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    axum::Json(json!({
        "name": "atlas",
        "version": "0.6.0",
        "hostname": "atlas-mock"
    }))
    .into_response()
}

async fn h_whoami(headers: HeaderMap) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    axum::Json(json!({
        "account_id": "acct_owner",
        "access_key_id": TEST_AK,
        "role": "owner",
        "scopes": ["read", "write", "delete", "media:search", "admin"]
    }))
    .into_response()
}

async fn h_buckets_ls(State(st): State<MockState>, headers: HeaderMap) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let db = st.inner.lock().unwrap();
    let list: Vec<BucketInfo> = db.buckets.values().cloned().collect();
    axum::Json(list).into_response()
}

async fn h_buckets_create(
    State(st): State<MockState>,
    headers: HeaderMap,
    axum::Json(req): axum::Json<CreateBucketRequest>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    if req.name == "evil-ansi" {
        return (
            StatusCode::BAD_REQUEST,
            json!({"error": "bad \x1b[31mANSI\x1b[0m\x1b]0;title\x07 bucket"}).to_string(),
        )
            .into_response();
    }
    let mut db = st.inner.lock().unwrap();
    let info = BucketInfo {
        name: req.name.clone(),
        kind: req.kind,
        owner_account_id: "acct_owner".into(),
        object_count: 0,
        total_bytes: 0,
        quota_bytes: req.quota_bytes,
        public_read: false,
        created_at: Utc::now(),
    };
    db.buckets.insert(req.name, info.clone());
    (StatusCode::CREATED, axum::Json(info)).into_response()
}

async fn h_buckets_info(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath(name): AxumPath<String>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let db = st.inner.lock().unwrap();
    match db.buckets.get(&name) {
        Some(b) => axum::Json(b.clone()).into_response(),
        None => (StatusCode::NOT_FOUND, r#"{"error":"bucket not found"}"#).into_response(),
    }
}

async fn h_buckets_rm(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath(name): AxumPath<String>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let mut db = st.inner.lock().unwrap();
    if db.buckets.remove(&name).is_some() {
        StatusCode::NO_CONTENT.into_response()
    } else {
        (StatusCode::NOT_FOUND, r#"{"error":"bucket not found"}"#).into_response()
    }
}

async fn h_objects_ls(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath(name): AxumPath<String>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let prefix = params.get("prefix").cloned().unwrap_or_default();
    let delimiter = params.get("delimiter").cloned();
    let q = params.get("q").cloned();
    let now = Utc::now();

    let db = st.inner.lock().unwrap();
    let mut objects = Vec::new();
    let mut common_prefixes = Vec::new();

    for ((b, k), obj) in &db.objects {
        if b != &name {
            continue;
        }
        if !prefix.is_empty() && !k.starts_with(&prefix) {
            continue;
        }
        if let Some(ref query) = q
            && !k.contains(query.as_str())
        {
            continue;
        }
        if let Some(ref delim) = delimiter {
            let rest = &k[prefix.len()..];
            if let Some(idx) = rest.find(delim.as_str()) {
                let cp = format!("{}{}", prefix, &rest[..=idx]);
                if !common_prefixes.contains(&cp) {
                    common_prefixes.push(cp);
                }
                continue;
            }
        }
        objects.push(ObjectInfo {
            bucket: b.clone(),
            key: k.clone(),
            size: obj.data.len() as i64,
            etag: obj.etag.clone(),
            sha256: obj.sha256.clone(),
            content_type: obj.content_type.clone(),
            metadata: obj.metadata.clone(),
            asset_id: None,
            drive_file_id: None,
            snippet: q.as_ref().map(|_| format!("matched {k}")),
            created_at: now,
            updated_at: now,
        });
    }

    axum::Json(ListObjectsResponse {
        bucket: name,
        prefix,
        delimiter,
        common_prefixes,
        objects,
        is_truncated: false,
        next_cursor: None,
    })
    .into_response()
}

async fn h_object_put_v1(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath((bucket, key)): AxumPath<(String, String)>,
    body: Bytes,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    store_object(&st, bucket, key, &headers, body.to_vec())
}

fn store_object(
    st: &MockState,
    bucket: String,
    key: String,
    headers: &HeaderMap,
    data: Vec<u8>,
) -> Response {
    let sha = sha256_hex(&data);
    let etag = format!("\"{}\"", &sha[..16]);
    let ct = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/octet-stream")
        .to_string();
    let mut metadata = BTreeMap::new();
    for (k, v) in headers {
        if let Some(mk) = k.as_str().strip_prefix("x-amz-meta-")
            && let Ok(mv) = v.to_str()
        {
            metadata.insert(mk.to_string(), mv.to_string());
        }
    }
    let mut db = st.inner.lock().unwrap();
    db.objects.insert(
        (bucket, key),
        StoredObject {
            data,
            content_type: ct,
            metadata,
            sha256: sha,
            etag: etag.clone(),
        },
    );
    ([(header::ETAG, etag)], StatusCode::OK).into_response()
}

fn serve_object_bytes(data: &[u8], headers: &HeaderMap) -> Response {
    if let Some(range) = headers.get(header::RANGE).and_then(|v| v.to_str().ok())
        && let Some(spec) = range.strip_prefix("bytes=")
        && let Some((start_s, end_s)) = spec.split_once('-')
        && let (Ok(start), Ok(end)) = (start_s.parse::<usize>(), end_s.parse::<usize>())
    {
        let end = end.min(data.len().saturating_sub(1));
        if start <= end && start < data.len() {
            return (StatusCode::PARTIAL_CONTENT, data[start..=end].to_vec()).into_response();
        }
    }
    (StatusCode::OK, data.to_vec()).into_response()
}

async fn h_object_get_v1(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath((bucket, key)): AxumPath<(String, String)>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let db = st.inner.lock().unwrap();
    match db.objects.get(&(bucket, key)) {
        Some(obj) => serve_object_bytes(&obj.data, &headers),
        None => (StatusCode::NOT_FOUND, r#"{"error":"not found"}"#).into_response(),
    }
}

async fn h_object_rm_v1(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath((bucket, key)): AxumPath<(String, String)>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let mut db = st.inner.lock().unwrap();
    db.objects.remove(&(bucket, key));
    StatusCode::NO_CONTENT.into_response()
}

async fn h_object_stat(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath((bucket, key)): AxumPath<(String, String)>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let db = st.inner.lock().unwrap();
    let now = Utc::now();
    match db.objects.get(&(bucket.clone(), key.clone())) {
        Some(obj) => axum::Json(ObjectInfo {
            bucket,
            key,
            size: obj.data.len() as i64,
            etag: obj.etag.clone(),
            sha256: obj.sha256.clone(),
            content_type: obj.content_type.clone(),
            metadata: obj.metadata.clone(),
            asset_id: None,
            drive_file_id: None,
            snippet: None,
            created_at: now,
            updated_at: now,
        })
        .into_response(),
        None => (StatusCode::NOT_FOUND, r#"{"error":"not found"}"#).into_response(),
    }
}

async fn h_object_copy(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath(dst_bucket): AxumPath<String>,
    axum::Json(req): axum::Json<CopyObjectRequest>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let mut db = st.inner.lock().unwrap();
    let Some(src) = db.objects.get(&(req.src_bucket, req.src_key)) else {
        return (StatusCode::NOT_FOUND, r#"{"error":"source not found"}"#).into_response();
    };
    let cloned = StoredObject {
        data: src.data.clone(),
        content_type: src.content_type.clone(),
        metadata: src.metadata.clone(),
        sha256: src.sha256.clone(),
        etag: src.etag.clone(),
    };
    let now = Utc::now();
    let info = ObjectInfo {
        bucket: dst_bucket.clone(),
        key: req.dst_key.clone(),
        size: cloned.data.len() as i64,
        etag: cloned.etag.clone(),
        sha256: cloned.sha256.clone(),
        content_type: cloned.content_type.clone(),
        metadata: cloned.metadata.clone(),
        asset_id: None,
        drive_file_id: None,
        snippet: None,
        created_at: now,
        updated_at: now,
    };
    db.objects.insert((dst_bucket, req.dst_key), cloned);
    axum::Json(info).into_response()
}

async fn h_object_batch_delete(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath(bucket): AxumPath<String>,
    axum::Json(req): axum::Json<BatchDeleteRequest>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let mut db = st.inner.lock().unwrap();
    let mut deleted = Vec::new();
    for k in req.keys {
        if db.objects.remove(&(bucket.clone(), k.clone())).is_some() {
            deleted.push(k);
        }
    }
    axum::Json(BatchDeleteResponse { deleted }).into_response()
}

async fn h_object_presign(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath(bucket): AxumPath<String>,
    axum::Json(req): axum::Json<PresignRequest>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    if st.inner.lock().unwrap().disable_online_presign {
        return (StatusCode::NOT_FOUND, r#"{"error":"disabled"}"#).into_response();
    }
    let now = Utc::now();
    axum::Json(PresignResponse {
        url: format!(
            "http://127.0.0.1:8787/s3/{bucket}/{}?X-Amz-Algorithm=AWS4-HMAC-SHA256&mock=1",
            req.key
        ),
        method: req.method,
        bucket,
        key: req.key,
        expires_in_secs: req.expires_in_secs,
        expires_at: now + chrono::Duration::seconds(req.expires_in_secs as i64),
    })
    .into_response()
}

async fn h_s3_put(
    State(st): State<MockState>,
    uri: Uri,
    headers: HeaderMap,
    AxumPath((bucket, key)): AxumPath<(String, String)>,
    body: Bytes,
) -> Response {
    if let Err(e) = verify_s3_sigv4("PUT", &uri, &headers, &body) {
        return e.into_response();
    }
    let pairs = parse_query_pairs(uri.query());
    let upload_id = pairs
        .iter()
        .find(|(k, _)| k == "uploadId")
        .map(|(_, v)| v.clone());
    let part_num = pairs
        .iter()
        .find(|(k, _)| k == "partNumber")
        .and_then(|(_, v)| v.parse::<usize>().ok());

    if let (Some(uid), Some(pnum)) = (upload_id, part_num) {
        let etag = format!("\"{}\"", &sha256_hex(&body)[..16]);
        let mut db = st.inner.lock().unwrap();
        let Some(sess) = db.multiparts.get_mut(&uid) else {
            return (StatusCode::NOT_FOUND, "NoSuchUpload").into_response();
        };
        sess.parts.insert(pnum, body.to_vec());
        return ([(header::ETAG, etag)], StatusCode::OK).into_response();
    }

    store_object(&st, bucket, key, &headers, body.to_vec())
}

async fn h_s3_post(
    State(st): State<MockState>,
    uri: Uri,
    headers: HeaderMap,
    AxumPath((bucket, key)): AxumPath<(String, String)>,
    body: Bytes,
) -> Response {
    if let Err(e) = verify_s3_sigv4("POST", &uri, &headers, &body) {
        return e.into_response();
    }
    let pairs = parse_query_pairs(uri.query());
    if pairs.iter().any(|(k, _)| k == "uploads") {
        let uid = "mpu_test_001".to_string();
        let ct = headers
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("application/octet-stream")
            .to_string();
        let mut db = st.inner.lock().unwrap();
        db.multiparts.insert(
            uid.clone(),
            MultipartSession {
                bucket: bucket.clone(),
                key: key.clone(),
                content_type: ct,
                parts: BTreeMap::new(),
            },
        );
        let xml = format!(
            "<InitiateMultipartUploadResult><Bucket>{bucket}</Bucket><Key>{key}</Key><UploadId>{uid}</UploadId></InitiateMultipartUploadResult>"
        );
        return (StatusCode::OK, xml).into_response();
    }

    if let Some((_, uid)) = pairs.iter().find(|(k, _)| k == "uploadId") {
        let mut db = st.inner.lock().unwrap();
        let Some(sess) = db.multiparts.remove(uid) else {
            return (StatusCode::NOT_FOUND, "NoSuchUpload").into_response();
        };
        let mut combined = Vec::new();
        for (_, part) in sess.parts {
            combined.extend_from_slice(&part);
        }
        let sha = sha256_hex(&combined);
        let etag = format!("\"{}-mp\"", &sha[..16]);
        db.objects.insert(
            (sess.bucket.clone(), sess.key.clone()),
            StoredObject {
                data: combined,
                content_type: sess.content_type,
                metadata: BTreeMap::new(),
                sha256: sha,
                etag: etag.clone(),
            },
        );
        db.multipart_completed_count += 1;
        let xml = format!(
            "<CompleteMultipartUploadResult><Bucket>{}</Bucket><Key>{}</Key><ETag>{etag}</ETag></CompleteMultipartUploadResult>",
            sess.bucket, sess.key
        );
        return (StatusCode::OK, xml).into_response();
    }

    (StatusCode::BAD_REQUEST, "unsupported s3 POST").into_response()
}

async fn h_s3_delete(
    State(st): State<MockState>,
    uri: Uri,
    headers: HeaderMap,
    AxumPath((_bucket, _key)): AxumPath<(String, String)>,
) -> Response {
    if let Err(e) = verify_s3_sigv4("DELETE", &uri, &headers, b"") {
        return e.into_response();
    }
    let pairs = parse_query_pairs(uri.query());
    if let Some((_, uid)) = pairs.iter().find(|(k, _)| k == "uploadId") {
        st.inner.lock().unwrap().multiparts.remove(uid);
    }
    StatusCode::NO_CONTENT.into_response()
}

async fn h_s3_get(
    State(st): State<MockState>,
    uri: Uri,
    headers: HeaderMap,
    AxumPath((bucket, key)): AxumPath<(String, String)>,
) -> Response {
    if let Err(e) = verify_s3_sigv4("GET", &uri, &headers, b"") {
        return e.into_response();
    }
    let db = st.inner.lock().unwrap();
    match db.objects.get(&(bucket, key)) {
        Some(obj) => serve_object_bytes(&obj.data, &headers),
        None => (StatusCode::NOT_FOUND, "NoSuchKey").into_response(),
    }
}

async fn h_drive_search(headers: HeaderMap) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    axum::Json(json!({
        "files": [{"id": 1, "name": "tax-2026.pdf", "size": 4096}]
    }))
    .into_response()
}

async fn h_media_search(
    headers: HeaderMap,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let q = params.get("q").cloned().unwrap_or_default();
    axum::Json(MediaSearchResponse {
        query: q,
        semantic: "ok".into(),
        total: 1,
        items: vec![MediaSearchItem {
            id: "a".repeat(64),
            bucket: "media".into(),
            key: "2026/05/sunset.jpg".into(),
            media_type: "photo".into(),
            taken_at: Some(Utc::now()),
            width: Some(4000),
            height: Some(3000),
            duration_s: None,
            size_bytes: Some(2_500_000),
            favorite: true,
            camera: Some("iPhone 16 Pro".into()),
            place: Some("Munich".into()),
            people: vec![],
            ocr_text: None,
            score: Some(0.94),
            urls: MediaUrls {
                original: "/v1/assets/aaa/original".into(),
                thumb_512: "/v1/assets/aaa/thumb/512".into(),
                thumb_2048: "/v1/assets/aaa/thumb/2048".into(),
                tile: "/v1/assets/aaa/tile".into(),
                s3: "/s3/media/2026/05/sunset.jpg".into(),
            },
        }],
    })
    .into_response()
}

async fn h_media_similar(headers: HeaderMap, AxumPath(id): AxumPath<String>) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    axum::Json(MediaSearchResponse {
        query: id,
        semantic: "similar".into(),
        total: 0,
        items: vec![],
    })
    .into_response()
}

async fn h_assets_exists(
    State(st): State<MockState>,
    headers: HeaderMap,
    axum::Json(body): axum::Json<Value>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let db = st.inner.lock().unwrap();
    let hashes = body
        .get("hashes")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let have: Vec<String> = hashes
        .into_iter()
        .filter_map(|v| v.as_str().map(String::from))
        .filter(|h| db.assets.contains_key(h))
        .collect();
    axum::Json(json!({ "have": have })).into_response()
}

async fn h_assets_upload(State(st): State<MockState>, headers: HeaderMap, body: Bytes) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let sha = sha256_hex(&body);
    let claimed = headers
        .get("x-content-hash")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if claimed != sha {
        return (StatusCode::BAD_REQUEST, r#"{"error":"hash mismatch"}"#).into_response();
    }
    let src = headers
        .get("x-source")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    let mut db = st.inner.lock().unwrap();
    db.assets.insert(sha.clone(), body.to_vec());
    db.uploaded_asset_sources.push(src);
    axum::Json(json!({ "id": sha, "exists": false })).into_response()
}

async fn h_asset_original(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath(id): AxumPath<String>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let db = st.inner.lock().unwrap();
    match db.assets.get(&id) {
        Some(bytes) => (StatusCode::OK, bytes.clone()).into_response(),
        None => (StatusCode::NOT_FOUND, r#"{"error":"asset not found"}"#).into_response(),
    }
}

async fn h_asset_thumb(
    headers: HeaderMap,
    AxumPath((_id, size)): AxumPath<(String, u32)>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    (StatusCode::OK, format!("webp-thumb-{size}")).into_response()
}

async fn h_people(headers: HeaderMap) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    axum::Json(json!({
        "people": [{"id": 1, "name": "Luka", "kind": "person", "photos": 42}]
    }))
    .into_response()
}

async fn h_albums(headers: HeaderMap) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    axum::Json(json!({
        "albums": [{"id": 7, "title": "Alps 2026", "count": 18}]
    }))
    .into_response()
}

async fn h_stats(headers: HeaderMap) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    axum::Json(json!({
        "photos": {"photos": 100, "videos": 12, "bytes": 10485760},
        "drive": {"files": 5, "bytes": 2048},
        "albums": 3,
        "people": 4
    }))
    .into_response()
}

async fn h_keys_ls(State(st): State<MockState>, headers: HeaderMap) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let db = st.inner.lock().unwrap();
    let list: Vec<ApiKeyInfo> = db.keys.values().cloned().collect();
    axum::Json(list).into_response()
}

async fn h_keys_create(
    State(st): State<MockState>,
    headers: HeaderMap,
    axum::Json(req): axum::Json<CreateKeyRequest>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let now = Utc::now();
    let id = "key_001".to_string();
    let ak = "ATLKNEWKEY12345678901234".to_string();
    let sk = "atls_newly_minted_secret".to_string();
    let info = ApiKeyInfo {
        id: id.clone(),
        access_key_id: ak.clone(),
        name: req.name,
        account_id: req.account_id.unwrap_or_else(|| "acct_owner".into()),
        scopes: req.scopes,
        buckets: req.buckets,
        rate_limit_rps: req.rate_limit_rps,
        rate_limit_burst: req.rate_limit_burst,
        expires_at: req
            .expires_in_secs
            .map(|s| now + chrono::Duration::seconds(s)),
        revoked_at: None,
        last_used_at: None,
        created_at: now,
    };
    st.inner.lock().unwrap().keys.insert(id, info.clone());
    axum::Json(CreateKeyResponse {
        key: info,
        secret_access_key: sk.clone(),
        bearer_token: format!("{ak}:{sk}"),
    })
    .into_response()
}

async fn h_keys_revoke(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath(id): AxumPath<String>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    if let Some(k) = st.inner.lock().unwrap().keys.get_mut(&id) {
        k.revoked_at = Some(Utc::now());
        StatusCode::OK.into_response()
    } else {
        StatusCode::NOT_FOUND.into_response()
    }
}

async fn h_keys_rm(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath(id): AxumPath<String>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    st.inner.lock().unwrap().keys.remove(&id);
    StatusCode::NO_CONTENT.into_response()
}

async fn h_accounts_ls(State(st): State<MockState>, headers: HeaderMap) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let db = st.inner.lock().unwrap();
    let list: Vec<AccountInfo> = db.accounts.values().cloned().collect();
    axum::Json(list).into_response()
}

async fn h_accounts_create(
    State(st): State<MockState>,
    headers: HeaderMap,
    axum::Json(req): axum::Json<CreateAccountRequest>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    let now = Utc::now();
    let info = AccountInfo {
        id: "acct_bot1".into(),
        name: req.name,
        display_name: req.display_name,
        role: req.role,
        status: AccountStatus::Active,
        rate_limit_rps: req.rate_limit_rps,
        rate_limit_burst: req.rate_limit_burst,
        quota_bytes: req.quota_bytes,
        created_at: now,
        updated_at: now,
    };
    st.inner
        .lock()
        .unwrap()
        .accounts
        .insert(info.id.clone(), info.clone());
    axum::Json(info).into_response()
}

async fn h_accounts_info(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath(id): AxumPath<String>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    match st.inner.lock().unwrap().accounts.get(&id) {
        Some(a) => axum::Json(a.clone()).into_response(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn h_accounts_rm(
    State(st): State<MockState>,
    headers: HeaderMap,
    AxumPath(id): AxumPath<String>,
) -> Response {
    if let Err(e) = check_bearer(&headers) {
        return e.into_response();
    }
    st.inner.lock().unwrap().accounts.remove(&id);
    StatusCode::NO_CONTENT.into_response()
}

async fn h_openapi() -> Response {
    axum::Json(json!({
        "openapi": "3.1.0",
        "info": {"title": "Atlas API", "version": "0.6.0"}
    }))
    .into_response()
}

// ── Test Harness Helpers ─────────────────────────────────────────────────────

fn temp_test_dir(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "atlas-cli-it-{label}-{}-{}",
        std::process::id(),
        Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn run_atlas(args: &[&str], env_vars: &[(&str, &str)], stdin_data: Option<&str>) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_atlas"));
    cmd.args(args)
        .env_remove("ATLAS_URL")
        .env_remove("ATLAS_SERVER_URL")
        .env_remove("ATLAS_API_KEY")
        .env_remove("ATLAS_ACCESS_KEY_ID")
        .env_remove("ATLAS_SECRET_ACCESS_KEY")
        .env_remove("ATLAS_TOKEN")
        .env_remove("ATLAS_CREDENTIALS_FILE")
        .env_remove("HTTP_PROXY")
        .env_remove("HTTPS_PROXY")
        .env_remove("http_proxy")
        .env_remove("https_proxy");
    for (k, v) in env_vars {
        cmd.env(k, v);
    }
    if stdin_data.is_some() {
        cmd.stdin(Stdio::piped());
    }
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().expect("failed to spawn atlas binary");
    if let Some(data) = stdin_data {
        use std::io::Write;
        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(data.as_bytes()).unwrap();
        drop(stdin);
    }
    child.wait_with_output().unwrap()
}

// ── Integration Tests ────────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn auth_login_status_whoami_logout_and_permissions() {
    let (url, _st) = start_mock_server().await;
    let dir = temp_test_dir("auth");
    let cred_file = dir.join("cfg").join("credentials.json");
    let cred_str = cred_file.to_str().unwrap();

    // Login via --key-stdin
    let out = run_atlas(
        &["auth", "login", "--url", &url, "--key-stdin"],
        &[("ATLAS_CREDENTIALS_FILE", cred_str)],
        Some(&format!("{TEST_AK}:{TEST_SK}\n")),
    );
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(cred_file.exists());

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let dir_mode = std::fs::metadata(cred_file.parent().unwrap())
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        let file_mode = std::fs::metadata(&cred_file).unwrap().permissions().mode() & 0o777;
        assert_eq!(dir_mode, 0o700);
        assert_eq!(file_mode, 0o600);
    }

    // Status (reads from saved file)
    let out = run_atlas(
        &["auth", "status", "--json"],
        &[("ATLAS_CREDENTIALS_FILE", cred_str)],
        None,
    );
    assert!(out.status.success());
    let status_json: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(status_json["url"], url);
    assert_eq!(status_json["access_key_id"], TEST_AK);
    assert_eq!(status_json["auth_source"], "credentials.json");

    // Whoami
    let out = run_atlas(
        &["auth", "whoami", "--json"],
        &[("ATLAS_CREDENTIALS_FILE", cred_str)],
        None,
    );
    assert!(out.status.success());
    let who: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(who["role"], "owner");

    // Logout
    let out = run_atlas(
        &["auth", "logout"],
        &[("ATLAS_CREDENTIALS_FILE", cred_str)],
        None,
    );
    assert!(out.status.success());
    assert!(!cred_file.exists());

    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn buckets_crud_and_ansi_sanitization() {
    let (url, _st) = start_mock_server().await;
    let key = format!("{TEST_AK}:{TEST_SK}");
    let env = [("ATLAS_URL", url.as_str()), ("ATLAS_API_KEY", key.as_str())];

    let out = run_atlas(
        &[
            "buckets",
            "create",
            "backups-2026",
            "--kind",
            "files",
            "--quota-gb",
            "10",
            "--json",
        ],
        &env,
        None,
    );
    assert!(out.status.success());
    let created: BucketInfo = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(created.name, "backups-2026");
    assert_eq!(created.quota_bytes, Some(10 * 1024 * 1024 * 1024));

    let out = run_atlas(&["buckets", "ls", "--json"], &env, None);
    assert!(out.status.success());
    let list: Vec<BucketInfo> = serde_json::from_slice(&out.stdout).unwrap();
    assert!(list.iter().any(|b| b.name == "backups-2026"));

    let out = run_atlas(&["buckets", "info", "backups-2026", "--json"], &env, None);
    assert!(out.status.success());
    let info: BucketInfo = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(info.name, "backups-2026");

    // Server error containing raw ANSI escape sequences must be sanitized before printing
    let out = run_atlas(&["buckets", "create", "evil-ansi"], &env, None);
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("bad ANSI bucket"), "stderr was: {stderr}");
    assert!(!stderr.contains("\x1b]0;"), "OSC sequence leaked: {stderr}");

    let out = run_atlas(&["buckets", "rm", "backups-2026"], &env, None);
    assert!(out.status.success());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn files_sigv4_put_get_range_stat_cp_rm_search_and_s3_alias() {
    let (url, _st) = start_mock_server().await;
    let key = format!("{TEST_AK}:{TEST_SK}");
    let env = [("ATLAS_URL", url.as_str()), ("ATLAS_API_KEY", key.as_str())];
    let dir = temp_test_dir("files");

    let src_file = dir.join("hello.txt");
    std::fs::write(&src_file, b"hello atlas sigv4 world").unwrap();

    // Put with SigV4 + metadata
    let out = run_atlas(
        &[
            "files",
            "put",
            src_file.to_str().unwrap(),
            "s3://files/docs/hello.txt",
            "--content-type",
            "text/plain",
            "--meta",
            "author=luka",
            "--json",
        ],
        &env,
        None,
    );
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    // List via `atlas s3` alias
    let out = run_atlas(&["s3", "ls", "files/docs/", "-r", "--json"], &env, None);
    assert!(out.status.success());
    let ls: ListObjectsResponse = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(ls.objects.len(), 1);
    assert_eq!(ls.objects[0].key, "docs/hello.txt");

    // Stat
    let out = run_atlas(
        &["files", "stat", "files/docs/hello.txt", "--json"],
        &env,
        None,
    );
    assert!(out.status.success());
    let stat: ObjectInfo = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(
        stat.metadata.get("author").map(String::as_str),
        Some("luka")
    );

    // Get to file
    let dst_file = dir.join("downloaded.txt");
    let out = run_atlas(
        &[
            "files",
            "get",
            "files/docs/hello.txt",
            dst_file.to_str().unwrap(),
        ],
        &env,
        None,
    );
    assert!(out.status.success());
    assert_eq!(
        std::fs::read(&dst_file).unwrap(),
        b"hello atlas sigv4 world"
    );

    // Get with --range to stdout ('-')
    let out = run_atlas(
        &[
            "files",
            "get",
            "files/docs/hello.txt",
            "-",
            "--range",
            "0-4",
        ],
        &env,
        None,
    );
    assert!(out.status.success());
    assert_eq!(out.stdout, b"hello");

    // Server-side copy
    let out = run_atlas(
        &[
            "files",
            "cp",
            "s3://files/docs/hello.txt",
            "s3://files/docs/hello-copy.txt",
        ],
        &env,
        None,
    );
    assert!(out.status.success());

    // Search within bucket
    let out = run_atlas(
        &[
            "files",
            "search",
            "hello-copy",
            "--bucket",
            "files",
            "--json",
        ],
        &env,
        None,
    );
    assert!(out.status.success());
    let sr: ListObjectsResponse = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(sr.objects.len(), 1);

    // Recursive rm (batch delete)
    let out = run_atlas(&["files", "rm", "files/docs/", "-r"], &env, None);
    assert!(out.status.success());

    let out = run_atlas(&["files", "ls", "files/docs/", "-r", "--json"], &env, None);
    let ls_after: ListObjectsResponse = serde_json::from_slice(&out.stdout).unwrap();
    assert!(ls_after.objects.is_empty());

    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn files_multipart_upload_and_presign_online_and_offline() {
    let (url, st) = start_mock_server().await;
    let key = format!("{TEST_AK}:{TEST_SK}");
    let env = [("ATLAS_URL", url.as_str()), ("ATLAS_API_KEY", key.as_str())];
    let dir = temp_test_dir("multipart");

    let payload = vec![0xABu8; 64 * 1024];
    let file_path = dir.join("chunked.bin");
    std::fs::write(&file_path, &payload).unwrap();

    // --multipart-mb 0 forces S3 Multipart Upload (init -> part -> complete)
    let out = run_atlas(
        &[
            "files",
            "put",
            file_path.to_str().unwrap(),
            "files/big/chunked.bin",
            "--multipart-mb",
            "0",
            "--json",
        ],
        &env,
        None,
    );
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let summary: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(summary["multipart"], true);
    assert_eq!(summary["parts"], 1);
    assert_eq!(st.inner.lock().unwrap().multipart_completed_count, 1);

    // Online presign
    let out = run_atlas(
        &[
            "files",
            "presign",
            "files/big/chunked.bin",
            "--expires",
            "600",
            "--json",
        ],
        &env,
        None,
    );
    assert!(out.status.success());
    let pr: PresignResponse = serde_json::from_slice(&out.stdout).unwrap();
    assert!(pr.url.contains("mock=1"));

    // Disable online presign -> verify offline SigV4 presign fallback!
    st.inner.lock().unwrap().disable_online_presign = true;
    let out = run_atlas(
        &[
            "files",
            "presign",
            "files/big/chunked.bin",
            "--expires",
            "300",
            "--method",
            "GET",
        ],
        &env,
        None,
    );
    assert!(out.status.success());
    let presigned = String::from_utf8(out.stdout).unwrap().trim().to_string();
    let (base_and_path, query) = presigned.split_once('?').unwrap();
    let parsed_q = parse_presigned_query(Some(query)).unwrap().unwrap();
    let host = url.strip_prefix("http://").unwrap();
    let mut hmap = BTreeMap::new();
    hmap.insert("host".into(), host.into());
    let path_only = base_and_path.strip_prefix(&url).unwrap();
    verify_presigned_request(
        &parsed_q,
        TEST_SK,
        "GET",
        path_only,
        Some(query),
        &hmap,
        Utc::now(),
    )
    .expect("offline presigned URL must verify with atlas-common");

    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn files_sync_upload_skip_and_delete() {
    let (url, _st) = start_mock_server().await;
    let key = format!("{TEST_AK}:{TEST_SK}");
    let env = [("ATLAS_URL", url.as_str()), ("ATLAS_API_KEY", key.as_str())];
    let dir = temp_test_dir("sync");

    let local = dir.join("src");
    std::fs::create_dir_all(local.join("sub")).unwrap();
    std::fs::write(local.join("a.txt"), b"alpha").unwrap();
    std::fs::write(local.join("sub/b.txt"), b"beta").unwrap();

    // First sync uploads both files
    let out = run_atlas(
        &[
            "files",
            "sync",
            local.to_str().unwrap(),
            "s3://files/mirror",
        ],
        &env,
        None,
    );
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("2 uploaded, 0 unchanged"), "{stdout}");

    // Second sync skips both (SHA-256 + size match)
    let out = run_atlas(
        &[
            "files",
            "sync",
            local.to_str().unwrap(),
            "s3://files/mirror",
        ],
        &env,
        None,
    );
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("0 uploaded, 2 unchanged"), "{stdout}");

    // Delete local b.txt and sync with --delete
    std::fs::remove_file(local.join("sub/b.txt")).unwrap();
    let out = run_atlas(
        &[
            "files",
            "sync",
            local.to_str().unwrap(),
            "s3://files/mirror",
            "--delete",
        ],
        &env,
        None,
    );
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("1 deleted"), "{stdout}");

    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn photos_search_similar_dedup_upload_get_and_library() {
    let (url, st) = start_mock_server().await;
    let key = format!("{TEST_AK}:{TEST_SK}");
    let env = [("ATLAS_URL", url.as_str()), ("ATLAS_API_KEY", key.as_str())];
    let dir = temp_test_dir("photos");

    // Pre-seed one photo hash so /v1/assets/exists skips it
    let existing_bytes = b"already-in-library-jpeg";
    let existing_sha = sha256_hex(existing_bytes);
    st.inner
        .lock()
        .unwrap()
        .assets
        .insert(existing_sha.clone(), existing_bytes.to_vec());

    let p1 = dir.join("old.jpg");
    let p2 = dir.join("new.heic");
    let ignored = dir.join("readme.txt");
    std::fs::write(&p1, existing_bytes).unwrap();
    std::fs::write(&p2, b"brand-new-heic-photo").unwrap();
    std::fs::write(&ignored, b"not media").unwrap();

    // Upload dir: should skip old.jpg, upload new.heic, ignore readme.txt
    let out = run_atlas(&["photos", "upload", dir.to_str().unwrap()], &env, None);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        stdout.contains("1 uploaded, 1 already in library"),
        "{stdout}"
    );
    assert_eq!(st.inner.lock().unwrap().uploaded_asset_sources, vec!["cli"]);

    // Search
    let out = run_atlas(&["photos", "search", "sunset", "--json"], &env, None);
    assert!(out.status.success());
    let sr: MediaSearchResponse = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(sr.total, 1);

    // Similar
    let out = run_atlas(&["photos", "similar", &existing_sha, "--json"], &env, None);
    assert!(out.status.success());

    // Get original & thumb
    let thumb_out = dir.join("thumb.webp");
    let out = run_atlas(
        &[
            "photos",
            "get",
            &existing_sha,
            thumb_out.to_str().unwrap(),
            "--thumb",
            "512",
        ],
        &env,
        None,
    );
    assert!(out.status.success());
    assert_eq!(std::fs::read(&thumb_out).unwrap(), b"webp-thumb-512");

    // People, albums, stats
    for sub in ["people", "albums", "stats"] {
        let out = run_atlas(&["photos", sub, "--json"], &env, None);
        assert!(out.status.success(), "photos {sub} failed");
    }

    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn iam_keys_accounts_openapi_and_compat_flags() {
    let (url, _st) = start_mock_server().await;
    let key = format!("{TEST_AK}:{TEST_SK}");
    let env = [("ATLAS_URL", url.as_str()), ("ATLAS_API_KEY", key.as_str())];
    let dir = temp_test_dir("iam");

    // Keys create -> ls -> revoke -> rm
    let out = run_atlas(
        &[
            "keys",
            "create",
            "ci-bot",
            "--scopes",
            "read,write",
            "--buckets",
            "files",
            "--expires-days",
            "30",
            "--json",
        ],
        &env,
        None,
    );
    assert!(out.status.success());
    let created: CreateKeyResponse = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(created.key.name, "ci-bot");

    let out = run_atlas(&["keys", "ls", "--json"], &env, None);
    assert!(out.status.success());

    let out = run_atlas(&["keys", "revoke", &created.key.id], &env, None);
    assert!(out.status.success());

    let out = run_atlas(&["keys", "rm", &created.key.id], &env, None);
    assert!(out.status.success());

    // Accounts create -> ls -> info -> rm
    let out = run_atlas(
        &[
            "accounts",
            "create",
            "backup-svc",
            "--display-name",
            "Backup Service",
            "--role",
            "service",
            "--quota-gb",
            "50",
            "--json",
        ],
        &env,
        None,
    );
    assert!(out.status.success());
    let acct: AccountInfo = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(acct.name, "backup-svc");

    let out = run_atlas(&["accounts", "ls", "--json"], &env, None);
    assert!(out.status.success());

    let out = run_atlas(&["accounts", "info", &acct.id, "--json"], &env, None);
    assert!(out.status.success());

    let out = run_atlas(&["accounts", "rm", &acct.id], &env, None);
    assert!(out.status.success());

    // OpenAPI
    let spec_file = dir.join("openapi.json");
    let out = run_atlas(
        &["openapi", "--out", spec_file.to_str().unwrap()],
        &env,
        None,
    );
    assert!(out.status.success());
    let spec: Value = serde_json::from_str(&std::fs::read_to_string(&spec_file).unwrap()).unwrap();
    assert_eq!(spec["openapi"], "3.1.0");

    // Backward-compatible flags
    let out = run_atlas(&["--version"], &[], None);
    assert!(out.status.success());
    assert!(String::from_utf8_lossy(&out.stdout).contains("atlas 0.6.0"));

    let out = run_atlas(&["--help"], &[], None);
    assert!(out.status.success());
    let help = String::from_utf8_lossy(&out.stdout);
    assert!(help.contains("API & S3 CLIENT"));
    assert!(help.contains("SSH & MACHINE"));

    let _ = std::fs::remove_dir_all(&dir);
}
