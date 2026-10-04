//! Link sharing through atlas-share, the owner's Cloudflare Worker (share/).
//!
//!   GET    /v1/shares          live shares, newest first
//!   POST   /v1/shares          share assets or an album → uploading
//!   GET    /v1/shares/{id}     one share (polled while uploading)
//!   DELETE /v1/shares/{id}     stop sharing: the files leave R2
//!
//! A share is a snapshot: its thumbnails, views (WebP photos, H.264 videos)
//! and, when allowed, the originals are uploaded to R2 under `s/<id>/`, then
//! the manifest, which makes the link live. Links work while atlas is off and
//! expire after at most [`MAX_DAYS`]; the hourly sweep removes expired files,
//! the Worker's cron and an R2 lifecycle rule do too. The wire format is in
//! share/CONTRACT.md.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use axum::extract::{Path as UrlPath, State};
use axum::routing::get;
use axum::{Json, Router};
use chrono::{DateTime, SecondsFormat, Utc};
use futures_util::{TryStreamExt, stream};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::io::AsyncReadExt;

use crate::jobs::{preview, video};
use crate::photos::VISIBLE;
use crate::{ApiError, ApiResult, App, AppState, util};

/// No link lives longer than this, whatever is asked for.
pub const MAX_DAYS: i64 = 7;
/// Files up to this size go up in one request; larger ones in parts. Small
/// parts keep the progress the app shows moving (R2's minimum is 5 MiB).
const SINGLE_MAX: u64 = 16 << 20;
const PART: usize = 16 << 20;
/// Files uploaded side by side.
const PARALLEL: usize = 4;
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
            &format!("SELECT {SHARE_COLS} FROM shares WHERE expires_at > now() ORDER BY created_at DESC"),
            &[],
        )
        .await?;
    Ok(Json(json!({ "shares": rows.iter().map(|r| share_json(&app, r)).collect::<Vec<_>>() })))
}

