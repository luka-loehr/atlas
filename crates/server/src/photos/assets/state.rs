//! Where an asset lives: favorite, archived, locked, trashed, restored, or
//! gone for good with every file derived from it.

use axum::Json;
use axum::extract::State;
use serde_json::{Value, json};

use crate::photos::{Ids, IdsValue};
use crate::{ApiError, ApiResult, App, AppState, util};

const MAX_BATCH_IDS: usize = 5_000;

fn check_batch_len<T>(items: &[T]) -> ApiResult<()> {
    if items.len() > MAX_BATCH_IDS {
        Err(ApiError::BadRequest("at most 5000 items per batch request"))
    } else {
        Ok(())
    }
}

pub async fn favorite(
    State(app): State<AppState>,
    Json(b): Json<IdsValue>,
) -> ApiResult<Json<Value>> {
    set_flag(&app, "favorite", &b).await
}

pub async fn archive(
    State(app): State<AppState>,
    Json(b): Json<IdsValue>,
) -> ApiResult<Json<Value>> {
    let r = set_flag(&app, "archived", &b).await?;
    if b.value {
        hidden(&app, &b.ids).await;
    }
    Ok(r)
}

pub async fn lock(State(app): State<AppState>, Json(b): Json<IdsValue>) -> ApiResult<Json<Value>> {
    let r = set_flag(&app, "locked", &b).await?;
    if b.value {
        hidden(&app, &b.ids).await;
    }
    Ok(r)
}

/// What leaves the library's view leaves every share link too.
async fn hidden(app: &AppState, ids: &[String]) {
    if let Err(e) = crate::share::assets_hidden(app, ids).await {
        tracing::warn!("share links: dropping hidden photos failed: {e:#}");
    }
}

/// `column` is one of three literals above, never client input.
async fn set_flag(app: &App, column: &str, b: &IdsValue) -> ApiResult<Json<Value>> {
    check_batch_len(&b.ids)?;
    let c = app.pool.get().await?;
    let n = c
        .execute(
            &format!("UPDATE assets SET {column} = $2 WHERE id = ANY($1)"),
            &[&b.ids, &b.value],
        )
        .await?;
    Ok(Json(json!({ "updated": n })))
}

pub async fn trash(State(app): State<AppState>, Json(b): Json<Ids>) -> ApiResult<Json<Value>> {
    check_batch_len(&b.ids)?;
    let c = app.pool.get().await?;
    let n = c
        .execute(
            "UPDATE assets SET trashed_at = now() WHERE id = ANY($1)",
            &[&b.ids],
        )
        .await?;
    c.execute(
        "UPDATE objects SET trashed_at = now() WHERE bucket = 'media' AND asset_id = ANY($1)",
        &[&b.ids],
    )
    .await?;
    hidden(&app, &b.ids).await;
    Ok(Json(json!({ "updated": n })))
}

/// Back into the timeline from wherever it was: trash, archive or locked.
pub async fn restore(State(app): State<AppState>, Json(b): Json<Ids>) -> ApiResult<Json<Value>> {
    check_batch_len(&b.ids)?;
    let c = app.pool.get().await?;
    let n = c
        .execute(
            "UPDATE assets SET archived = false, trashed_at = NULL, locked = false WHERE id = ANY($1)",
            &[&b.ids],
        )
        .await?;
    c.execute(
        "UPDATE objects SET trashed_at = NULL WHERE bucket = 'media' AND asset_id = ANY($1)",
        &[&b.ids],
    )
    .await?;
    Ok(Json(json!({ "updated": n })))
}

pub async fn delete(State(app): State<AppState>, Json(b): Json<Ids>) -> ApiResult<Json<Value>> {
    check_batch_len(&b.ids)?;
    Ok(Json(json!({ "deleted": purge(&app, &b.ids).await? })))
}

pub async fn empty_trash(State(app): State<AppState>) -> ApiResult<Json<Value>> {
    let ids: Vec<String> = {
        let c = app.pool.get().await?;
        c.query("SELECT id FROM assets WHERE trashed_at IS NOT NULL", &[])
            .await?
            .iter()
            .map(|r| r.get(0))
            .collect()
    };
    Ok(Json(json!({ "deleted": purge(&app, &ids).await? })))
}

