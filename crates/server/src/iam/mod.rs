//! Identity, Access Management, Scoped API/S3 Keys, RBAC, and Rate Limiting.

pub mod cache;
pub mod handlers;
pub mod ratelimit;

use std::collections::BTreeMap;

use atlas_common::crypto::ct_eq;
use atlas_common::models::AccountRole;
use atlas_common::s3::{
    UNSIGNED_PAYLOAD, parse_authorization_header, parse_presigned_query, verify_header_request,
    verify_presigned_request,
};
use axum::Router;
use axum::extract::{Request, State};
use axum::http::{HeaderMap, HeaderValue, Method, Uri, header};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use chrono::{DateTime, Utc};

use crate::{ApiError, ApiResult, AppState};
use cache::KeyCache;
use ratelimit::RateLimiter;

#[derive(Default)]
pub struct IamState {
    pub cache: KeyCache,
    pub limiter: RateLimiter,
}

#[derive(Debug, Clone)]
pub struct Principal {
    pub account_id: String,
    pub role: AccountRole,
    pub key_id: Option<String>,
    pub access_key_id: Option<String>,
    pub scopes: Vec<String>,
    pub buckets: Vec<String>,
    pub quota_bytes: Option<i64>,
    pub is_master: bool,
}

impl Principal {
    pub fn master_owner() -> Self {
        Self {
            account_id: "owner".into(),
            role: AccountRole::Owner,
            key_id: None,
            access_key_id: None,
            scopes: vec![
                "read".into(),
                "write".into(),
                "delete".into(),
                "media:search".into(),
                "admin".into(),
            ],
            buckets: vec!["*".into()],
            quota_bytes: None,
            is_master: true,
        }
    }

    pub fn has_scope(&self, scope: &str) -> bool {
        self.is_master
            || self.role == AccountRole::Owner
            || self.scopes.iter().any(|s| s == "admin" || s == scope)
    }

    pub fn require_scope(&self, scope: &str) -> ApiResult<()> {
        if self.has_scope(scope) {
            Ok(())
        } else {
            Err(ApiError::Forbidden("insufficient key scope"))
        }
    }

    pub fn require_owner_or_admin(&self) -> ApiResult<()> {
        if self.is_master
            || matches!(self.role, AccountRole::Owner | AccountRole::Admin)
                && self.has_scope("admin")
        {
            Ok(())
        } else {
            Err(ApiError::Forbidden("owner or admin credentials required"))
        }
    }

    pub fn can_access_bucket(&self, bucket: &str) -> bool {
        self.is_master
            || self.role == AccountRole::Owner
            || self.buckets.is_empty()
            || self.buckets.iter().any(|b| b == "*" || b == bucket)
    }

    pub fn require_bucket(&self, bucket: &str, scope: &str) -> ApiResult<()> {
        self.require_scope(scope)?;
        if self.can_access_bucket(bucket) {
            Ok(())
        } else {
            Err(ApiError::Forbidden("key is not authorized for this bucket"))
        }
    }
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/auth/whoami", get(handlers::whoami))
        .route(
            "/accounts",
            get(handlers::list_accounts).post(handlers::create_account),
        )
        .route(
            "/accounts/{id}",
            get(handlers::get_account)
                .patch(handlers::update_account)
                .delete(handlers::delete_account),
        )
        .route("/keys", get(handlers::list_keys).post(handlers::create_key))
        .route(
            "/keys/{id}",
            get(handlers::get_key).delete(handlers::delete_key),
        )
        .route("/keys/{id}/revoke", post(handlers::revoke_key))
}

/// Checks if a route is a read-only media/blob playback route allowed to carry `?token=`.
/// Privileged endpoints (system terminal, power, key management, mutations) NEVER accept `?token=`.
pub fn allows_query_token(method: &Method, path: &str) -> bool {
    if !matches!(*method, Method::GET | Method::HEAD) {
        return false;
    }
    if path.starts_with("/v1/system")
        || path.starts_with("/v1/keys")
        || path.starts_with("/v1/accounts")
    {
        return false;
    }
    path.contains("/thumb")
        || path.contains("/tile")
        || path.contains("/original")
        || path.contains("/video")
        || path.contains("/crop")
        || path.starts_with("/v1/drive/blobs/")
        || path.starts_with("/v1/buckets/")
}