async fn one(State(app): State<AppState>, UrlPath(id): UrlPath<String>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let row = c
        .query_opt(&format!("SELECT {SHARE_COLS} FROM shares WHERE id = $1 AND expires_at > now()"), &[&id])
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
    let password = b.password.map(|p| p.trim().to_string()).filter(|p| !p.is_empty());
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
                let row = c.query_one(&format!("SELECT {SHARE_COLS} FROM shares WHERE id = $1"), &[&id]).await?;
                return Ok(Json(share_json(&app, &row)));
            }
            return Ok(Json(share_json(&app, &row)));
        }
    }
    let rows = match (&b.ids, b.album) {
        (Some(ids), None) => {
            c.query(
                &format!(
                    "SELECT id FROM assets WHERE id = ANY($1) AND {VISIBLE}
                     ORDER BY taken_at NULLS LAST, id"
                ),
                &[ids],
            )
            .await?
        }
        (None, Some(album)) => {
            c.query(
                &format!(
                    "SELECT assets.id FROM assets JOIN album_assets aa ON aa.asset_id = assets.id
                     WHERE aa.album_id = $1 AND {VISIBLE}
                     ORDER BY assets.taken_at NULLS LAST, assets.id"
                ),
                &[&album],
            )
            .await?
        }
        _ => return Err(ApiError::BadRequest("give either ids or album")),
    };
    let assets: Vec<String> = rows.iter().map(|r| r.get(0)).collect();
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
    if c.query_opt("SELECT 1 FROM shares WHERE id = $1", &[&id]).await?.is_none() {
        return Err(ApiError::NotFound);
    }
    // the row goes first, so a running upload stops at its next file
    c.execute("DELETE FROM shares WHERE id = $1", &[&id]).await?;
    if let Some(remote) = Remote::new(&app) {
        remote.delete(&id).await.map_err(|e| {
            tracing::warn!("share {id}: remote delete failed, the Worker's cron will: {e:#}");
            ApiError::Unavailable("the link stopped, but atlas-share could not be reached to remove the files yet")
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
    let id: String = bytes.iter().filter(|&&b| b < 248).take(22).map(|&b| ALPHABET[(b % 62) as usize] as char).collect();
    if id.len() < 22 {
        bail!("not enough random bytes");
    }
    Ok(id)
}

// MARK: - Uploading

/// Uploads every share still `uploading` (after a restart, they resume where
/// they stopped: files already in R2 are skipped).
pub async fn resume(app: AppState) {
    let Ok(c) = app.pool.get().await else { return };
    let Ok(rows) = c.query("SELECT id FROM shares WHERE state = 'uploading' AND expires_at > now()", &[]).await
    else {
        return;
    };
    for r in rows {
        spawn_upload(app.clone(), r.get(0));
    }
}

/// Shares uploading right now; `true` = changed meanwhile, upload once more.
static RUNNING: std::sync::LazyLock<std::sync::Mutex<std::collections::HashMap<String, bool>>> =
    std::sync::LazyLock::new(Default::default);

/// Uploads a share in the background, on atlas: the phone only asks. A share
/// already uploading runs once more when it is done.
fn spawn_upload(app: AppState, id: String) {
    {
        let mut running = RUNNING.lock().unwrap();
        if let Some(again) = running.get_mut(&id) {
            *again = true;
            return;
        }
        running.insert(id.clone(), false);
    }
    tokio::spawn(async move {
        loop {
            run_upload(&app, &id).await;
            let mut running = RUNNING.lock().unwrap();
            if running.get(&id) == Some(&true) {
                running.insert(id.clone(), false);
            } else {
                running.remove(&id);
                break;
            }
        }
    });
}

async fn run_upload(app: &AppState, id: &str) {
    let Err(e) = upload(app, id).await else { return };
    tracing::warn!("share {id}: {e:#}");
    let message = format!("{e:#}").lines().next().unwrap_or("upload failed").chars().take(300).collect::<String>();
    if let Ok(c) = app.pool.get().await {
        let _ = c
            .execute("UPDATE shares SET state = 'failed', error = $2 WHERE id = $1 AND state = 'uploading'", &[&id, &message])
            .await;
    }
}

/// An album with a live link changed (photos added or removed, renamed): the
/// link follows it. New files go up, the manifest is written again; the link
/// keeps working with the old contents meanwhile.
pub async fn album_changed(app: &AppState, album: i64) -> Result<()> {
    let c = app.pool.get().await?;
    let Some(row) = c
        .query_opt(
            "SELECT s.id, a.title FROM shares s JOIN albums a ON a.id = s.album_id
             WHERE s.album_id = $1 AND s.expires_at > now() ORDER BY s.created_at DESC LIMIT 1",
            &[&album],
        )
        .await?
    else {
        return Ok(());
    };
    let (id, title): (String, String) = (row.get(0), row.get(1));
    let assets: Vec<String> = c
        .query(
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
        .collect();
    if assets.is_empty() {
        // nothing left to show: the link goes
        c.execute("DELETE FROM shares WHERE id = $1", &[&id]).await?;
        if let Some(remote) = Remote::new(app) {
            let _ = remote.delete(&id).await;
        }
        return Ok(());
    }
    c.execute(
        "UPDATE shares SET asset_ids = $2, title = $3, state = 'uploading', error = NULL WHERE id = $1",
        &[&id, &assets, &title],
    )
    .await?;
    spawn_upload(app.clone(), id);
    Ok(())
}

/// The album is being deleted: its link ends with it.
pub async fn album_removed(app: &AppState, album: i64) -> Result<()> {
    let c = app.pool.get().await?;
    let ids: Vec<String> =
        c.query("DELETE FROM shares WHERE album_id = $1 RETURNING id", &[&album]).await?.iter().map(|r| r.get(0)).collect();
    if let Some(remote) = Remote::new(app) {
        for id in ids {
            if let Err(e) = remote.delete(&id).await {
                tracing::warn!("share {id}: removing its files failed, the Worker's cron will: {e:#}");
            }
        }
    }
    Ok(())
}

/// Assets left the library's view (archived, locked, trashed, deleted): they
/// leave every link that shows them, at once.
pub async fn assets_hidden(app: &AppState, ids: &[String]) -> Result<()> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            "SELECT id, album_id FROM shares WHERE asset_ids && $1 AND expires_at > now()",
            &[&ids],
        )
        .await?;
    for r in rows {
        let (id, album): (String, Option<i64>) = (r.get(0), r.get(1));
        if let Some(album) = album {
            album_changed(app, album).await?;
            continue;
        }
        let left = c
            .query_one(
                "UPDATE shares SET asset_ids = array(SELECT x FROM unnest(asset_ids) x WHERE x <> ALL($2)),
                                   state = 'uploading', error = NULL
                 WHERE id = $1 RETURNING cardinality(asset_ids)",
                &[&id, &ids],
            )
            .await?
            .get::<_, i32>(0);
        if left == 0 {
            c.execute("DELETE FROM shares WHERE id = $1", &[&id]).await?;
            if let Some(remote) = Remote::new(app) {
                let _ = remote.delete(&id).await;
            }
        } else {
            spawn_upload(app.clone(), id);
        }
    }
    Ok(())
}

/// One file of a share.
struct File {
    kind: &'static str,
    asset: String,
    source: Source,
    mime: String,
}

enum Source {
    Path(PathBuf),
    /// A video whose H.264 view is made first.
    Transcode { original: PathBuf, duration: Option<f64> },
}

struct Item {
    json: Value,
    files: Vec<File>,
}

async fn upload(app: &AppState, id: &str) -> Result<()> {
    let remote = Remote::new(app).context("sharing is not set up")?;
    let c = app.pool.get().await?;
    let share = c
        .query_opt(
            "SELECT title, asset_ids, allow_download, password, extract(epoch FROM expires_at)::bigint, live
             FROM shares WHERE id = $1",
            &[&id],
        )
        .await?
        .context("share is gone")?;
    let (title, ids, allow_download, password, expires, live): (String, Vec<String>, bool, Option<String>, i64, bool) =
        (share.get(0), share.get(1), share.get(2), share.get(3), share.get(4), share.get(5));
    // a new link says "being created" from its first second, not "not found";
    // a live one keeps showing its current contents while it is updated
    let announce = |done: i64, total: i64, eta: Option<i64>| {
        json!({ "title": title, "count": ids.len(), "done_bytes": done.max(0), "total_bytes": total.max(0),
                "eta_s": eta, "expires_at": expires })
    };
    if !live {
        let first = announce(0, 0, None);
        with_retries(|| remote.progress(id, &first)).await.context("progress")?;
    }
    let rows = c
        .query(
            "SELECT id, type, width, height, taken_at, tz_offset_s, duration_s, orig_path, orig_name, size_bytes
             FROM assets WHERE id = ANY($1)",
            &[&ids],
        )
        .await?;
    drop(c);

    let mut by_id = std::collections::HashMap::new();
    for r in rows {
        let item = prepare(app, &r, allow_download).await?;
        by_id.insert(r.get::<_, String>(0), item);
    }
    // in the order the share was made with; assets deleted since are left out
    let items: Vec<Item> = ids.iter().filter_map(|a| by_id.remove(a)).collect();
    if items.is_empty() {
        bail!("none of these photos exist any more");
    }

    let total: i64 = items.iter().flat_map(|i| &i.files).map(|f| estimate(&f.source) as i64).sum();
    let done = Arc::new(AtomicI64::new(0));
    set_progress(app, id, 0, total).await?;

    let manifest_items: Vec<Value> = items.iter().map(|i| i.json.clone()).collect();
    let files: Vec<File> = items.into_iter().flat_map(|i| i.files).collect();
    let total = Arc::new(AtomicI64::new(total));
    // the bytes sent so far reach the database once a second, so the app sees
    // the progress move part by part, not file by file
    let reporting = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let progress_base = announce(0, 0, None);
    tokio::spawn({
        let (app, id, done, total, reporting) = (app.clone(), id.to_string(), done.clone(), total.clone(), reporting.clone());
        async move {
            let mut speed = Speed::default();
            let mut tick = 0u32;
            while reporting.load(Ordering::Relaxed) {
                tokio::time::sleep(Duration::from_secs(1)).await;
                let (d, t) = (done.load(Ordering::Relaxed), total.load(Ordering::Relaxed));
                let _ = set_progress(&app, &id, d, t).await;
                let eta = speed.eta(d, t);
                tick += 1;
                // the recipient's page: every 5 s is plenty, and cheap
                if !live && tick % 5 == 0
                    && let Some(remote) = Remote::new(&app)
                {
                    let mut body = progress_base.clone();
                    body["done_bytes"] = json!(d.max(0));
                    body["total_bytes"] = json!(t.max(d).max(0));
                    body["eta_s"] = json!(eta);
                    let _ = remote.progress(&id, &body).await;
                }
            }
        }
    });
    let sent = stream::iter(files.into_iter().map(Ok::<_, anyhow::Error>))
        .try_for_each_concurrent(PARALLEL, |file| {
            let (remote, done, total) = (&remote, done.clone(), total.clone());
            async move {
                if !still_wanted(app, id).await? {
                    bail!("stopped");
                }
                let estimated = estimate(&file.source) as i64;
                let path = materialize(app, &file).await?;
                let size = tokio::fs::metadata(&path).await?.len();
                total.fetch_add(size as i64 - estimated, Ordering::Relaxed);
                // what this file has added to `done`; a retry starts it over
                let credited = AtomicI64::new(0);
                let report = |n: u64| {
                    credited.fetch_add(n as i64, Ordering::Relaxed);
                    done.fetch_add(n as i64, Ordering::Relaxed);
                };
                let result = with_retries(|| {
                    done.fetch_sub(credited.swap(0, Ordering::Relaxed), Ordering::Relaxed);
                    remote.put_file(id, file.kind, &file.asset, &path, &file.mime, size, &report)
                })
                .await;
                if matches!(file.source, Source::Transcode { .. }) {
                    let _ = tokio::fs::remove_file(&path).await;
                }
                result.with_context(|| format!("{} of {}", file.kind, &file.asset[..12]))?;
                done.fetch_add(size as i64 - credited.load(Ordering::Relaxed), Ordering::Relaxed);
                Ok(())
            }
        })
        .await;
    reporting.store(false, Ordering::Relaxed);
    sent?;
    set_progress(app, id, done.load(Ordering::Relaxed), total.load(Ordering::Relaxed)).await?;

    if !still_wanted(app, id).await? {
        return Ok(());
    }
    let manifest = json!({
        "title": title,
        "expires_at": expires,
        "allow_download": allow_download,
        "password": password,
        "items": manifest_items,
    });
    with_retries(|| remote.manifest(id, &manifest)).await.context("manifest")?;
    let c = app.pool.get().await?;
    c.execute("UPDATE shares SET state = 'ready', live = true, error = NULL WHERE id = $1", &[&id]).await?;
    tracing::info!("share {id}: live, {} items", manifest_items.len());
    Ok(())
}

/// The manifest entry and the files of one asset.
async fn prepare(app: &App, r: &tokio_postgres::Row, allow_download: bool) -> Result<Item> {
    let id: String = r.get(0);
    let kind: String = r.get(1);
    let taken: Option<DateTime<Utc>> = r.get(4);
    let offset: Option<i32> = r.get(5);
    let duration: Option<f64> = r.get(6);
    let original = util::confine(&app.cfg.photos_dir, Path::new(&r.get::<_, String>(7)))
        .await
        .with_context(|| format!("original of {} is missing", &id[..12]))?;
    let name: String = r.get::<_, Option<String>>(8).unwrap_or_else(|| id[..12].to_string());
    let bytes: i64 = r.get::<_, Option<i64>>(9).unwrap_or(0);
    // wall time where it was taken, which is what the page shows
    let wall = taken.map(|t| match offset {
        Some(o) => t.timestamp() + i64::from(o),
        None => t.with_timezone(&app.cfg.tz).naive_local().and_utc().timestamp(),
    });

    let thumb = |size| app.cfg.thumb_path(&id, size);
    let mut files = vec![File { kind: "t", asset: id.clone(), source: Source::Path(thumb(512)), mime: "image/webp".into() }];
    let is_video = kind == "video";
    if is_video {
        let probe = {
            let original = original.clone();
            tokio::task::spawn_blocking(move || video::probe(&original)).await??
        };
        let source = if browser_plays(&probe) {
            Source::Path(original.clone())
        } else {
            Source::Transcode { original: original.clone(), duration }
        };
        files.push(File { kind: "v", asset: id.clone(), source, mime: "video/mp4".into() });
    } else {
        files.push(File { kind: "v", asset: id.clone(), source: Source::Path(thumb(2048)), mime: "image/webp".into() });
    }
    // the original's CRC-32 lets the Worker build "Download all" without
    // reading a byte of it (its CPU budget is tiny)
    let crc = if allow_download {
        files.push(File { kind: "o", asset: id.clone(), source: Source::Path(original.clone()), mime: mime_of(&name).into() });
        let original = original.clone();
        Some(tokio::task::spawn_blocking(move || crc32_of(&original)).await??)
    } else {
        None
    };
    let mut json = json!({
        "id": id,
        "kind": if is_video { "video" } else { "photo" },
        "w": r.get::<_, Option<i32>>(2).unwrap_or(0),
        "h": r.get::<_, Option<i32>>(3).unwrap_or(0),
        "taken": wall,
        "duration": duration,
        "name": name,
        "bytes": bytes,
        "view": if is_video { "video/mp4" } else { "image/webp" },
    });
    if let Some(crc) = crc {
        json["crc32"] = json!(crc);
    }
    Ok(Item { json, files })
}

fn crc32_of(path: &Path) -> Result<u32> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = crc32fast::Hasher::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = std::io::Read::read(&mut file, &mut buf)?;
        if n == 0 {
            return Ok(hasher.finalize());
        }
        hasher.update(&buf[..n]);
    }
}

