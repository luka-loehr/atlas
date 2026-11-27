//! Accounts and API/S3 keys management handlers (`/v1/auth/whoami`, `/v1/accounts`, `/v1/keys`).

use atlas_common::crypto::{
    generate_access_key_id, generate_prefixed_id, generate_secret_key, seal_secret, sha256_bytes,
};
use atlas_common::models::{
    AccountInfo, AccountRole, AccountStatus, ApiKeyInfo, CreateAccountRequest, CreateKeyRequest,
    CreateKeyResponse, UpdateAccountRequest, VALID_SCOPES,
};
use atlas_common::validate::is_valid_bucket_name;
use axum::Json;
use axum::extract::{Extension, Path, State};
use chrono::{Duration, Utc};
use serde_json::{Value, json};
use tokio_postgres::Row;

use super::Principal;
use crate::{ApiError, ApiResult, AppState};

pub async fn whoami(Extension(principal): Extension<Principal>) -> Json<Value> {
    Json(json!({
        "account_id": principal.account_id,
        "role": principal.role,
        "key_id": principal.key_id,
        "access_key_id": principal.access_key_id,
        "scopes": principal.scopes,
        "buckets": principal.buckets,
        "is_master": principal.is_master,
    }))
}

fn valid_account_slug(s: &str) -> bool {
    let s = s.trim();
    (2..=64).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'-' | b'_'))
}

fn account_from_row(r: &Row) -> AccountInfo {
    let role_raw: String = r.get(3);
    let status_raw: String = r.get(4);
    AccountInfo {
        id: r.get(0),
        name: r.get(1),
        display_name: r.get(2),
        role: AccountRole::parse(&role_raw).unwrap_or(AccountRole::Service),
        status: AccountStatus::parse(&status_raw).unwrap_or(AccountStatus::Active),
        rate_limit_rps: r.get(5),
        rate_limit_burst: r.get(6),
        quota_bytes: r.get(7),
        created_at: r.get(8),
        updated_at: r.get(9),
    }
}

const ACCOUNT_COLS: &str = "id, name, display_name, role, status, rate_limit_rps, rate_limit_burst, quota_bytes, created_at, updated_at";

pub async fn list_accounts(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
) -> ApiResult<Json<Value>> {
    p.require_owner_or_admin()?;
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!("SELECT {ACCOUNT_COLS} FROM accounts ORDER BY created_at ASC"),
            &[],
        )
        .await?;
    let accounts: Vec<AccountInfo> = rows.iter().map(account_from_row).collect();
    Ok(Json(json!({ "accounts": accounts })))
}