/// Rejects cross-origin browser WebSocket hijacking attempts (CSWSH):
/// native iOS/macOS apps send no `Origin` header, whereas browsers always send `Origin`.
pub fn verify_ws_origin(headers: &HeaderMap) -> ApiResult<()> {
    let Some(origin) = headers.get(header::ORIGIN).and_then(|v| v.to_str().ok()) else {
        return Ok(());
    };
    let Some(host) = headers.get(header::HOST).and_then(|v| v.to_str().ok()) else {
        return Err(ApiError::Forbidden(
            "missing Host header on WebSocket upgrade",
        ));
    };
    let origin_host = origin
        .strip_prefix("https://")
        .or_else(|| origin.strip_prefix("http://"))
        .and_then(|rest| rest.split('/').next())
        .unwrap_or("");
    if origin_host.eq_ignore_ascii_case(host.trim()) {
        Ok(())
    } else {
        Err(ApiError::Forbidden("cross-origin WebSocket upgrade denied"))
    }
}

pub fn collect_lowercase_headers(headers: &HeaderMap) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for (k, v) in headers {
        if let Ok(val) = v.to_str() {
            out.insert(k.as_str().to_ascii_lowercase(), val.to_string());
        }
    }
    out
}

/// Authenticates a `/v1` or `/s3` request, checks scope & per-key rate limits,
/// and injects `Principal` into request extensions.
pub async fn authenticate_request(
    app: &AppState,
    method: &Method,
    uri: &Uri,
    headers: &HeaderMap,
) -> Result<(Principal, Option<(u32, u32)>), ApiError> {
    let raw_path = uri.path();
    let raw_query = uri.query();
    let now = Utc::now();

    // 1. Check X-Atlas-Key header (`ATLK...:atls_...` or master token)
    if let Some(raw_key) = headers.get("x-atlas-key").and_then(|v| v.to_str().ok()) {
        return authenticate_token_string(app, raw_key.trim(), now).await;
    }

    // 2. Check Authorization header (`Bearer ...` or `AWS4-HMAC-SHA256 ...`)
    if let Some(auth_val) = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
    {
        let auth_val = auth_val.trim();
        if let Some(bearer) = auth_val.strip_prefix("Bearer ") {
            return authenticate_token_string(app, bearer.trim(), now).await;
        }
        if auth_val.starts_with("AWS4-HMAC-SHA256") {
            let parsed =
                parse_authorization_header(auth_val).map_err(|_| ApiError::Unauthorized)?;
            let key = app
                .iam
                .cache
                .lookup(
                    &app.pool,
                    &app.cfg.token,
                    app.cfg.default_key_rps,
                    app.cfg.default_key_burst,
                    &parsed.scope.access_key_id,
                )
                .await?
                .ok_or(ApiError::Unauthorized)?;
            if !key.is_active_at(now) {
                return Err(ApiError::Unauthorized);
            }
            let headers_lc = collect_lowercase_headers(headers);
            let payload_hash = headers_lc
                .get("x-amz-content-sha256")
                .map(String::as_str)
                .unwrap_or(UNSIGNED_PAYLOAD);
            verify_header_request(
                &parsed,
                &key.secret_plain,
                method.as_str(),
                raw_path,
                raw_query,
                &headers_lc,
                payload_hash,
                now,
            )
            .map_err(|_| ApiError::Unauthorized)?;
            return finalize_key_principal(app, &key).await;
        }
    }

    // 3. Check AWS SigV4 Presigned URL query parameters (`?X-Amz-Algorithm=AWS4-HMAC-SHA256...`)
    if let Some(presign_res) = parse_presigned_query(raw_query) {
        let parsed = presign_res.map_err(|_| ApiError::Unauthorized)?;
        let key = app
            .iam
            .cache
            .lookup(
                &app.pool,
                &app.cfg.token,
                app.cfg.default_key_rps,
                app.cfg.default_key_burst,
                &parsed.scope.access_key_id,
            )
            .await?
            .ok_or(ApiError::Unauthorized)?;
        if !key.is_active_at(now) {
            return Err(ApiError::Unauthorized);
        }
        let headers_lc = collect_lowercase_headers(headers);
        verify_presigned_request(
            &parsed,
            &key.secret_plain,
            method.as_str(),
            raw_path,
            raw_query,
            &headers_lc,
            now,
        )
        .map_err(|_| ApiError::Unauthorized)?;
        return finalize_key_principal(app, &key).await;
    }

    // 4. Check `?token=` query string ONLY on read-only media/blob routes
    if allows_query_token(method, raw_path)
        && let Some(q) = raw_query
    {
        for kv in q.split('&') {
            if let Some(tok) = kv.strip_prefix("token=")
                && !tok.is_empty()
            {
                return authenticate_token_string(app, tok, now).await;
            }
        }
    }

    Err(ApiError::Unauthorized)
}

