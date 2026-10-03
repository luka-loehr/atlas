//! Thumbnails: the 512 and 2048 WebP of every asset, its dimensions and its
//! placeholder hash.

use anyhow::{Context, Result};

use super::video;
use crate::{AppState, imaging, util};

pub async fn run(app: &AppState, id: &str) -> Result<()> {
    let c = app.pool.get().await?;
    let row = c
        .query_opt("SELECT orig_path, type, width, height, thumbhash IS NOT NULL FROM assets WHERE id = $1", &[&id])
        .await?
        .context("asset is gone")?;
    let original: String = row.get(0);
    let is_video = row.get::<_, &str>(1) == "video";
    let dimensions_known = row.get::<_, Option<i32>>(2).is_some() && row.get::<_, Option<i32>>(3).is_some();
    let has_hash: bool = row.get(4);
    drop(c);

    let grid = app.cfg.thumb_path(id, imaging::GRID);
    let screen = app.cfg.thumb_path(id, imaging::SCREEN);
    let on_disk = tokio::fs::try_exists(&grid).await.unwrap_or(false) && tokio::fs::try_exists(&screen).await.unwrap_or(false);

    if on_disk && dimensions_known {
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
        return Ok(());
    }

    let path = util::confine(&app.cfg.photos_dir, std::path::Path::new(&original))
        .await
        .with_context(|| format!("original missing: {original}"))?;
    let (thumbs, duration) = tokio::task::spawn_blocking(move || -> Result<_> {
        if is_video {
            let decoded = imaging::decode_bytes(&video::poster(&path)?)?;
            let duration = video::probe(&path).ok().and_then(|p| p.duration);
            Ok((imaging::write_thumbs(&decoded, &grid, &screen)?, duration))
        } else {
            let decoded = imaging::decode(&path)?;
            Ok((imaging::write_thumbs(&decoded, &grid, &screen)?, None))
        }
    })
    .await??;

    let c = app.pool.get().await?;
    c.execute(
        "UPDATE assets
            SET width = COALESCE(width, $2), height = COALESCE(height, $3),
                duration_s = COALESCE(duration_s, $4), thumbhash = $5
          WHERE id = $1",
        &[&id, &(thumbs.width as i32), &(thumbs.height as i32), &duration, &thumbs.thumbhash],
    )
    .await?;
    Ok(())
}
