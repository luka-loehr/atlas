//! Low-latency in-memory cache of active API/S3 keys and their accounts.
//!
//! Loaded once from Postgres and invalidated immediately whenever `api_keys` or
//! `accounts` changes (both locally and via `LISTEN atlas_keys`), so Bearer and
//! AWS SigV4 verification take nanoseconds without touching the database.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use atlas_common::crypto::{ct_eq, open_secret, sha256_bytes};
use atlas_common::models::{AccountRole, AccountStatus};
use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use tokio::sync::{Mutex, RwLock};

#[derive(Debug, Clone)]
pub struct CachedKey {
    pub id: String,
    pub access_key_id: String,
    pub account_id: String,
    pub role: AccountRole,
    pub account_status: AccountStatus,
    pub secret_plain: String,
    pub secret_sha256: [u8; 32],
    pub scopes: Vec<String>,
    pub buckets: Vec<String>,
    pub effective_rps: u32,
    pub effective_burst: u32,
    pub expires_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub quota_bytes: Option<i64>,
}

impl CachedKey {
    pub fn is_active_at(&self, now: DateTime<Utc>) -> bool {
        self.account_status == AccountStatus::Active
            && self.revoked_at.is_none()
            && self.expires_at.is_none_or(|exp| now < exp)
    }

    pub fn matches_secret(&self, candidate: &str) -> bool {
        let digest = sha256_bytes(candidate.as_bytes());
        ct_eq(&digest, &self.secret_sha256)
    }
}

pub struct KeyCache {
    by_access_key: RwLock<HashMap<String, Arc<CachedKey>>>,
    stale: AtomicBool,
    last_touched: Mutex<HashMap<String, Instant>>,
}

impl Default for KeyCache {
    fn default() -> Self {
        Self {
            by_access_key: RwLock::new(HashMap::new()),
            stale: AtomicBool::new(true),
            last_touched: Mutex::new(HashMap::new()),
        }
    }
}

impl KeyCache {
    pub fn invalidate(&self) {
        self.stale.store(true, Ordering::SeqCst);
    }

    async fn ensure_fresh(
        &self,
        pool: &Pool,
        master_secret: &str,
        def_rps: u32,
        def_burst: u32,
    ) -> Result<()> {
        if !self.stale.swap(false, Ordering::SeqCst) {
            return Ok(());
        }
        let res = self.reload(pool, master_secret, def_rps, def_burst).await;
        if res.is_err() {
            self.stale.store(true, Ordering::SeqCst);
        }
        res
    }

    async fn reload(
        &self,
        pool: &Pool,
        master_secret: &str,
        def_rps: u32,
        def_burst: u32,
    ) -> Result<()> {
        let c = pool.get().await?;
        let rows = c
            .query(
                "SELECT k.id, k.access_key_id, k.account_id, a.role, a.status,
                        k.sealed_secret, k.secret_sha256, k.scopes, k.buckets,
                        k.rate_limit_rps, k.rate_limit_burst,
                        a.rate_limit_rps, a.rate_limit_burst,
                        k.expires_at, k.revoked_at, a.quota_bytes
                   FROM api_keys k
                   JOIN accounts a ON a.id = k.account_id",
                &[],
            )
            .await?;

        let mut next = HashMap::with_capacity(rows.len());
        for r in rows {
            let id: String = r.get(0);
            let access_key_id: String = r.get(1);
            let account_id: String = r.get(2);
            let role_raw: String = r.get(3);
            let status_raw: String = r.get(4);
            let sealed: Vec<u8> = r.get(5);
            let sha_vec: Vec<u8> = r.get(6);
            let scopes: Vec<String> = r.get(7);
            let buckets: Vec<String> = r.get(8);
            let key_rps: Option<i32> = r.get(9);
            let key_burst: Option<i32> = r.get(10);
            let acct_rps: Option<i32> = r.get(11);
            let acct_burst: Option<i32> = r.get(12);
            let expires_at: Option<DateTime<Utc>> = r.get(13);
            let revoked_at: Option<DateTime<Utc>> = r.get(14);
            let quota_bytes: Option<i64> = r.get(15);

            let Ok(plain_bytes) = open_secret(master_secret, access_key_id.as_bytes(), &sealed)
            else {
                tracing::warn!("iam: skipping key {id} ({access_key_id}): failed to unseal secret");
                continue;
            };
            let Ok(secret_plain) = String::from_utf8(plain_bytes) else {
                continue;
            };
            let Ok(secret_sha256): Result<[u8; 32], _> = sha_vec.try_into() else {
                continue;
            };

            let rps = key_rps
                .or(acct_rps)
                .and_then(|v| u32::try_from(v).ok())
                .unwrap_or(def_rps);
            let burst = key_burst
                .or(acct_burst)
                .and_then(|v| u32::try_from(v).ok())
                .unwrap_or_else(|| def_burst.max(rps));

            let cached = CachedKey {
                id,
                access_key_id: access_key_id.clone(),
                account_id,
                role: AccountRole::parse(&role_raw).unwrap_or(AccountRole::Service),
                account_status: AccountStatus::parse(&status_raw)
                    .unwrap_or(AccountStatus::Suspended),
                secret_plain,
                secret_sha256,
                scopes,
                buckets,
                effective_rps: rps,
                effective_burst: burst,
                expires_at,
                revoked_at,
                quota_bytes,
            };
            next.insert(access_key_id, Arc::new(cached));
        }

        let mut guard = self.by_access_key.write().await;
        *guard = next;
        Ok(())
    }

    pub async fn lookup(
        &self,
        pool: &Pool,
        master_secret: &str,
        def_rps: u32,
        def_burst: u32,
        access_key_id: &str,
    ) -> Result<Option<Arc<CachedKey>>> {
        self.ensure_fresh(pool, master_secret, def_rps, def_burst)
            .await?;
        let guard = self.by_access_key.read().await;
        Ok(guard.get(access_key_id).cloned())
    }

    /// Asynchronously records `last_used_at` at most once per minute per key.
    pub async fn touch_debounced(&self, pool: Pool, key_id: String) {
        let should_update = {
            let mut map = self.last_touched.lock().await;
            let now = Instant::now();
            match map.get(&key_id) {
                Some(&prev) if now.duration_since(prev) < Duration::from_secs(60) => false,
                _ => {
                    map.insert(key_id.clone(), now);
                    true
                }
            }
        };
        if should_update {
            tokio::spawn(async move {
                if let Ok(c) = pool.get().await {
                    let _ = c
                        .execute(
                            "UPDATE api_keys SET last_used_at = now() WHERE id = $1",
                            &[&key_id],
                        )
                        .await;
                }
            });
        }
    }
}