async fn authenticate_token_string(
    app: &AppState,
    token: &str,
    now: DateTime<Utc>,
) -> Result<(Principal, Option<(u32, u32)>), ApiError> {
    if token.is_empty() {
        return Err(ApiError::Unauthorized);
    }
    // Master ATLAS_TOKEN check (constant-time)
    if ct_eq(token.as_bytes(), app.cfg.token.as_bytes()) {
        return Ok((Principal::master_owner(), None));
    }
    // Scoped API key check: `<access_key_id>:<secret_access_key>`
    if let Some((ak, sk)) = token.split_once(':')
        && ak.starts_with("ATLK")
        && !sk.is_empty()
    {
        let key = app
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
            .ok_or(ApiError::Unauthorized)?;
        if !key.is_active_at(now) || !key.matches_secret(sk) {
            return Err(ApiError::Unauthorized);
        }
        return finalize_key_principal(app, &key).await;
    }
    Err(ApiError::Unauthorized)
}

async fn finalize_key_principal(
    app: &AppState,
    key: &cache::CachedKey,
) -> Result<(Principal, Option<(u32, u32)>), ApiError> {
    let decision = app
        .iam
        .limiter
        .check(&key.id, key.effective_rps, key.effective_burst);
    if !decision.allowed {
        return Err(ApiError::RateLimited {
            retry_after: decision.retry_after_secs,
            limit: decision.limit,
        });
    }
    app.iam
        .cache
        .touch_debounced(app.pool.clone(), key.id.clone())
        .await;
    let principal = Principal {
        account_id: key.account_id.clone(),
        role: key.role,
        key_id: Some(key.id.clone()),
        access_key_id: Some(key.access_key_id.clone()),
        scopes: key.scopes.clone(),
        buckets: key.buckets.clone(),
        quota_bytes: key.quota_bytes,
        is_master: false,
    };
    Ok((principal, Some((decision.limit, decision.remaining))))
}

/// Coarse route-level RBAC guard for `/v1` routes, ensuring scoped keys cannot
/// invoke privileged system, share, or write routes outside their scopes.
pub fn enforce_v1_route_policy(
    principal: &Principal,
    method: &Method,
    path: &str,
) -> ApiResult<()> {
    if principal.is_master {
        return Ok(());
    }
    if path.starts_with("/v1/system")
        || path.starts_with("/v1/accounts")
        || path.starts_with("/v1/keys")
        || path.starts_with("/v1/share")
    {
        return principal.require_owner_or_admin();
    }
    // Bucket routes perform their own fine-grained bucket + scope checks in handlers,
    // but we still enforce base read/write/delete scope at the perimeter.
    if path.starts_with("/v1/buckets") {
        let needed = match *method {
            Method::GET | Method::HEAD => "read",
            Method::DELETE => "delete",
            _ => "write",
        };
        return principal.require_scope(needed);
    }
    if path.starts_with("/v1/drive") {
        let needed = match *method {
            Method::GET | Method::HEAD => "read",
            Method::DELETE => "delete",
            _ => "write",
        };
        return principal.require_bucket("files", needed);
    }
    if path.starts_with("/v1/search")
        || path.starts_with("/v1/media/search")
        || path.starts_with("/v1/media/similar")
    {
        return principal.require_scope("media:search");
    }
    // Remaining /v1 photo/library/people/albums/assets routes map to bucket `media`
    let needed = match *method {
        Method::GET | Method::HEAD => "read",
        Method::DELETE => "delete",
        _ => "write",
    };
    principal.require_bucket("media", needed)
}