/// H.264 in MP4/MOV, 8 bit, at most 1080p and a sane bitrate plays in every
/// browser as it is.
fn browser_plays(p: &video::Probe) -> bool {
    p.codec == "h264"
        && !p.pixel_format.contains("10")
        && p.coded_width.min(p.coded_height) <= 1080
        && p.bitrate.is_none_or(|b| b <= 12_000_000)
        && (p.container.contains("mp4") || p.container.contains("mov"))
}

/// Bytes a file will have; for a video still to be made, about 6 Mbit/s.
fn estimate(source: &Source) -> u64 {
    match source {
        Source::Path(p) => std::fs::metadata(p).map(|m| m.len()).unwrap_or(0),
        Source::Transcode { original, duration } => {
            let size = std::fs::metadata(original).map(|m| m.len()).unwrap_or(0);
            duration.map(|d| ((d * 750_000.0) as u64).min(size.max(1))).unwrap_or(size)
        }
    }
}

/// The file on disk, making the H.264 view first where needed.
async fn materialize(app: &App, file: &File) -> Result<PathBuf> {
    match &file.source {
        Source::Path(p) => {
            if !p.is_file() {
                bail!("{} is missing", p.display());
            }
            Ok(p.clone())
        }
        Source::Transcode { original, .. } => {
            let dest = app.cfg.previews_dir.join("share").join(format!("{}.mp4", file.asset));
            let (source, out) = (original.clone(), dest.clone());
            tokio::task::spawn_blocking(move || transcode_h264(&source, &out)).await??;
            Ok(dest)
        }
    }
}