/// How long trashed photos and files are kept before they are removed for good.
pub const TRASH_DAYS: i32 = 30;

/// Remove photos that have been in the trash for longer than [`TRASH_DAYS`].
pub async fn purge_expired(app: &App) -> ApiResult<u64> {
    let ids: Vec<String> = {
        let c = app.pool.get().await?;
        c.query(
            "SELECT id FROM assets WHERE trashed_at < now() - make_interval(days => $1)",
            &[&TRASH_DAYS],
        )
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect()
    };
    purge(app, &ids).await
}

/// Permanent: rows, the original, every derived file. Child rows that carry
/// no foreign key (edges, embeddings, queue rows) are removed by hand: ids
/// are content hashes, so anything left behind would silently re-attach to
/// the same bytes uploaded again, and a stale vector would stay searchable.
async fn purge(app: &App, ids: &[String]) -> ApiResult<u64> {
    if ids.is_empty() {
        return Ok(0);
    }
    let mut c = app.pool.get().await?;
    let originals = c
        .query(
            "SELECT id, orig_path FROM assets WHERE id = ANY($1)",
            &[&ids],
        )
        .await?;
    let faces: Vec<i64> = c
        .query("SELECT id FROM faces WHERE asset_id = ANY($1)", &[&ids])
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();

    let tx = c.transaction().await?;
    for statement in [
        "DELETE FROM edges WHERE src_type = 'asset' AND src_id = ANY($1)",
        "DELETE FROM embeddings WHERE owner_type = 'asset' AND owner_id = ANY($1)",
        "DELETE FROM ingest_jobs WHERE owner_type = 'asset' AND owner_id = ANY($1)",
    ] {
        tx.execute(statement, &[&ids]).await?;
    }
    // faces and album links follow through ON DELETE CASCADE
    let deleted = tx
        .execute("DELETE FROM assets WHERE id = ANY($1)", &[&ids])
        .await?;
    tx.commit().await?;

    // files go after the commit: a failed transaction must not orphan rows
    for row in &originals {
        let id: String = row.get(0);
        let original: String = row.get(1);
        match util::confine(&app.cfg.photos_dir, std::path::Path::new(&original)).await {
            Some(path) => {
                let _ = tokio::fs::remove_file(path).await;
            }
            None => {
                tracing::warn!("purge: {original} is missing or outside the library, left alone")
            }
        }
        for derived in [
            app.cfg.thumb_path(&id, 512),
            app.cfg.thumb_path(&id, 2048),
            app.cfg.preview_path(&id),
        ] {
            let _ = tokio::fs::remove_file(derived).await;
        }
    }
    for face in faces {
        let _ = tokio::fs::remove_file(app.cfg.faces_dir().join(format!("{face}.webp"))).await;
    }
    Ok(deleted)
}

#[derive(serde::Deserialize)]
pub struct RotateBody {
    pub degrees: i32,
}

