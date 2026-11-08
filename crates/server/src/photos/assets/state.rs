//! Where an asset lives: favorite, archived, locked, trashed, restored, or
//! gone for good with every file derived from it.

use axum::Json;
use axum::extract::State;
use serde_json::{Value, json};

use crate::photos::{Ids, IdsValue};
use crate::{ApiResult, App, AppState, util};

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
    let c = app.pool.get().await?;
    let n = c
        .execute(
            "UPDATE assets SET trashed_at = now() WHERE id = ANY($1)",
            &[&b.ids],
        )
        .await?;
    hidden(&app, &b.ids).await;
    Ok(Json(json!({ "updated": n })))
}

/// Back into the timeline from wherever it was: trash, archive or locked.
pub async fn restore(State(app): State<AppState>, Json(b): Json<Ids>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let n = c
        .execute(
            "UPDATE assets SET archived = false, trashed_at = NULL, locked = false WHERE id = ANY($1)",
            &[&b.ids],
        )
        .await?;
    Ok(Json(json!({ "updated": n })))
}

pub async fn delete(State(app): State<AppState>, Json(b): Json<Ids>) -> ApiResult<Json<Value>> {
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