/// A 1080p H.264 rendition for browsers, which mostly cannot play HEVC. GPU
/// first, then software, as for the app's own previews.
fn transcode_h264(source: &Path, dest: &Path) -> Result<()> {
    if dest.is_file() {
        return Ok(());
    }
    let probe = video::probe(source)?;
    let (w, h) = preview::target_size(&probe);
    std::fs::create_dir_all(dest.parent().context("no parent directory")?)?;
    let tmp = dest.with_extension("part.mp4");
    let nvenc = ["-c:v", "h264_nvenc", "-preset", "p5", "-rc", "vbr", "-cq", "24", "-b:v", "0", "-maxrate", "8M", "-bufsize", "16M"];
    let gpu_scale = format!("scale_cuda={w}:{h}:format=nv12");
    let cpu_scale = format!("scale={w}:{h}:flags=bicubic,format=yuv420p");
    let attempts: [(&[&str], &str, &[&str]); 3] = [
        (&["-hwaccel", "cuda", "-hwaccel_output_format", "cuda"], &gpu_scale, &nvenc),
        (&[], &cpu_scale, &nvenc),
        (&[], &cpu_scale, &["-c:v", "libx264", "-preset", "veryfast", "-crf", "23"]),
    ];
    let mut last_error = String::new();
    for (decode, filter, encode) in attempts {
        let output = std::process::Command::new("ffmpeg")
            .args(["-v", "error", "-y", "-noautorotate"])
            .args(decode)
            .arg("-i")
            .arg(source)
            .args(["-map", "0:v:0", "-map", "0:a:0?", "-vf", filter])
            .args(encode)
            .args(["-profile:v", "high", "-c:a", "aac", "-b:a", "160k", "-ac", "2"])
            // no location or camera data in what leaves the house
            .args(["-map_metadata", "-1", "-movflags", "+faststart"])
            .arg(&tmp)
            .output()
            .context("ffmpeg is not installed")?;
        if output.status.success() && std::fs::metadata(&tmp).is_ok_and(|m| m.len() > 0) {
            std::fs::rename(&tmp, dest)?;
            return Ok(());
        }
        last_error = String::from_utf8_lossy(&output.stderr).lines().last().unwrap_or("").to_string();
        let _ = std::fs::remove_file(&tmp);
    }
    bail!("every encoder failed; last: {last_error}")
}

