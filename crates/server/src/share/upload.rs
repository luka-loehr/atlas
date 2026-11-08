//! Uploading a share: its files to R2 (several side by side, resumable,
//! progress reported as it goes), then the link preview, then the manifest,
//! which makes the link live.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use futures_util::{TryStreamExt, stream};
use serde_json::{Value, json};

use super::{Remote, card, media};
use crate::jobs::video;
use crate::photos::local_seconds;
use crate::{App, AppState, util};

/// Files uploaded side by side.
const PARALLEL: usize = 4;

/// Uploads every share still `uploading` (after a restart, they resume where
/// they stopped: files already in R2 are skipped).
pub async fn resume(app: AppState) {
    let Ok(c) = app.pool.get().await else { return };
    let Ok(rows) = c
        .query(
            "SELECT id FROM shares WHERE state = 'uploading' AND expires_at > now()",
            &[],
        )
        .await
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
pub(super) fn spawn_upload(app: AppState, id: String) {
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
    let Err(e) = upload(app, id).await else {
        return;
    };
    tracing::warn!("share {id}: {e:#}");
    let message = format!("{e:#}")
        .lines()
        .next()
        .unwrap_or("upload failed")
        .chars()
        .take(300)
        .collect::<String>();
    if let Ok(c) = app.pool.get().await {
        let _ = c
            .execute("UPDATE shares SET state = 'failed', error = $2 WHERE id = $1 AND state = 'uploading'", &[&id, &message])
            .await;
    }
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
    Transcode {
        original: PathBuf,
        duration: Option<f64>,
    },
    /// A video browsers play as it is: copied into a fresh MP4 without its
    /// metadata, since the original's carries where it was taken.
    Remux {
        original: PathBuf,
    },
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
    let (title, ids, allow_download, password, expires, live): (
        String,
        Vec<String>,
        bool,
        Option<String>,
        i64,
        bool,
    ) = (
        share.get(0),
        share.get(1),
        share.get(2),
        share.get(3),
        share.get(4),
        share.get(5),
    );
    // a new link says "being created" from its first second, not "not found";
    // a live one keeps showing its current contents while it is updated
    let announce = |done: i64, total: i64, eta: Option<i64>| {
        json!({ "title": title, "count": ids.len(), "done_bytes": done.max(0), "total_bytes": total.max(0),
                "eta_s": eta, "expires_at": expires })
    };
    if !live {
        let first = announce(0, 0, None);
        with_retries(|| remote.progress(id, &first))
            .await
            .context("progress")?;
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

    let total: i64 = items
        .iter()
        .flat_map(|i| &i.files)
        .map(|f| estimate(&f.source) as i64)
        .sum();
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
        let (app, id, done, total, reporting) = (
            app.clone(),
            id.to_string(),
            done.clone(),
            total.clone(),
            reporting.clone(),
        );
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
                if !live
                    && tick.is_multiple_of(5)
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
                if matches!(file.source, Source::Transcode { .. } | Source::Remux { .. }) {
                    let _ = tokio::fs::remove_file(&path).await;
                }
                result.with_context(|| format!("{} of {}", file.kind, &file.asset[..12]))?;
                done.fetch_add(
                    size as i64 - credited.load(Ordering::Relaxed),
                    Ordering::Relaxed,
                );
                Ok(())
            }
        })
        .await;
    reporting.store(false, Ordering::Relaxed);
    sent?;
    set_progress(
        app,
        id,
        done.load(Ordering::Relaxed),
        total.load(Ordering::Relaxed),
    )
    .await?;

    if !still_wanted(app, id).await? {
        return Ok(());
    }
    let card = card::preview(app, &title, &manifest_items, password.is_some())
        .await
        .context("preview")?;
    let stored = with_retries(|| remote.preview(id, &card))
        .await
        .context("preview")?;
    let mut manifest = json!({
        "title": title,
        "expires_at": expires,
        "allow_download": allow_download,
        "password": password,
        "items": manifest_items,
    });
    if stored {
        // its version: the page's og:image URL changes with the card
        manifest["og"] = json!(&util::sha256_hex(&card)[..16]);
    }
    with_retries(|| remote.manifest(id, &manifest))
        .await
        .context("manifest")?;
    let c = app.pool.get().await?;
    c.execute(
        "UPDATE shares SET state = 'ready', live = true, error = NULL WHERE id = $1",
        &[&id],
    )
    .await?;
    tracing::info!("share {id}: live, {} items", manifest_items.len());
    Ok(())
}

