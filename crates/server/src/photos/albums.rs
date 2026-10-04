//! Albums: named, ordered-by-date sets of assets.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;
use serde_json::{Value, json};

use super::{COLS, Columns, Ids, VISIBLE};
use crate::{ApiError, ApiResult, AppState, media};

/// Every album with its size and newest visible asset as the cover, the
/// most recently photographed album first.
pub async fn list(State(app): State<AppState>, headers: HeaderMap) -> ApiResult<Response> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!(
                "SELECT a.id, a.title, count(assets.id),
                        (array_agg(assets.id ORDER BY assets.taken_at DESC NULLS LAST))[1],
                        min(assets.taken_at), max(assets.taken_at)
                 FROM albums a
                 LEFT JOIN album_assets aa ON aa.album_id = a.id
                 LEFT JOIN assets ON assets.id = aa.asset_id AND {VISIBLE}
                 GROUP BY a.id
                 ORDER BY max(assets.taken_at) DESC NULLS LAST, lower(a.title)"
            ),
            &[],
        )
        .await?;
    let albums: Vec<Value> = rows
        .iter()
        .map(|r| {
            json!({
                "id": r.get::<_, i64>(0), "title": r.get::<_, String>(1),
                "count": r.get::<_, i64>(2), "cover": r.get::<_, Option<String>>(3),
                "from": r.get::<_, Option<chrono::DateTime<chrono::Utc>>>(4),
                "to": r.get::<_, Option<chrono::DateTime<chrono::Utc>>>(5),
            })
        })
        .collect();
    Ok(media::json_validated(&headers, &json!({ "albums": albums })))
}

#[derive(Deserialize)]
pub struct Title {
    title: String,
}

fn clean_title(raw: &str) -> ApiResult<&str> {
    let title = raw.trim();
    if title.is_empty() || title.chars().count() > 200 {
        return Err(ApiError::BadRequest("album title must be 1 to 200 characters"));
    }
    Ok(title)
}

/// Creating a title that exists returns that album: titles are unique.
pub async fn create(State(app): State<AppState>, Json(b): Json<Title>) -> ApiResult<Json<Value>> {
    let title = clean_title(&b.title)?;
    let c = app.pool.get().await?;
    let row = c
        .query_one(
            "INSERT INTO albums (title) VALUES ($1)
             ON CONFLICT (title) DO UPDATE SET title = EXCLUDED.title RETURNING id",
            &[&title],
        )
        .await?;
    Ok(Json(json!({ "id": row.get::<_, i64>(0), "title": title })))
}

pub async fn assets(State(app): State<AppState>, Path(id): Path<i64>, headers: HeaderMap) -> ApiResult<Response> {
    let c = app.pool.get().await?;
    let album = c.query_opt("SELECT title FROM albums WHERE id = $1", &[&id]).await?.ok_or(ApiError::NotFound)?;
    let rows = c
        .query(
            &format!(
                "SELECT {COLS} FROM assets JOIN album_assets aa ON aa.asset_id = assets.id
                 WHERE aa.album_id = $1 AND {VISIBLE}
                 ORDER BY assets.taken_at DESC NULLS LAST, assets.id"
            ),
            &[&id],
        )
        .await?;
    Ok(media::json_validated(
        &headers,
        &json!({ "id": id, "title": album.get::<_, String>(0), "assets": Columns::from_rows(&rows, app.cfg.tz) }),
    ))
}

pub async fn rename(State(app): State<AppState>, Path(id): Path<i64>, Json(b): Json<Title>) -> ApiResult<Json<Value>> {
    let title = clean_title(&b.title)?;
    let c = app.pool.get().await?;
    if c.query_opt("SELECT 1 FROM albums WHERE title = $1 AND id <> $2", &[&title, &id]).await?.is_some() {
        return Err(ApiError::BadRequest("an album with that title already exists"));
    }
    let n = c.execute("UPDATE albums SET title = $2 WHERE id = $1", &[&id, &title]).await?;
    if n == 0 {
        return Err(ApiError::NotFound);
    }
    follow(&app, id).await;
    Ok(Json(json!({ "id": id, "title": title })))
}

/// Deletes the album only; its assets stay in the library.
pub async fn remove(State(app): State<AppState>, Path(id): Path<i64>) -> ApiResult<Json<Value>> {
    if let Err(e) = crate::share::album_removed(&app, id).await {
        tracing::warn!("album {id}: ending its share link failed: {e:#}");
    }
    let c = app.pool.get().await?;
    let n = c.execute("DELETE FROM albums WHERE id = $1", &[&id]).await?;
    Ok(Json(json!({ "deleted": n })))
}

pub async fn add_assets(State(app): State<AppState>, Path(id): Path<i64>, Json(b): Json<Ids>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    if c.query_opt("SELECT 1 FROM albums WHERE id = $1", &[&id]).await?.is_none() {
        return Err(ApiError::NotFound);
    }
    let n = c
        .execute(
            "INSERT INTO album_assets (album_id, asset_id)
             SELECT $1, id FROM assets WHERE id = ANY($2)
             ON CONFLICT DO NOTHING",
            &[&id, &b.ids],
        )
        .await?;
    follow(&app, id).await;
    Ok(Json(json!({ "added": n })))
}

pub async fn remove_assets(State(app): State<AppState>, Path(id): Path<i64>, Json(b): Json<Ids>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let n = c
        .execute("DELETE FROM album_assets WHERE album_id = $1 AND asset_id = ANY($2)", &[&id, &b.ids])
        .await?;
    follow(&app, id).await;
    Ok(Json(json!({ "removed": n })))
}

/// The album's share link, if it has one, follows the change.
async fn follow(app: &AppState, album: i64) {
    if let Err(e) = crate::share::album_changed(app, album).await {
        tracing::warn!("album {album}: updating its share link failed: {e:#}");
    }
}