fn mime_of(name: &str) -> &'static str {
    match name.rsplit('.').next().map(str::to_ascii_lowercase).as_deref() {
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("png") => "image/png",
        Some("heic" | "heif") => "image/heic",
        Some("webp") => "image/webp",
        Some("gif") => "image/gif",
        Some("dng") => "image/x-adobe-dng",
        Some("mov") => "video/quicktime",
        Some("mp4" | "m4v") => "video/mp4",
        _ => "application/octet-stream",
    }
}

async fn still_wanted(app: &App, id: &str) -> Result<bool> {
    let c = app.pool.get().await?;
    Ok(c.query_opt("SELECT 1 FROM shares WHERE id = $1 AND expires_at > now()", &[&id]).await?.is_some())
}

async fn set_progress(app: &App, id: &str, done: i64, total: i64) -> Result<()> {
    let c = app.pool.get().await?;
    c.execute("UPDATE shares SET done_bytes = $2, total_bytes = $3 WHERE id = $1", &[&id, &done, &total.max(done)])
        .await?;
    Ok(())
}

/// Three tries with a growing pause: a home uplink drops now and then.
async fn with_retries<T, F, Fut>(mut op: F) -> Result<T>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    let mut attempt = 0;
    loop {
        match op().await {
            Ok(v) => return Ok(v),
            Err(e) if attempt < 2 => {
                attempt += 1;
                tracing::debug!("share upload retry {attempt}: {e:#}");
                tokio::time::sleep(Duration::from_secs(3 * attempt)).await;
            }
            Err(e) => return Err(e),
        }
    }
}