/// Middleware for `/v1` routes: authenticates, checks WebSocket `Origin` when upgrading,
/// enforces route RBAC, attaches `Principal`, and appends `X-RateLimit-*` headers.
pub async fn require_v1_auth(
    State(app): State<AppState>,
    mut req: Request,
    next: Next,
) -> Response {
    if req
        .headers()
        .get(header::UPGRADE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|u| u.eq_ignore_ascii_case("websocket"))
        && let Err(e) = verify_ws_origin(req.headers())
    {
        return e.into_response();
    }

    let (method, uri, headers) = (
        req.method().clone(),
        req.uri().clone(),
        req.headers().clone(),
    );
    let (principal, rl_headers) = match authenticate_request(&app, &method, &uri, &headers).await {
        Ok(pair) => pair,
        Err(e) => return e.into_response(),
    };
    if let Err(e) = enforce_v1_route_policy(&principal, &method, uri.path()) {
        return e.into_response();
    }

    req.extensions_mut().insert(principal);
    let mut resp = next.run(req).await;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_token_never_allowed_on_privileged_or_mutating_routes() {
        assert!(allows_query_token(&Method::GET, "/v1/assets/abc/original"));
        assert!(allows_query_token(&Method::GET, "/v1/assets/abc/thumb/512"));
        assert!(allows_query_token(
            &Method::GET,
            "/v1/drive/blobs/abc/doc.pdf"
        ));
        assert!(!allows_query_token(&Method::GET, "/v1/system/terminal"));
        assert!(!allows_query_token(
            &Method::POST,
            "/v1/system/power/shutdown"
        ));
        assert!(!allows_query_token(&Method::GET, "/v1/keys"));
        assert!(!allows_query_token(
            &Method::DELETE,
            "/v1/buckets/files/objects/a"
        ));
    }

    #[test]
    fn websocket_origin_blocks_cross_site_and_allows_native_apps() {
        let mut h = HeaderMap::new();
        h.insert(header::HOST, HeaderValue::from_static("atlas:8787"));
        assert!(verify_ws_origin(&h).is_ok());

        h.insert(
            header::ORIGIN,
            HeaderValue::from_static("http://atlas:8787"),
        );
        assert!(verify_ws_origin(&h).is_ok());

        h.insert(
            header::ORIGIN,
            HeaderValue::from_static("https://evil.example"),
        );
        assert!(verify_ws_origin(&h).is_err());
    }

    #[test]
    fn bucket_scoped_key_cannot_touch_system_or_other_buckets() {
        let p = Principal {
            account_id: "acct_bots".into(),
            role: AccountRole::Service,
            key_id: Some("key_1".into()),
            access_key_id: Some("ATLK123".into()),
            scopes: vec!["read".into(), "write".into()],
            buckets: vec!["shared".into()],
            quota_bytes: None,
            is_master: false,
        };
        assert!(enforce_v1_route_policy(&p, &Method::GET, "/v1/system/terminal").is_err());
        assert!(enforce_v1_route_policy(&p, &Method::GET, "/v1/keys").is_err());
        assert!(enforce_v1_route_policy(&p, &Method::GET, "/v1/drive/recent").is_err());
        assert!(p.require_bucket("shared", "write").is_ok());
        assert!(p.require_bucket("media", "read").is_err());
        assert!(p.require_bucket("shared", "delete").is_err());
    }
}
