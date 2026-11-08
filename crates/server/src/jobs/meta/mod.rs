//! Metadata: when and where an asset was taken, and with what.
//!
//! Sources, best first: EXIF (photos) or the container's tags (videos), then
//! a date embedded in the filename. Chat apps strip EXIF but keep names like
//! `IMG-20220513-WA0011.jpg`, which is the only date such a file still has.
//! Every column is fill-NULL: a value that is already there (from a Takeout
//! sidecar or the uploading phone) is never overwritten.

use std::path::Path;

use anyhow::{Context, Result};
use atlas_core::queue;
use chrono::{DateTime, NaiveDateTime, Utc};
use serde_json::Value;

use super::{preview, video};
use crate::{AppState, util};

mod exif;
mod time;

use time::{date_from_name, offset_between, resolve_local};

#[derive(Default)]
struct Meta {
    taken: Option<DateTime<Utc>>,
    tz_offset_s: Option<i32>,
    source: Option<&'static str>,
    /// EXIF wall-clock time whose UTC offset the camera did not record
    wall_clock: Option<NaiveDateTime>,
    width: Option<i32>,
    height: Option<i32>,
    duration: Option<f64>,
    camera: Option<String>,
    lat: Option<f64>,
    lon: Option<f64>,
    exif: Option<Value>,
    wants_preview: bool,
}

pub async fn run(app: &AppState, id: &str) -> Result<()> {
    let c = app.pool.get().await?;
    let row = c
        .query_opt("SELECT orig_path, type, orig_name, taken_at FROM assets WHERE id = $1", &[&id])
        .await?
        .context("asset is gone")?;
    let original: String = row.get(0);
    let is_video = row.get::<_, &str>(1) == "video";
    let name: String = row.get::<_, Option<String>>(2).unwrap_or_default();
    let known: Option<DateTime<Utc>> = row.get(3);
    drop(c);

    let path = util::confine(&app.cfg.photos_dir, Path::new(&original))
        .await
        .with_context(|| format!("original missing: {original}"))?;
    let tz = app.cfg.tz;
    let mut meta = tokio::task::spawn_blocking(move || if is_video { video_meta(&path) } else { exif::photo_meta(&path) }).await?;
    if let Some(wall_clock) = meta.wall_clock {
        match known {
            // The instant is already known (a Takeout sidecar, the uploading
            // phone): the camera's wall clock then tells which offset it was
            // taken at, so a photo from a trip shows its local time.
            Some(instant) => meta.tz_offset_s = offset_between(wall_clock, instant),
            None => {
                if let Some((taken, offset)) = resolve_local(wall_clock, tz) {
                    meta.taken = Some(taken);
                    meta.tz_offset_s = Some(offset);
                    meta.source = Some("exif");
                }
            }
        }
    }
    if meta.taken.is_none()
        && known.is_none()
        && let Some((taken, offset)) = date_from_name(&name, tz)
    {
        meta.taken = Some(taken);
        meta.tz_offset_s = Some(offset);
        meta.source = Some("filename");
    }

    let c = app.pool.get().await?;
    c.execute(
        "UPDATE assets
            SET taken_src   = CASE WHEN taken_at IS NULL AND $2::timestamptz IS NOT NULL THEN $4 ELSE taken_src END,
                tz_offset_s = COALESCE(tz_offset_s, $3),
                taken_at    = COALESCE(taken_at, $2),
                width       = COALESCE(width, $5),
                height      = COALESCE(height, $6),
                duration_s  = COALESCE(duration_s, $7),
                camera      = COALESCE(camera, $8),
                lat         = COALESCE(lat, $9),
                lon         = COALESCE(lon, $10),
                exif        = COALESCE(exif, $11)
          WHERE id = $1",
        &[
            &id, &meta.taken, &meta.tz_offset_s, &meta.source, &meta.width, &meta.height, &meta.duration,
            &meta.camera, &meta.lat, &meta.lon, &meta.exif,
        ],
    )
    .await?;

    let located = c.query_one("SELECT lat IS NOT NULL AND lon IS NOT NULL FROM assets WHERE id = $1", &[&id]).await?;
    if located.get::<_, bool>(0) {
        queue::enqueue(&c, queue::GEOCODE, "asset", id, queue::PRIORITY_DEFAULT).await?;
    }
    if meta.wants_preview && app.cfg.video_previews {
        queue::enqueue(&c, queue::PREVIEW, "asset", id, queue::PRIORITY_BACKGROUND).await?;
    }
    Ok(())
}

fn video_meta(path: &Path) -> Meta {
    let Ok(probe) = video::probe(path) else { return Meta::default() };
    Meta {
        taken: probe.created,
        tz_offset_s: probe.tz_offset_s,
        source: probe.created.map(|_| "exif"),
        width: probe.width,
        height: probe.height,
        duration: probe.duration,
        camera: probe.camera.clone(),
        lat: probe.lat,
        lon: probe.lon,
        wants_preview: preview::wanted(&probe),
        ..Meta::default()
    }
}