// MARK: - Expiry

/// Removes shares whose links expired, from R2 and from here. Run hourly; a
/// share whose files could not be removed (Worker unreachable) is tried again
/// next time.
pub async fn purge_expired(app: &App) -> ApiResult<u64> {
    reconcile(app).await;
    let c = app.pool.get().await?;
    let rows = c.query("SELECT id FROM shares WHERE expires_at <= now()", &[]).await?;
    let mut removed = 0;
    for r in rows {
        let id: String = r.get(0);
        if let Some(remote) = Remote::new(app)
            && let Err(e) = remote.delete(&id).await
        {
            tracing::warn!("share {id}: expired, removing its files failed: {e:#}");
            continue;
        }
        removed += c.execute("DELETE FROM shares WHERE id = $1", &[&id]).await?;
    }
    Ok(removed)
}

/// Anything in R2 that atlas does not know as a share (a stop whose remote
/// delete failed, a database restored from backup, a crash at the wrong
/// moment) is deleted, so no stray link survives.
async fn reconcile(app: &App) {
    let Some(remote) = Remote::new(app) else { return };
    let stored = match remote.ids().await {
        Ok(ids) => ids,
        Err(e) => {
            tracing::warn!("share: could not list atlas-share to reconcile: {e:#}");
            return;
        }
    };
    let Ok(c) = app.pool.get().await else { return };
    let Ok(rows) = c.query("SELECT id FROM shares", &[]).await else { return };
    let known: std::collections::HashSet<String> = rows.iter().map(|r| r.get(0)).collect();
    for id in stored.into_iter().filter(|id| !known.contains(id)) {
        match remote.delete(&id).await {
            Ok(()) => tracing::info!("share {id}: removed from atlas-share, atlas no longer knew it"),
            Err(e) => tracing::warn!("share {id}: stray, removing it failed: {e:#}"),
        }
    }
}

