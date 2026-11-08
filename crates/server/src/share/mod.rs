//! Link sharing through atlas-share, the owner's Cloudflare Worker (share/).
//!
//!   GET    /v1/shares          live shares, newest first
//!   POST   /v1/shares          share assets or an album → uploading
//!   GET    /v1/shares/{id}     one share (polled while uploading)
//!   DELETE /v1/shares/{id}     stop sharing: the files leave R2
//!
//! A share is a snapshot: its thumbnails, views (WebP photos, H.264 videos)
//! and, when allowed, the originals are uploaded to R2 under `s/<id>/`, then
//! the link preview chat apps show (`og`), then the manifest, which makes
//! the link live. Links work while atlas is off and expire after at most
//! [`MAX_DAYS`]; the hourly sweep removes expired files, the Worker's cron
//! and an R2 lifecycle rule do too. The wire format is in share/CONTRACT.md.

use anyhow::{Context, Result, bail};
use axum::extract::{Path as UrlPath, State};
use axum::routing::get;
use axum::{Json, Router};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::photos::VISIBLE;
use crate::{ApiError, ApiResult, App, AppState};

mod card;
mod follow;
mod media;
mod og;
mod remote;
mod upload;

pub use follow::{album_changed, album_removed, assets_hidden, purge_expired};
use remote::Remote;
pub use upload::resume;
use upload::spawn_upload;

/// No link lives longer than this, whatever is asked for.
pub const MAX_DAYS: i64 = 7;
const MAX_ITEMS: usize = 5000;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/shares", get(list).post(create))
        .route("/shares/{id}", get(one).delete(stop))
}

const SHARE_COLS: &str = "id, title, album_id, asset_ids, allow_download, has_password, state, \
                          done_bytes, total_bytes, error, created_at, expires_at, password, live";

fn share_json(app: &App, r: &tokio_postgres::Row) -> Value {
    let id: String = r.get(0);
    let assets: Vec<String> = r.get(3);
    json!({
        "id": id,
        "title": r.get::<_, String>(1),
        "url": format!("{}/s/{id}", app.cfg.share_url.as_deref().unwrap_or("")),
        "album_id": r.get::<_, Option<i64>>(2),
        "count": assets.len(),
        "cover": assets.first(),
        "allow_download": r.get::<_, bool>(4),
        "has_password": r.get::<_, bool>(5),
        "state": r.get::<_, String>(6),
        "done_bytes": r.get::<_, i64>(7),
        "total_bytes": r.get::<_, i64>(8),
        "error": r.get::<_, Option<String>>(9),
        // whole seconds: what the app's ISO 8601 decoder reads
        "created_at": r.get::<_, DateTime<Utc>>(10).to_rfc3339_opts(SecondsFormat::Secs, true),
        "expires_at": r.get::<_, DateTime<Utc>>(11).to_rfc3339_opts(SecondsFormat::Secs, true),
        // the owner's own app asks; recipients only ever see the Worker
        "password": r.get::<_, Option<String>>(12),
        // the link opens (the manifest is there); before that it says "almost ready"
        "live": r.get::<_, bool>(13),
    })
}

async fn list(State(app): State<AppState>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!(
                "SELECT {SHARE_COLS} FROM shares WHERE expires_at > now() ORDER BY created_at DESC"
            ),
            &[],
        )
        .await?;
    Ok(Json(
        json!({ "shares": rows.iter().map(|r| share_json(&app, r)).collect::<Vec<_>>() }),
    ))
}

