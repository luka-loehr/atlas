//! Changing the tree: folders made, renamed and deleted, files renamed,
//! anything moved.

use axum::Json;
use axum::extract::{Path, State};
use serde::Deserialize;
use serde_json::{Value, json};

use super::blobs::{collect_blobs, mime_for};
use super::folder_ref;
use crate::{ApiError, ApiResult, AppState};

#[derive(Deserialize)]
pub(super) struct NewFolder {
    parent_id: Option<i64>,
    name: String,
}

#[derive(Deserialize)]
pub(super) struct Rename {
    name: String,
}

/// A name that is one path component: no separators, not a dot entry.
fn clean_name(raw: &str) -> ApiResult<&str> {
    let name = raw.trim();
    if name.is_empty()
        || name.chars().count() > 255
        || name.contains(['/', '\\'])
        || name == "."
        || name == ".."
    {
        return Err(ApiError::BadRequest("invalid name"));
    }
    Ok(name)
}

/// Creating a folder that exists returns it.
pub(super) async fn folder_create(
    State(app): State<AppState>,
    Json(b): Json<NewFolder>,
) -> ApiResult<Json<Value>> {
    let name = clean_name(&b.name)?;
    let c = app.pool.get().await?;
    if let Some(parent) = b.parent_id
        && c.query_opt("SELECT 1 FROM drive_folders WHERE id = $1", &[&parent])
            .await?
            .is_none()
    {
        return Err(ApiError::BadRequest("unknown folder"));
    }
    let row = c
        .query_one(
            "INSERT INTO drive_folders (parent_id, name) VALUES ($1, $2)
             ON CONFLICT (parent_id, name) DO UPDATE SET name = EXCLUDED.name
             RETURNING id",
            &[&b.parent_id, &name],
        )
        .await?;
    Ok(Json(json!({ "id": row.get::<_, i64>(0), "name": name })))
}

pub(super) async fn folder_rename(
    State(app): State<AppState>,
    Path(id): Path<String>,
    Json(b): Json<Rename>,
) -> ApiResult<Json<Value>> {
    let id = folder_ref(&id)?.ok_or(ApiError::BadRequest("the root cannot be renamed"))?;
    let name = clean_name(&b.name)?;
    let c = app.pool.get().await?;
    let taken = c
        .query_opt(
            "SELECT 1 FROM drive_folders s JOIN drive_folders me ON me.id = $1
             WHERE s.parent_id IS NOT DISTINCT FROM me.parent_id AND s.name = $2 AND s.id <> $1",
            &[&id, &name],
        )
        .await?;
    if taken.is_some() {
        return Err(ApiError::BadRequest(
            "a folder with that name already exists here",
        ));
    }
    let n = c
        .execute(
            "UPDATE drive_folders SET name = $2 WHERE id = $1",
            &[&id, &name],
        )
        .await?;
    Ok(Json(json!({ "updated": n })))
}

/// Permanent: the folder, its whole subtree and every file row in it, then
/// the blobs that lost their last reference.
pub(super) async fn folder_delete(
    State(app): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    let id = folder_ref(&id)?.ok_or(ApiError::BadRequest("the root cannot be deleted"))?;
    let c = app.pool.get().await?;
    let hashes: Vec<String> = c
        .query(
            "WITH RECURSIVE tree AS (
                 SELECT id FROM drive_folders WHERE id = $1
               UNION ALL
                 SELECT f.id FROM drive_folders f JOIN tree t ON f.parent_id = t.id
             )
             SELECT DISTINCT hash FROM drive_files WHERE folder_id IN (SELECT id FROM tree)",
            &[&id],
        )
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    let n = c
        .execute("DELETE FROM drive_folders WHERE id = $1", &[&id])
        .await?;
    drop(c);
    collect_blobs(&app, &hashes).await?;
    Ok(Json(json!({ "deleted": n })))
}

pub(super) async fn file_rename(
    State(app): State<AppState>,
    Path(id): Path<i64>,
    Json(b): Json<Rename>,
) -> ApiResult<Json<Value>> {
    let name = clean_name(&b.name)?;
    let c = app.pool.get().await?;
    let n = c
        .execute(
            "UPDATE drive_files SET name = $2, mime = $3 WHERE id = $1",
            &[&id, &name, &mime_for(name)],
        )
        .await?;
    Ok(Json(json!({ "updated": n })))
}

#[derive(Deserialize)]
pub(super) struct Move {
    #[serde(default)]
    files: Vec<i64>,
    #[serde(default)]
    folders: Vec<i64>,
    /// null = root
    to: Option<i64>,
}

/// A folder cannot move into itself or anything below it.
pub(super) async fn mv(State(app): State<AppState>, Json(b): Json<Move>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    if let Some(target) = b.to {
        if c.query_opt("SELECT 1 FROM drive_folders WHERE id = $1", &[&target])
            .await?
            .is_none()
        {
            return Err(ApiError::BadRequest("unknown folder"));
        }
        if !b.folders.is_empty() {
            let cycle = c
                .query_opt(
                    "WITH RECURSIVE below AS (
                         SELECT id FROM drive_folders WHERE id = ANY($1)
                       UNION ALL
                         SELECT f.id FROM drive_folders f JOIN below ON f.parent_id = below.id
                     )
                     SELECT 1 FROM below WHERE id = $2",
                    &[&b.folders, &target],
                )
                .await?;
            if cycle.is_some() {
                return Err(ApiError::BadRequest("cannot move a folder into itself"));
            }
        }
    }
    let mut moved = 0;
    if !b.files.is_empty() {
        moved += c
            .execute(
                "UPDATE drive_files SET folder_id = $2 WHERE id = ANY($1)",
                &[&b.files, &b.to],
            )
            .await?;
    }
    if !b.folders.is_empty() {
        moved += c
            .execute(
                "UPDATE drive_folders SET parent_id = $2 WHERE id = ANY($1)",
                &[&b.folders, &b.to],
            )
            .await?;
    }
    Ok(Json(json!({ "moved": moved })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_single_path_components() {
        assert!(clean_name("Steuer 2025").is_ok());
        assert!(clean_name("a/b").is_err());
        assert!(clean_name("..").is_err());
        assert!(clean_name("   ").is_err());
    }
}