/// Upload speed, smoothed, for the time left the recipient's page shows.
#[derive(Default)]
struct Speed {
    last: Option<(std::time::Instant, i64)>,
    bytes_per_s: f64,
}

impl Speed {
    fn eta(&mut self, done: i64, total: i64) -> Option<i64> {
        let now = std::time::Instant::now();
        if let Some((then, before)) = self.last {
            let dt = now.duration_since(then).as_secs_f64();
            if dt > 0.0 {
                let rate = (done - before).max(0) as f64 / dt;
                // a slow average: parts land in bursts of 16 MiB
                self.bytes_per_s = if self.bytes_per_s == 0.0 { rate } else { 0.9 * self.bytes_per_s + 0.1 * rate };
            }
        }
        self.last = Some((now, done));
        (self.bytes_per_s > 1024.0 && total > done).then(|| ((total - done) as f64 / self.bytes_per_s).ceil() as i64)
    }
}

// MARK: - The Worker's admin API

struct Remote {
    http: reqwest::Client,
    base: String,
    token: String,
}

impl Remote {
    fn new(app: &App) -> Option<Self> {
        Some(Self {
            http: reqwest::Client::builder().timeout(Duration::from_secs(600)).build().ok()?,
            base: app.cfg.share_url.clone()?,
            token: app.cfg.share_token.clone()?,
        })
    }

    fn file_url(&self, id: &str, kind: &str, asset: &str) -> String {
        format!("{}/api/shares/{id}/files/{kind}/{asset}", self.base)
    }

    async fn send(&self, req: reqwest::RequestBuilder) -> Result<reqwest::Response> {
        let res = req.bearer_auth(&self.token).send().await?;
        if !res.status().is_success() {
            let status = res.status();
            let body = res.text().await.unwrap_or_default();
            return Err(anyhow!("atlas-share answered {status}: {}", body.chars().take(200).collect::<String>()));
        }
        Ok(res)
    }