/// Rotate a photo upright (90, 180, or 270 degrees clockwise; -90 == 270),
/// regenerate both thumbnails + thumbhash, clear stale tile/face crops, and
/// re-queue GPU embedding and face recognition.
pub async fn rotate(
    State(app): State<AppState>,
    axum::extract::Path(id): axum::extract::Path<String>,
    Json(b): Json<RotateBody>,
) -> ApiResult<Json<Value>> {
    if !util::is_content_id(&id) {
        return Err(ApiError::NotFound);
    }
    let deg = b.degrees.rem_euclid(360);
    if !matches!(deg, 90 | 180 | 270) {
        return Err(ApiError::BadRequest("degrees must be 90, 180, 270, or -90"));
    }

    let c = app.pool.get().await?;
    let row = c
        .query_opt(
            "SELECT orig_path, type, size_bytes FROM assets WHERE id = $1",
            &[&id],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    let orig_rel: String = row.get(0);
    let kind: String = row.get(1);
    let old_size: Option<i64> = row.get(2);
    if kind != "photo" {
        return Err(ApiError::BadRequest("only photos can be rotated"));
    }
    let orig_path = util::confine(&app.cfg.photos_dir, std::path::Path::new(&orig_rel))
        .await
        .ok_or(ApiError::NotFound)?;
    drop(c);

    let grid = app.cfg.thumb_path(&id, crate::imaging::GRID);
    let screen = app.cfg.thumb_path(&id, crate::imaging::SCREEN);
    let path_for_block = orig_path.clone();

    let (thumbs, new_size) = tokio::task::spawn_blocking(move || -> anyhow::Result<_> {
        let mut decoded = crate::imaging::decode(&path_for_block)?;
        decoded.rgb = match deg {
            90 => image::imageops::rotate90(&decoded.rgb),
            180 => image::imageops::rotate180(&decoded.rgb),
            270 => image::imageops::rotate270(&decoded.rgb),
            _ => unreachable!(),
        };
        let thumbs = crate::imaging::write_thumbs(&decoded, &grid, &screen)?;

        let ext = path_for_block
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let mut updated_bytes: Option<i64> = None;
        if matches!(ext.as_str(), "jpg" | "jpeg") {
            use image::ImageEncoder;
            let mut out = Vec::new();
            let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 95);
            if let Some(icc) = decoded.icc.clone() {
                let _ = enc.set_icc_profile(icc);
            }
            enc.write_image(
                decoded.rgb.as_raw(),
                decoded.rgb.width(),
                decoded.rgb.height(),
                image::ExtendedColorType::Rgb8,
            )?;
            crate::imaging::write_atomic(&path_for_block, &out)?;
            updated_bytes = Some(out.len() as i64);
        } else if ext == "png" {
            use image::ImageEncoder;
            let mut out = Vec::new();
            let enc = image::codecs::png::PngEncoder::new(&mut out);
            enc.write_image(
                decoded.rgb.as_raw(),
                decoded.rgb.width(),
                decoded.rgb.height(),
                image::ExtendedColorType::Rgb8,
            )?;
            crate::imaging::write_atomic(&path_for_block, &out)?;
            updated_bytes = Some(out.len() as i64);
        } else if ext == "webp" {
            let out = crate::imaging::encode_webp(&decoded.rgb, 92.0, decoded.icc.as_deref());
            crate::imaging::write_atomic(&path_for_block, &out)?;
            updated_bytes = Some(out.len() as i64);
        }
        Ok((thumbs, updated_bytes))
    })
    .await
    .map_err(|e| ApiError::Internal(anyhow::anyhow!("rotate join: {e}")))?
    .map_err(ApiError::Internal)?;

    let _ = tokio::fs::remove_file(app.cfg.tile_path(&id)).await;

    let c = app.pool.get().await?;
    let stale_faces: Vec<i64> = c
        .query("DELETE FROM faces WHERE asset_id = $1 RETURNING id", &[&id])
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    let final_size = new_size.or(old_size);
    c.execute(
        "UPDATE assets
            SET width = $2, height = $3, size_bytes = $4, thumbhash = $5, thumb_v = $6
          WHERE id = $1",
        &[
            &id,
            &(thumbs.width as i32),
            &(thumbs.height as i32),
            &final_size,
            &thumbs.thumbhash,
            &crate::jobs::thumb::THUMB_V,
        ],
    )
    .await?;
    if let Some(sz) = final_size {
        let _ = c
            .execute(
                "UPDATE objects SET size_bytes = $2, updated_at = now() WHERE bucket = 'media' AND asset_id = $1",
                &[&id, &sz],
            )
            .await;
    }
    let _ = atlas_core::queue::requeue(
        &c,
        atlas_core::queue::EMBED,
        "asset",
        &id,
        atlas_core::queue::PRIORITY_INTERACTIVE,
    )
    .await;
    let _ = atlas_core::queue::requeue(
        &c,
        atlas_core::queue::FACES,
        "asset",
        &id,
        atlas_core::queue::PRIORITY_INTERACTIVE,
    )
    .await;
    drop(c);

    for fid in stale_faces {
        let _ = tokio::fs::remove_file(app.cfg.faces_dir().join(format!("{fid}.webp"))).await;
    }

    Ok(Json(json!({
        "id": id,
        "width": thumbs.width,
        "height": thumbs.height,
    })))
}
