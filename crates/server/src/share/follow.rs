//! Links follow the library: an album's link changes with the album, and
//! what leaves the library's view leaves every link. Expired links go, and
//! nothing stays in R2 that atlas does not know as a share.

use anyhow::Result;

use super::{Remote, album_assets, spawn_upload};
use crate::{ApiResult, App, AppState};

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
    let assets = album_assets(&c, album).await?;
    if assets.is_empty() {
        // nothing left to show: the link goes
        return end(app, &c, &id).await;
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
    let ids: Vec<String> = c
        .query(
            "DELETE FROM shares WHERE album_id = $1 RETURNING id",
            &[&album],
        )
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    if let Some(remote) = Remote::new(app) {
        for id in ids {
            if let Err(e) = remote.delete(&id).await {
                tracing::warn!(
                    "share {id}: removing its files failed, the Worker's cron will: {e:#}"
                );
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
            end(app, &c, &id).await?;
        } else {
            spawn_upload(app.clone(), id);
        }
    }
    Ok(())
}

/// A link with nothing left to show: its row goes, then its files.
async fn end(app: &App, c: &deadpool_postgres::Object, id: &str) -> Result<()> {
    c.execute("DELETE FROM shares WHERE id = $1", &[&id])
        .await?;
    if let Some(remote) = Remote::new(app) {
        let _ = remote.delete(id).await;
    }
    Ok(())
}

// MARK: - Expiry

/// Removes shares whose links expired, from R2 and from here. Run hourly; a
/// share whose files could not be removed (Worker unreachable) is tried again
/// next time.
pub async fn purge_expired(app: &App) -> ApiResult<u64> {
    reconcile(app).await;
    let c = app.pool.get().await?;
    let rows = c
        .query("SELECT id FROM shares WHERE expires_at <= now()", &[])
        .await?;
    let mut removed = 0;
    for r in rows {
        let id: String = r.get(0);
        if let Some(remote) = Remote::new(app)
            && let Err(e) = remote.delete(&id).await
        {
            tracing::warn!("share {id}: expired, removing its files failed: {e:#}");
            continue;
        }
        removed += c
            .execute("DELETE FROM shares WHERE id = $1", &[&id])
            .await?;
    }
    Ok(removed)
}

/// Anything in R2 that atlas does not know as a share (a stop whose remote
/// delete failed, a database restored from backup, a crash at the wrong
/// moment) is deleted, so no stray link survives.
async fn reconcile(app: &App) {
    let Some(remote) = Remote::new(app) else {
        return;
    };
    let stored = match remote.ids().await {
        Ok(ids) => ids,
        Err(e) => {
            tracing::warn!("share: could not list atlas-share to reconcile: {e:#}");
            return;
        }
    };
    let Ok(c) = app.pool.get().await else { return };
    let Ok(rows) = c.query("SELECT id FROM shares", &[]).await else {
        return;
    };
    let known: std::collections::HashSet<String> = rows.iter().map(|r| r.get(0)).collect();
    for id in stored.into_iter().filter(|id| !known.contains(id)) {
        match remote.delete(&id).await {
            Ok(()) => {
                tracing::info!("share {id}: removed from atlas-share, atlas no longer knew it")
            }
            Err(e) => tracing::warn!("share {id}: stray, removing it failed: {e:#}"),
        }
    }
}
