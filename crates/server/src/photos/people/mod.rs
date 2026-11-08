//! People: face clusters the ML worker builds, named and merged here.

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;
use serde_json::{Value, json};

use super::{COLS, Columns, VISIBLE};
use crate::{ApiError, ApiResult, AppState, media};

mod faces;
mod tidy;

pub use faces::{face_crop, hide_faces, unassign_faces};
pub use tidy::tidy;

/// Unnamed clusters with fewer photos than this stay out of the list:
/// mostly strangers in the background and odd detections.
const MIN_UNNAMED_PHOTOS: i64 = 3;

#[derive(Deserialize, Default)]
pub struct ListQuery {
    /// true: the hidden people instead (to bring someone back)
    #[serde(default)]
    hidden: bool,
}

/// Everyone with a visible photo, unnamed clusters only from
/// [`MIN_UNNAMED_PHOTOS`] on: named people first, then by how often they
/// appear. Pets are people of another kind. Hidden people only on request.
pub async fn list(
    State(app): State<AppState>,
    Query(q): Query<ListQuery>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!(
                "{SUMMARY}
                 WHERE p.merged_into IS NULL AND p.hidden = $2 AND {VISIBLE}
                 GROUP BY p.id
                 HAVING p.display_name IS NOT NULL OR count(DISTINCT f.asset_id) >= $1
                 ORDER BY (p.display_name IS NULL), photos DESC, p.id"
            ),
            &[&MIN_UNNAMED_PHOTOS, &q.hidden],
        )
        .await?;
    let people: Vec<Value> = rows.iter().map(person_json).collect();
    Ok(media::json_validated(
        &headers,
        &json!({ "people": people }),
    ))
}

/// People as the lists show them ([`person_json`]): each with their faces
/// `f` and those faces' `assets`; the caller adds WHERE and GROUP BY p.id.
pub const SUMMARY: &str =
    "SELECT p.id, p.display_name, p.cover_face_id, count(DISTINCT f.asset_id) AS photos, p.kind
                           FROM persons p
                           JOIN faces f ON f.person_id = p.id
                           JOIN assets ON assets.id = f.asset_id";

pub fn person_json(r: &tokio_postgres::Row) -> Value {
    json!({
        "id": r.get::<_, i64>(0),
        "name": r.get::<_, Option<String>>(1),
        "cover_face": r.get::<_, Option<i64>>(2),
        "photos": r.get::<_, i64>(3),
        // 'person', or a species for a pet ('dog', 'cat', 'horse', 'bird')
        "kind": r.get::<_, String>(4),
    })
}

pub async fn assets(
    State(app): State<AppState>,
    Path(id): Path<i64>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    let c = app.pool.get().await?;
    let person = c
        .query_opt(
            "SELECT display_name, cover_face_id, kind FROM persons WHERE id = $1",
            &[&id],
        )
        .await?
        .ok_or(ApiError::NotFound)?;
    let rows = c
        .query(
            &format!(
                "SELECT {COLS} FROM assets
                 WHERE {VISIBLE} AND EXISTS (SELECT 1 FROM faces f WHERE f.asset_id = assets.id AND f.person_id = $1)
                 ORDER BY assets.taken_at DESC NULLS LAST, assets.id"
            ),
            &[&id],
        )
        .await?;
    Ok(media::json_validated(
        &headers,
        &json!({
            "id": id,
            "name": person.get::<_, Option<String>>(0),
            "cover_face": person.get::<_, Option<i64>>(1),
            "kind": person.get::<_, String>(2),
            "assets": Columns::from_rows(&rows, app.cfg.tz),
        }),
    ))
}

#[derive(Deserialize)]
pub struct Update {
    /// "" clears the name
    name: Option<String>,
    /// must be one of this person's faces
    cover_face: Option<i64>,
    /// out of People, search and the info panel (or back)
    hidden: Option<bool>,
}

pub async fn update(
    State(app): State<AppState>,
    Path(id): Path<i64>,
    Json(b): Json<Update>,
) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let mut updated = 0;
    if let Some(name) = &b.name {
        let name = name.trim();
        let value = (!name.is_empty()).then_some(name);
        updated += c
            .execute(
                "UPDATE persons SET display_name = $2 WHERE id = $1",
                &[&id, &value],
            )
            .await?;
    }
    if let Some(hidden) = b.hidden {
        updated += c
            .execute(
                "UPDATE persons SET hidden = $2 WHERE id = $1",
                &[&id, &hidden],
            )
            .await?;
    }
    if let Some(face) = b.cover_face {
        updated += c
            .execute(
                "UPDATE persons SET cover_face_id = $2
                 WHERE id = $1 AND EXISTS (SELECT 1 FROM faces WHERE id = $2 AND person_id = $1)",
                &[&id, &face],
            )
            .await?;
    }
    Ok(Json(json!({ "updated": updated })))
}

#[derive(Deserialize)]
pub struct Merge {
    into: i64,
}

/// Fold this person into another: the faces move, the graph edges follow,
/// and the survivor's centroid is recomputed from all its faces so future
/// photos of either cluster land on it.
pub async fn merge(
    State(app): State<AppState>,
    Path(id): Path<i64>,
    Json(b): Json<Merge>,
) -> ApiResult<Json<Value>> {
    if id == b.into {
        return Err(ApiError::BadRequest("cannot merge a person into itself"));
    }
    let mut c = app.pool.get().await?;
    let tx = c.transaction().await?;
    let both = tx
        .query(
            "SELECT id FROM persons WHERE id = ANY($1) AND merged_into IS NULL",
            &[&vec![id, b.into]],
        )
        .await?;
    if both.len() != 2 {
        return Err(ApiError::NotFound);
    }
    let moved = tx
        .execute(
            "UPDATE faces SET person_id = $2 WHERE person_id = $1",
            &[&id, &b.into],
        )
        .await?;
    let (from, into) = (id.to_string(), b.into.to_string());
    tx.execute(
        "INSERT INTO edges (src_type, src_id, rel, dst_type, dst_id, confidence)
         SELECT src_type, src_id, rel, dst_type, $2, confidence FROM edges
         WHERE dst_type = 'person' AND dst_id = $1
         ON CONFLICT (src_type, src_id, rel, dst_type, dst_id)
         DO UPDATE SET confidence = GREATEST(edges.confidence, EXCLUDED.confidence)",
        &[&from, &into],
    )
    .await?;
    tx.execute(
        "DELETE FROM edges WHERE dst_type = 'person' AND dst_id = $1",
        &[&from],
    )
    .await?;
    tx.execute(
        "UPDATE persons SET merged_into = $2, centroid = NULL, look = NULL, face_count = 0, cover_face_id = NULL WHERE id = $1",
        &[&id, &b.into],
    )
    .await?;
    // the centroid of the current recognizer's faces (atlas-ml's
    // vision::refresh_people), an animal's mean look
    tx.execute(
        "UPDATE persons p SET face_count = c.n, centroid = coalesce(c.a, p.centroid), look = coalesce(c.l, p.look)
         FROM (SELECT count(*) AS n,
                      avg(embedding) FILTER (WHERE model = 'adaface-ir101') AS a,
                      avg(look) AS l
               FROM faces WHERE person_id = $1) c
         WHERE p.id = $1",
        &[&b.into],
    )
    .await?;
    tx.commit().await?;
    Ok(Json(json!({ "moved": moved })))
}