async fn one(State(app): State<AppState>, UrlPath(id): UrlPath<String>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let row = c
        .query_opt(
            &format!("SELECT {SHARE_COLS} FROM shares WHERE id = $1 AND expires_at > now()"),
            &[&id],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    Ok(Json(share_json(&app, &row)))
}

#[derive(Deserialize)]
struct NewShare {
    title: String,
    #[serde(default)]
    ids: Option<Vec<String>>,
    #[serde(default)]
    album: Option<i64>,
    #[serde(default)]
    days: Option<i64>,
    #[serde(default)]
    allow_download: bool,
    #[serde(default)]
    password: Option<String>,
}

async fn create(State(app): State<AppState>, Json(b): Json<NewShare>) -> ApiResult<Json<Value>> {
    if !app.cfg.sharing() {
        return Err(ApiError::Unavailable("sharing is not set up"));
    }
    let title = b.title.trim();
    if title.is_empty() || title.chars().count() > 200 {
        return Err(ApiError::BadRequest("title must be 1 to 200 characters"));
    }
    let days = b.days.unwrap_or(MAX_DAYS);
    if !(1..=MAX_DAYS).contains(&days) {
        return Err(ApiError::BadRequest("a link lasts 1 to 7 days"));
    }
    let password = b
        .password
        .map(|p| p.trim().to_string())
        .filter(|p| !p.is_empty());
    if password.as_ref().is_some_and(|p| p.chars().count() > 200) {
        return Err(ApiError::BadRequest("password is too long"));
    }

    let c = app.pool.get().await?;
    // an album has one link: asking again returns it (and retries a failed one)
    if let Some(album) = b.album {
        let existing = c
            .query_opt(
                &format!(
                    "SELECT {SHARE_COLS} FROM shares WHERE album_id = $1 AND expires_at > now()
                     ORDER BY created_at DESC LIMIT 1"
                ),
                &[&album],
            )
            .await?;
        if let Some(row) = existing {
            let id: String = row.get(0);
            if row.get::<_, String>(6) == "failed" {
                album_changed(&app, album).await?;
                let row = c
                    .query_one(
                        &format!("SELECT {SHARE_COLS} FROM shares WHERE id = $1"),
                        &[&id],
                    )
                    .await?;
                return Ok(Json(share_json(&app, &row)));
            }
            return Ok(Json(share_json(&app, &row)));
        }
    }
    let assets: Vec<String> = match (&b.ids, b.album) {
        (Some(ids), None) => c
            .query(
                &format!(
                    "SELECT id FROM assets WHERE id = ANY($1) AND {VISIBLE}
                     ORDER BY taken_at NULLS LAST, id"
                ),
                &[ids],
            )
            .await?
            .iter()
            .map(|r| r.get(0))
            .collect(),
        (None, Some(album)) => album_assets(&c, album).await?,
        _ => return Err(ApiError::BadRequest("give either ids or album")),
    };
    if assets.is_empty() {
        return Err(ApiError::BadRequest("nothing to share"));
    }
    if assets.len() > MAX_ITEMS {
        return Err(ApiError::BadRequest("at most 5000 items per link"));
    }

    let id = new_id()?;
    let row = c
        .query_one(
            &format!(
                "INSERT INTO shares (id, title, album_id, asset_ids, allow_download, password, has_password, expires_at)
                 VALUES ($1, $2, $3, $4, $5, $6, $7, now() + make_interval(days => $8))
                 RETURNING {SHARE_COLS}"
            ),
            &[&id, &title, &b.album, &assets, &b.allow_download, &password, &password.is_some(), &(days as i32)],
        )
        .await?;
    spawn_upload(app.clone(), id);
    Ok(Json(share_json(&app, &row)))
}

async fn stop(State(app): State<AppState>, UrlPath(id): UrlPath<String>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    if c.query_opt("SELECT 1 FROM shares WHERE id = $1", &[&id])
        .await?
        .is_none()
    {
        return Err(ApiError::NotFound);
    }
    // the row goes first, so a running upload stops at its next file
    c.execute("DELETE FROM shares WHERE id = $1", &[&id])
        .await?;
    if let Some(remote) = Remote::new(&app) {
        remote.delete(&id).await.map_err(|e| {
            tracing::warn!("share {id}: remote delete failed, the Worker's cron will: {e:#}");
            ApiError::Unavailable(
                "the link stopped, but atlas-share could not be reached to remove the files yet",
            )
        })?;
    }
    Ok(Json(json!({ "deleted": true })))
}

/// 22 base62 characters from the OS's CSPRNG.
fn new_id() -> Result<String> {
    const ALPHABET: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    let mut bytes = [0u8; 64];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| std::io::Read::read_exact(&mut f, &mut bytes))
        .context("no random source")?;
    // 248 = 4 × 62: rejecting the rest keeps every character equally likely
    let id: String = bytes
        .iter()
        .filter(|&&b| b < 248)
        .take(22)
        .map(|&b| ALPHABET[(b % 62) as usize] as char)
        .collect();
    if id.len() < 22 {
        bail!("not enough random bytes");
    }
    Ok(id)
}

/// The visible assets of an album, in the order a share shows them.
async fn album_assets(c: &deadpool_postgres::Object, album: i64) -> Result<Vec<String>> {
    Ok(c.query(
        &format!(
            "SELECT assets.id FROM assets JOIN album_assets aa ON aa.asset_id = assets.id
                 WHERE aa.album_id = $1 AND {VISIBLE}
                 ORDER BY assets.taken_at NULLS LAST, assets.id"
        ),
        &[&album],
    )
    .await?
    .iter()
    .map(|r| r.get(0))
    .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_22_base62() {
        let a = new_id().unwrap();
        let b = new_id().unwrap();
        assert_eq!(a.len(), 22);
        assert!(a.chars().all(|c| c.is_ascii_alphanumeric()));
        assert_ne!(a, b);
    }
}