/// The manifest entry and the files of one asset.
async fn prepare(app: &App, r: &tokio_postgres::Row, allow_download: bool) -> Result<Item> {
    let id: String = r.get(0);
    let kind: String = r.get(1);
    let taken: Option<chrono::DateTime<chrono::Utc>> = r.get(4);
    let offset: Option<i32> = r.get(5);
    let duration: Option<f64> = r.get(6);
    let original = util::confine(&app.cfg.photos_dir, Path::new(&r.get::<_, String>(7)))
        .await
        .with_context(|| format!("original of {} is missing", &id[..12]))?;
    let name: String = r
        .get::<_, Option<String>>(8)
        .unwrap_or_else(|| id[..12].to_string());
    let bytes: i64 = r.get::<_, Option<i64>>(9).unwrap_or(0);
    // wall time where it was taken, which is what the page shows
    let wall = taken.map(|t| local_seconds(t, offset, app.cfg.tz));

    let thumb = |size| app.cfg.thumb_path(&id, size);
    let mut files = vec![File {
        kind: "t",
        asset: id.clone(),
        source: Source::Path(thumb(512)),
        mime: "image/webp".into(),
    }];
    let is_video = kind == "video";
    if is_video {
        let probe = {
            let original = original.clone();
            tokio::task::spawn_blocking(move || video::probe(&original)).await??
        };
        let source = if media::browser_plays(&probe) {
            Source::Remux {
                original: original.clone(),
            }
        } else {
            Source::Transcode {
                original: original.clone(),
                duration,
            }
        };
        files.push(File {
            kind: "v",
            asset: id.clone(),
            source,
            mime: "video/mp4".into(),
        });
    } else {
        files.push(File {
            kind: "v",
            asset: id.clone(),
            source: Source::Path(thumb(2048)),
            mime: "image/webp".into(),
        });
    }
    // the original's CRC-32 lets the Worker build "Download all" without
    // reading a byte of it (its CPU budget is tiny)
    let crc = if allow_download {
        files.push(File {
            kind: "o",
            asset: id.clone(),
            source: Source::Path(original.clone()),
            mime: media::mime_of(&name).into(),
        });
        let original = original.clone();
        Some(tokio::task::spawn_blocking(move || media::crc32_of(&original)).await??)
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

/// Bytes a file will have; for a video still to be made, about 6 Mbit/s.
fn estimate(source: &Source) -> u64 {
    match source {
        Source::Path(p) | Source::Remux { original: p } => {
            std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)
        }
        Source::Transcode { original, duration } => {
            let size = std::fs::metadata(original).map(|m| m.len()).unwrap_or(0);
            duration
                .map(|d| ((d * 750_000.0) as u64).min(size.max(1)))
                .unwrap_or(size)
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
            let dest = app
                .cfg
                .previews_dir
                .join("share")
                .join(format!("{}.mp4", file.asset));
            let (source, out) = (original.clone(), dest.clone());
            tokio::task::spawn_blocking(move || media::transcode_h264(&source, &out)).await??;
            Ok(dest)
        }
        Source::Remux { original } => {
            let dest = app
                .cfg
                .previews_dir
                .join("share")
                .join(format!("{}.mp4", file.asset));
            let (source, out) = (original.clone(), dest.clone());
            tokio::task::spawn_blocking(move || media::remux_clean(&source, &out)).await??;
            Ok(dest)
        }
    }
}

async fn still_wanted(app: &App, id: &str) -> Result<bool> {
    let c = app.pool.get().await?;
    Ok(c.query_opt(
        "SELECT 1 FROM shares WHERE id = $1 AND expires_at > now()",
        &[&id],
    )
    .await?
    .is_some())
}

async fn set_progress(app: &App, id: &str, done: i64, total: i64) -> Result<()> {
    let c = app.pool.get().await?;
    c.execute(
        "UPDATE shares SET done_bytes = $2, total_bytes = $3 WHERE id = $1",
        &[&id, &done, &total.max(done)],
    )
    .await?;
    Ok(())
}

/// Three tries with a growing pause: a home uplink drops now and then.
pub(super) async fn with_retries<T, F, Fut>(mut op: F) -> Result<T>
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
                self.bytes_per_s = if self.bytes_per_s == 0.0 {
                    rate
                } else {
                    0.9 * self.bytes_per_s + 0.1 * rate
                };
            }
        }
        self.last = Some((now, done));
        (self.bytes_per_s > 1024.0 && total > done)
            .then(|| ((total - done) as f64 / self.bytes_per_s).ceil() as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