    /// Stores one file, skipping one already there at the same size.
    /// `sent` hears the bytes of every part as it lands.
    #[allow(clippy::too_many_arguments)]
    async fn put_file(
        &self,
        id: &str,
        kind: &str,
        asset: &str,
        path: &Path,
        mime: &str,
        size: u64,
        sent: &(dyn Fn(u64) + Sync),
    ) -> Result<()> {
        let url = self.file_url(id, kind, asset);
        let head = self.http.head(&url).bearer_auth(&self.token).send().await?;
        if head.status().is_success() && head.content_length() == Some(size) {
            return Ok(());
        }
        if size <= SINGLE_MAX {
            let body = tokio::fs::read(path).await?;
            self.send(self.http.put(&url).header("content-type", mime).body(body)).await?;
            return Ok(());
        }
        #[derive(Deserialize)]
        struct Started {
            upload_id: String,
        }
        #[derive(Deserialize)]
        struct Part {
            etag: String,
        }
        let started: Started =
            self.send(self.http.post(format!("{url}?uploads")).header("content-type", mime)).await?.json().await?;
        let mut file = tokio::fs::File::open(path).await?;
        let mut parts = Vec::new();
        let mut buf = vec![0u8; PART];
        for n in 1.. {
            let read = read_full(&mut file, &mut buf).await?;
            if read == 0 {
                break;
            }
            let chunk = buf[..read].to_vec();
            let part_url = format!("{url}?upload_id={}&part={n}", started.upload_id);
            let part: Part = with_retries(|| async {
                Ok(self.send(self.http.put(&part_url).body(chunk.clone())).await?.json().await?)
            })
            .await?;
            parts.push(json!({ "part": n, "etag": part.etag }));
            sent(read as u64);
            if read < PART {
                break;
            }
        }
        self.send(
            self.http
                .post(format!("{url}?upload_id={}&complete", started.upload_id))
                .json(&json!({ "parts": parts })),
        )
        .await?;
        Ok(())
    }

    async fn progress(&self, id: &str, body: &Value) -> Result<()> {
        self.send(self.http.put(format!("{}/api/shares/{id}/progress", self.base)).json(body)).await?;
        Ok(())
    }

    /// Every share id atlas-share holds files for.
    async fn ids(&self) -> Result<Vec<String>> {
        #[derive(Deserialize)]
        struct Ids {
            ids: Vec<String>,
        }
        Ok(self.send(self.http.get(format!("{}/api/shares", self.base))).await?.json::<Ids>().await?.ids)
    }

    async fn manifest(&self, id: &str, manifest: &Value) -> Result<()> {
        self.send(self.http.put(format!("{}/api/shares/{id}", self.base)).json(manifest)).await?;
        Ok(())
    }

    async fn delete(&self, id: &str) -> Result<()> {
        self.send(self.http.delete(format!("{}/api/shares/{id}", self.base))).await?;
        Ok(())
    }
}

/// Fills `buf` unless the file ends first; returns the bytes read.
async fn read_full(file: &mut tokio::fs::File, buf: &mut [u8]) -> Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        let n = file.read(&mut buf[filled..]).await?;
        if n == 0 {
            break;
        }
        filled += n;
    }
    Ok(filled)
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

    #[test]
    fn browsers_get_h264_up_to_1080p_as_is() {
        let p = |codec: &str, w, h, pix: &str| video::Probe {
            codec: codec.into(),
            coded_width: w,
            coded_height: h,
            pixel_format: pix.into(),
            bitrate: Some(8_000_000),
            container: "mov,mp4,m4a,3gp,3g2,mj2".into(),
            ..video::Probe::default()
        };
        assert!(browser_plays(&p("h264", 1920, 1080, "yuv420p")));
        assert!(!browser_plays(&p("hevc", 1920, 1080, "yuv420p")));
        assert!(!browser_plays(&p("h264", 3840, 2160, "yuv420p")));
        assert!(!browser_plays(&p("h264", 1920, 1080, "yuv420p10le")));
    }

    #[test]
    fn time_left_follows_the_speed() {
        let mut s = Speed::default();
        assert_eq!(s.eta(0, 1000), None);
        s.last = Some((std::time::Instant::now() - Duration::from_secs(10), 0));
        // 10 MB in 10 s = 1 MB/s, 90 MB left
        let eta = s.eta(10_000_000, 100_000_000).unwrap();
        assert!((89..=91).contains(&eta), "{eta}");
        assert_eq!(s.eta(100_000_000, 100_000_000), None);
    }

    #[test]
    fn original_types() {
        assert_eq!(mime_of("IMG_1.HEIC"), "image/heic");
        assert_eq!(mime_of("clip.mov"), "video/quicktime");
        assert_eq!(mime_of("noext"), "application/octet-stream");
    }
}
