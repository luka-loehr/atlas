//! Thumbnails: the 512 and 2048 WebP of every asset, its dimensions and its
//! placeholder hash. The model stages read the 2048 one, so this job queues
//! them once it is there.

use anyhow::{Context, Result};
use atlas_core::queue;

use super::video;
use crate::{AppState, imaging, util};

/// The thumbnail recipe. 2: video posters of HDR clips are tone-mapped;
/// video thumbnails from before are made again.
pub const THUMB_V: i16 = 2;

pub async fn run(app: &AppState, id: &str, priority: i32) -> Result<()> {
    let c = app.pool.get().await?;
    let row = c
        .query_opt(
            "SELECT orig_path, type, width, height, thumbhash IS NOT NULL, thumb_v FROM assets WHERE id = $1",
            &[&id],
        )
        .await?
        .context("asset is gone")?;
    let original: String = row.get(0);
    let is_video = row.get::<_, &str>(1) == "video";
    let dimensions_known = row.get::<_, Option<i32>>(2).is_some() && row.get::<_, Option<i32>>(3).is_some();
    let has_hash: bool = row.get(4);
    let made_by: i16 = row.get(5);
    drop(c);

    let grid = app.cfg.thumb_path(id, imaging::GRID);
    let screen = app.cfg.thumb_path(id, imaging::SCREEN);
    let on_disk = tokio::fs::try_exists(&grid).await.unwrap_or(false) && tokio::fs::try_exists(&screen).await.unwrap_or(false);
    // only the video recipe changed since version 1
    let current = !is_video || made_by >= THUMB_V;

    if on_disk && dimensions_known && current {
        if !has_hash {
            // thumbnails made before placeholders existed: hash the small
            // one instead of decoding the original again
            let hash = tokio::task::spawn_blocking(move || {
                let small = image::open(&grid)?.into_rgb8();
                imaging::thumbhash(&small)
            })
            .await??;
            let c = app.pool.get().await?;
            c.execute("UPDATE assets SET thumbhash = $2 WHERE id = $1", &[&id, &hash]).await?;
        }
        return queue_models(app, id, priority, false).await;
    }

    let path = util::confine(&app.cfg.photos_dir, std::path::Path::new(&original))
        .await
        .with_context(|| format!("original missing: {original}"))?;
    let (thumbs, duration, hdr) = tokio::task::spawn_blocking(move || -> Result<_> {
        if is_video {
            let probe = video::probe(&path).ok();
            let hdr = probe.as_ref().is_some_and(video::Probe::hdr);
            let decoded = imaging::decode_bytes(&video::poster(&path, hdr)?)?;
            let duration = probe.and_then(|p| p.duration);
            Ok((imaging::write_thumbs(&decoded, &grid, &screen)?, duration, hdr))
        } else {
            let decoded = imaging::decode(&path)?;
            Ok((imaging::write_thumbs(&decoded, &grid, &screen)?, None, false))
        }
    })
    .await??;

    let c = app.pool.get().await?;
    c.execute(
        "UPDATE assets
            SET width = COALESCE(width, $2), height = COALESCE(height, $3),
                duration_s = COALESCE(duration_s, $4), thumbhash = $5, thumb_v = $6
          WHERE id = $1",
        &[&id, &(thumbs.width as i32), &(thumbs.height as i32), &duration, &thumbs.thumbhash, &THUMB_V],
    )
    .await?;
    drop(c);
    // an HDR clip embedded before its frames were tone-mapped is embedded again
    queue_models(app, id, priority, on_disk && hdr && made_by < THUMB_V).await
}

/// Embedding and faces, once there is a thumbnail to read: a fresh upload's
/// right behind it, a backlog's at the default.
async fn queue_models(app: &AppState, id: &str, priority: i32, embed_again: bool) -> Result<()> {
    let follow = if priority < queue::PRIORITY_DEFAULT { queue::PRIORITY_INTERACTIVE + 20 } else { queue::PRIORITY_DEFAULT };
    let c = app.pool.get().await?;
    if embed_again {
        queue::requeue(&c, queue::EMBED, "asset", id, queue::PRIORITY_BACKGROUND).await?;
    } else {
        queue::enqueue(&c, queue::EMBED, "asset", id, follow).await?;
    }
    queue::enqueue(&c, queue::FACES, "asset", id, follow).await?;
    Ok(())
}