pub async fn get_account(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(id): Path<String>,
) -> ApiResult<Json<AccountInfo>> {
    p.require_owner_or_admin()?;
    let c = app.pool.get().await?;
    let row = c
        .query_opt(
            &format!("SELECT {ACCOUNT_COLS} FROM accounts WHERE id = $1 OR name = $1"),
            &[&id],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    Ok(Json(account_from_row(&row)))
}

pub async fn create_account(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Json(req): Json<CreateAccountRequest>,
) -> ApiResult<Json<AccountInfo>> {
    p.require_owner_or_admin()?;
    let name = req.name.trim().to_ascii_lowercase();
    if !valid_account_slug(&name) {
        return Err(ApiError::BadRequest(
            "invalid account name (2..64 lowercase letters, digits, '-' or '_')",
        ));
    }
    if req.role == AccountRole::Owner {
        return Err(ApiError::BadRequest(
            "only the built-in owner account may hold role 'owner'",
        ));
    }
    if req.rate_limit_rps.is_some_and(|v| v <= 0)
        || req.rate_limit_burst.is_some_and(|v| v <= 0)
        || req.quota_bytes.is_some_and(|v| v < 0)
    {
        return Err(ApiError::BadRequest(
            "rate limits must be > 0 and quota >= 0",
        ));
    }

    let id = generate_prefixed_id("acct", 8)?;
    let c = app.pool.get().await?;
    if c.query_opt("SELECT 1 FROM accounts WHERE name = $1", &[&name])
        .await?
        .is_some()
    {
        return Err(ApiError::Conflict("account name already exists"));
    }
    let row = c
        .query_one(
            &format!(
                "INSERT INTO accounts (id, name, display_name, role, rate_limit_rps, rate_limit_burst, quota_bytes)
                 VALUES ($1, $2, $3, $4, $5, $6, $7)
                 RETURNING {ACCOUNT_COLS}"
            ),
            &[
                &id,
                &name,
                &req.display_name,
                &req.role.as_str(),
                &req.rate_limit_rps,
                &req.rate_limit_burst,
                &req.quota_bytes,
            ],
        )
        .await?;
    app.iam.cache.invalidate();
    Ok(Json(account_from_row(&row)))
}

pub async fn update_account(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(id): Path<String>,
    Json(req): Json<UpdateAccountRequest>,
) -> ApiResult<Json<AccountInfo>> {
    p.require_owner_or_admin()?;
    if id == "owner"
        && (req.status == Some(AccountStatus::Suspended)
            || req.role.is_some_and(|r| r != AccountRole::Owner))
    {
        return Err(ApiError::BadRequest(
            "cannot suspend or downgrade the built-in owner account",
        ));
    }
    if req.role == Some(AccountRole::Owner) && id != "owner" {
        return Err(ApiError::BadRequest(
            "only the built-in owner account may hold role 'owner'",
        ));
    }
    if req.rate_limit_rps.is_some_and(|v| v <= 0)
        || req.rate_limit_burst.is_some_and(|v| v <= 0)
        || req.quota_bytes.is_some_and(|v| v < 0)
    {
        return Err(ApiError::BadRequest(
            "rate limits must be > 0 and quota >= 0",
        ));
    }

    let c = app.pool.get().await?;
    let existing = c
        .query_opt(
            &format!("SELECT {ACCOUNT_COLS} FROM accounts WHERE id = $1"),
            &[&id],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    let cur = account_from_row(&existing);

    let display_name = req.display_name.or(cur.display_name);
    let role = req.role.unwrap_or(cur.role);
    let status = req.status.unwrap_or(cur.status);
    let rps = req.rate_limit_rps.or(cur.rate_limit_rps);
    let burst = req.rate_limit_burst.or(cur.rate_limit_burst);
    let quota = req.quota_bytes.or(cur.quota_bytes);

    let row = c
        .query_one(
            &format!(
                "UPDATE accounts
                    SET display_name = $2, role = $3, status = $4,
                        rate_limit_rps = $5, rate_limit_burst = $6, quota_bytes = $7,
                        updated_at = now()
                  WHERE id = $1
                  RETURNING {ACCOUNT_COLS}"
            ),
            &[
                &id,
                &display_name,
                &role.as_str(),
                &status.as_str(),
                &rps,
                &burst,
                &quota,
            ],
        )
        .await?;
    app.iam.cache.invalidate();
    Ok(Json(account_from_row(&row)))
}

pub async fn delete_account(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    p.require_owner_or_admin()?;
    if id == "owner" {
        return Err(ApiError::BadRequest(
            "cannot delete the built-in owner account",
        ));
    }
    let c = app.pool.get().await?;
    let n = c
        .execute("DELETE FROM accounts WHERE id = $1", &[&id])
        .await?;
    if n == 0 {
        return Err(ApiError::NotFound);
    }
    app.iam.cache.invalidate();
    Ok(Json(json!({ "deleted": n })))
}

// ------------------------------------------------------------------ keys -----

const KEY_COLS: &str = "id, access_key_id, name, account_id, scopes, buckets, rate_limit_rps, rate_limit_burst, expires_at, revoked_at, last_used_at, created_at";

fn key_from_row(r: &Row) -> ApiKeyInfo {
    ApiKeyInfo {
        id: r.get(0),
        access_key_id: r.get(1),
        name: r.get(2),
        account_id: r.get(3),
        scopes: r.get(4),
        buckets: r.get(5),
        rate_limit_rps: r.get(6),
        rate_limit_burst: r.get(7),
        expires_at: r.get(8),
        revoked_at: r.get(9),
        last_used_at: r.get(10),
        created_at: r.get(11),
    }
}

pub async fn list_keys(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
) -> ApiResult<Json<Value>> {
    p.require_owner_or_admin()?;
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!("SELECT {KEY_COLS} FROM api_keys ORDER BY created_at DESC"),
            &[],
        )
        .await?;
    let keys: Vec<ApiKeyInfo> = rows.iter().map(key_from_row).collect();
    Ok(Json(json!({ "keys": keys })))
}

pub async fn get_key(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(id): Path<String>,
) -> ApiResult<Json<ApiKeyInfo>> {
    p.require_owner_or_admin()?;
    let c = app.pool.get().await?;
    let row = c
        .query_opt(
            &format!("SELECT {KEY_COLS} FROM api_keys WHERE id = $1 OR access_key_id = $1"),
            &[&id],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    Ok(Json(key_from_row(&row)))
}

pub async fn create_key(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Json(req): Json<CreateKeyRequest>,
) -> ApiResult<Json<CreateKeyResponse>> {
    p.require_owner_or_admin()?;
    let name = req.name.trim();
    if name.is_empty() || name.len() > 128 {
        return Err(ApiError::BadRequest("key name must be 1..128 characters"));
    }
    if req.scopes.is_empty()
        || req
            .scopes
            .iter()
            .any(|s| !VALID_SCOPES.contains(&s.as_str()))
    {
        return Err(ApiError::BadRequest(
            "invalid scopes (expected subset of read, write, delete, media:search, admin)",
        ));
    }
    if req.scopes.iter().any(|s| s == "admin") && p.role != AccountRole::Owner {
        return Err(ApiError::Forbidden("only owner may mint admin-scoped keys"));
    }
    for b in &req.buckets {
        if b != "*" && !is_valid_bucket_name(b) {
            return Err(ApiError::BadRequest("invalid bucket name in allowlist"));
        }
    }
    if req.rate_limit_rps.is_some_and(|v| v <= 0) || req.rate_limit_burst.is_some_and(|v| v <= 0) {
        return Err(ApiError::BadRequest("rate limits must be > 0"));
    }
    let expires_at = match req.expires_in_secs {
        Some(secs) if secs <= 0 => {
            return Err(ApiError::BadRequest("expires_in_secs must be > 0"));
        }
        Some(secs) => Some(Utc::now() + Duration::seconds(secs)),
        None => None,
    };

    let account_id = req.account_id.unwrap_or_else(|| "owner".to_string());
    let c = app.pool.get().await?;
    let acct_row = c
        .query_opt(
            "SELECT id FROM accounts WHERE id = $1 OR name = $1",
            &[&account_id],
        )
        .await?
        .ok_or(ApiError::BadRequest("unknown account"))?;
    let resolved_account_id: String = acct_row.get(0);

    let id = generate_prefixed_id("key", 8)?;
    let access_key_id = generate_access_key_id()?;
    let secret_access_key = generate_secret_key()?;
    let sealed_secret = seal_secret(
        &app.cfg.token,
        access_key_id.as_bytes(),
        secret_access_key.as_bytes(),
    )?;
    let secret_sha = sha256_bytes(secret_access_key.as_bytes()).to_vec();

    let row = c
        .query_one(
            &format!(
                "INSERT INTO api_keys (
                    id, access_key_id, name, account_id, sealed_secret, secret_sha256,
                    scopes, buckets, rate_limit_rps, rate_limit_burst, expires_at
                 )
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
                 RETURNING {KEY_COLS}"
            ),
            &[
                &id,
                &access_key_id,
                &name,
                &resolved_account_id,
                &sealed_secret,
                &secret_sha,
                &req.scopes,
                &req.buckets,
                &req.rate_limit_rps,
                &req.rate_limit_burst,
                &expires_at,
            ],
        )
        .await?;
    app.iam.cache.invalidate();

    let key = key_from_row(&row);
    let bearer_token = format!("{}:{secret_access_key}", key.access_key_id);
    Ok(Json(CreateKeyResponse {
        key,
        secret_access_key,
        bearer_token,
    }))
}

pub async fn revoke_key(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(id): Path<String>,
) -> ApiResult<Json<ApiKeyInfo>> {
    p.require_owner_or_admin()?;
    let c = app.pool.get().await?;
    let row = c
        .query_opt(
            &format!(
                "UPDATE api_keys
                    SET revoked_at = coalesce(revoked_at, now())
                  WHERE id = $1 OR access_key_id = $1
                  RETURNING {KEY_COLS}"
            ),
            &[&id],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    let info = key_from_row(&row);
    app.iam.cache.invalidate();
    app.iam.limiter.evict(&info.id);
    Ok(Json(info))
}

pub async fn delete_key(
    State(app): State<AppState>,
    Extension(p): Extension<Principal>,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    p.require_owner_or_admin()?;
    let c = app.pool.get().await?;
    let row = c
        .query_opt(
            "DELETE FROM api_keys WHERE id = $1 OR access_key_id = $1 RETURNING id",
            &[&id],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    let key_id: String = row.get(0);
    app.iam.cache.invalidate();
    app.iam.limiter.evict(&key_id);
    Ok(Json(json!({ "deleted": 1, "id": key_id })))
}
