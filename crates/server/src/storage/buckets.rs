//! Bucket lifecycle operations (`list`, `get`, `create`, `delete`, quota check).

use atlas_common::models::{BucketInfo, BucketKind, CreateBucketRequest};
use atlas_common::validate::is_valid_bucket_name;
use tokio_postgres::Row;

use crate::iam::Principal;
use crate::{ApiError, ApiResult, App};

fn bucket_from_row(r: &Row) -> BucketInfo {
    let kind_raw: String = r.get(1);
    BucketInfo {
        name: r.get(0),
        kind: BucketKind::parse(&kind_raw).unwrap_or(BucketKind::General),
        owner_account_id: r.get(2),
        object_count: r.get(3),
        total_bytes: r.get(4),
        quota_bytes: r.get(5),
        public_read: r.get(6),
        created_at: r.get(7),
    }
}

pub async fn list_buckets(app: &App, principal: &Principal) -> ApiResult<Vec<BucketInfo>> {
    principal.require_scope("read")?;
    let c = app.pool.get().await?;
    let rows = c
        .query(
            "SELECT b.name, b.kind, b.owner_account_id,
                    count(o.key) FILTER (WHERE o.trashed_at IS NULL) AS object_count,
                    coalesce(sum(o.size_bytes) FILTER (WHERE o.trashed_at IS NULL), 0)::bigint AS total_bytes,
                    b.quota_bytes, b.public_read, b.created_at
               FROM buckets b
               LEFT JOIN objects o ON o.bucket = b.name
              GROUP BY b.name
              ORDER BY b.name ASC",
            &[],
        )
        .await?;
    Ok(rows
        .iter()
        .map(bucket_from_row)
        .filter(|b| principal.can_access_bucket(&b.name))
        .collect())
}

pub async fn get_bucket(app: &App, principal: &Principal, name: &str) -> ApiResult<BucketInfo> {
    principal.require_bucket(name, "read")?;
    let c = app.pool.get().await?;
    let row = c
        .query_opt(
            "SELECT b.name, b.kind, b.owner_account_id,
                    count(o.key) FILTER (WHERE o.trashed_at IS NULL) AS object_count,
                    coalesce(sum(o.size_bytes) FILTER (WHERE o.trashed_at IS NULL), 0)::bigint AS total_bytes,
                    b.quota_bytes, b.public_read, b.created_at
               FROM buckets b
               LEFT JOIN objects o ON o.bucket = b.name
              WHERE b.name = $1
              GROUP BY b.name",
            &[&name],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    Ok(bucket_from_row(&row))
}

pub async fn bucket_exists(app: &App, name: &str) -> ApiResult<Option<BucketKind>> {
    let c = app.pool.get().await?;
    let row = c
        .query_opt("SELECT kind FROM buckets WHERE name = $1", &[&name])
        .await?;
    Ok(row.map(|r| {
        let s: String = r.get(0);
        BucketKind::parse(&s).unwrap_or(BucketKind::General)
    }))
}

pub async fn create_bucket(
    app: &App,
    principal: &Principal,
    req: &CreateBucketRequest,
) -> ApiResult<BucketInfo> {
    let name = req.name.trim();
    if !is_valid_bucket_name(name) {
        return Err(ApiError::BadRequest(
            "invalid bucket name (3..63 lowercase alphanumeric, '-' or '.')",
        ));
    }
    principal.require_bucket(name, "write")?;
    if req.quota_bytes.is_some_and(|q| q < 0) {
        return Err(ApiError::BadRequest("quota_bytes must be >= 0"));
    }

    let c = app.pool.get().await?;
    c.execute(
        "INSERT INTO buckets (name, kind, owner_account_id, quota_bytes)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (name) DO NOTHING",
        &[
            &name,
            &req.kind.as_str(),
            &principal.account_id,
            &req.quota_bytes,
        ],
    )
    .await?;
    drop(c);
    get_bucket(app, principal, name).await
}

pub async fn delete_bucket(app: &App, principal: &Principal, name: &str) -> ApiResult<()> {
    if matches!(name, "media" | "files") {
        return Err(ApiError::Conflict(
            "built-in system buckets 'media' and 'files' cannot be deleted",
        ));
    }
    principal.require_bucket(name, "delete")?;
    let c = app.pool.get().await?;
    if c.query_opt("SELECT 1 FROM buckets WHERE name = $1", &[&name])
        .await?
        .is_none()
    {
        return Err(ApiError::NotFound);
    }
    let has_objects = c
        .query_opt(
            "SELECT 1 FROM objects WHERE bucket = $1 AND trashed_at IS NULL LIMIT 1",
            &[&name],
        )
        .await?
        .is_some();
    if has_objects {
        return Err(ApiError::Conflict("bucket is not empty"));
    }
    c.execute("DELETE FROM objects WHERE bucket = $1", &[&name])
        .await?;
    c.execute("DELETE FROM buckets WHERE name = $1", &[&name])
        .await?;
    Ok(())
}

/// Checks bucket quota and account quota before storing `incoming_bytes`.
pub async fn enforce_quotas(
    app: &App,
    principal: &Principal,
    bucket: &str,
    incoming_bytes: u64,
) -> ApiResult<()> {
    let c = app.pool.get().await?;
    let b_row = c
        .query_opt(
            "SELECT quota_bytes FROM buckets WHERE name = $1",
            &[&bucket],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    let bucket_quota: Option<i64> = b_row.get(0);

    if let Some(limit) = bucket_quota {
        let used: i64 = c
            .query_one(
                "SELECT coalesce(sum(size_bytes), 0)::bigint FROM objects WHERE bucket = $1 AND trashed_at IS NULL",
                &[&bucket],
            )
            .await?
            .get(0);
        if used.saturating_add(incoming_bytes as i64) > limit {
            return Err(ApiError::TooLarge);
        }
    }

    if let Some(acct_limit) = principal.quota_bytes {
        let acct_used: i64 = c
            .query_one(
                "SELECT coalesce(sum(size_bytes), 0)::bigint FROM objects WHERE owner_account_id = $1 AND trashed_at IS NULL",
                &[&principal.account_id],
            )
            .await?
            .get(0);
        if acct_used.saturating_add(incoming_bytes as i64) > acct_limit {
            return Err(ApiError::TooLarge);
        }
    }
    Ok(())
}
