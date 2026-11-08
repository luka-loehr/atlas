//! People: face clusters the ML worker builds, named and merged here.

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;
use serde_json::{Value, json};

use super::{COLS, Columns, VISIBLE};
use crate::{ApiError, ApiResult, App, AppState, media};

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
pub async fn list(State(app): State<AppState>, Query(q): Query<ListQuery>, headers: HeaderMap) -> ApiResult<Response> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!(
                "SELECT p.id, p.display_name, p.cover_face_id, count(DISTINCT f.asset_id) AS photos, p.kind
                 FROM persons p
                 JOIN faces f ON f.person_id = p.id
                 JOIN assets ON assets.id = f.asset_id
                 WHERE p.merged_into IS NULL AND p.hidden = $2 AND {VISIBLE}
                 GROUP BY p.id
                 HAVING p.display_name IS NOT NULL OR count(DISTINCT f.asset_id) >= $1
                 ORDER BY (p.display_name IS NULL), photos DESC, p.id"
            ),
            &[&MIN_UNNAMED_PHOTOS, &q.hidden],
        )
        .await?;
    let people: Vec<Value> = rows.iter().map(person_json).collect();
    Ok(media::json_validated(&headers, &json!({ "people": people })))
}

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

pub async fn assets(State(app): State<AppState>, Path(id): Path<i64>, headers: HeaderMap) -> ApiResult<Response> {
    let c = app.pool.get().await?;
    let person = c
        .query_opt("SELECT display_name, cover_face_id, kind FROM persons WHERE id = $1", &[&id])
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

pub async fn update(State(app): State<AppState>, Path(id): Path<i64>, Json(b): Json<Update>) -> ApiResult<Json<Value>> {
    let c = app.pool.get().await?;
    let mut updated = 0;
    if let Some(name) = &b.name {
        let name = name.trim();
        let value = (!name.is_empty()).then_some(name);
        updated += c.execute("UPDATE persons SET display_name = $2 WHERE id = $1", &[&id, &value]).await?;
    }
    if let Some(hidden) = b.hidden {
        updated += c.execute("UPDATE persons SET hidden = $2 WHERE id = $1", &[&id, &hidden]).await?;
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
pub async fn merge(State(app): State<AppState>, Path(id): Path<i64>, Json(b): Json<Merge>) -> ApiResult<Json<Value>> {
    if id == b.into {
        return Err(ApiError::BadRequest("cannot merge a person into itself"));
    }
    let mut c = app.pool.get().await?;
    let tx = c.transaction().await?;
    let both = tx
        .query("SELECT id FROM persons WHERE id = ANY($1) AND merged_into IS NULL", &[&vec![id, b.into]])
        .await?;
    if both.len() != 2 {
        return Err(ApiError::NotFound);
    }
    let moved = tx.execute("UPDATE faces SET person_id = $2 WHERE person_id = $1", &[&id, &b.into]).await?;
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
    tx.execute("DELETE FROM edges WHERE dst_type = 'person' AND dst_id = $1", &[&from]).await?;
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

#[derive(Deserialize)]
pub struct HideFaces {
    /// faces to hide; or
    #[serde(default)]
    faces: Vec<i64>,
    /// every face in these assets
    #[serde(default)]
    assets: Vec<String>,
}

#[derive(Deserialize)]
pub struct Unassign {
    faces: Vec<i64>,
}

/// Takes faces away from the people they were filed under, for good: each
/// face remembers whom it is not (faces.vetoed), so neither the grouping
/// pass nor a re-analysis files it there again.
pub async fn unassign_faces(State(app): State<AppState>, Json(b): Json<Unassign>) -> ApiResult<Json<Value>> {
    let mut c = app.pool.get().await?;
    let tx = c.transaction().await?;
    let rows = tx
        .query(
            "UPDATE faces f SET vetoed = array_append(f.vetoed, old.person_id), person_id = NULL
             FROM (SELECT id, person_id FROM faces WHERE id = ANY($1) AND person_id IS NOT NULL FOR UPDATE) old
             WHERE f.id = old.id
             RETURNING old.person_id, f.asset_id, f.id",
            &[&b.faces],
        )
        .await?;
    for r in &rows {
        let (person, asset, face): (i64, String, i64) = (r.get(0), r.get(1), r.get(2));
        tx.execute(
            "DELETE FROM edges WHERE src_type = 'asset' AND src_id = $1 AND rel = 'depicts'
               AND dst_type = 'person' AND dst_id = $3
               AND NOT EXISTS (SELECT 1 FROM faces WHERE asset_id = $1 AND person_id = $2)",
            &[&asset, &person, &person.to_string()],
        )
        .await?;
        tx.execute("UPDATE persons SET cover_face_id = NULL WHERE id = $1 AND cover_face_id = $2", &[&person, &face]).await?;
    }
    let people: Vec<i64> = rows.iter().map(|r| r.get(0)).collect();
    tx.execute(
        "UPDATE persons p SET face_count = (SELECT count(*) FROM faces f WHERE f.person_id = p.id),
                cover_face_id = coalesce(p.cover_face_id,
                    (SELECT f.id FROM faces f WHERE f.person_id = p.id ORDER BY f.quality * f.width_px DESC NULLS LAST LIMIT 1))
         WHERE p.id = ANY($1)",
        &[&people],
    )
    .await?;
    tx.commit().await?;
    Ok(Json(json!({ "unassigned": rows.len() })))
}

/// Hides the people behind faces (a group photo of strangers): an unnamed
/// face's person is hidden, and a face nobody was recognized in gets a
/// hidden person of its own, which then takes that stranger's other faces
/// too. Named people are never hidden this way.
pub async fn hide_faces(State(app): State<AppState>, Json(b): Json<HideFaces>) -> ApiResult<Json<Value>> {
    let mut c = app.pool.get().await?;
    let tx = c.transaction().await?;
    let faces: Vec<(i64, Option<i64>, String)> = tx
        .query(
            "SELECT f.id, f.person_id, f.kind FROM faces f LEFT JOIN persons p ON p.id = f.person_id
             WHERE (f.id = ANY($1) OR f.asset_id = ANY($2)) AND p.display_name IS NULL",
            &[&b.faces, &b.assets],
        )
        .await?
        .iter()
        .map(|r| (r.get(0), r.get(1), r.get(2)))
        .collect();
    let mut hidden = 0u64;
    for (face, person, kind) in &faces {
        match person {
            Some(person) => hidden += tx.execute("UPDATE persons SET hidden = true WHERE id = $1 AND NOT hidden", &[person]).await?,
            None => {
                let person: i64 = tx
                    .query_one(
                        "INSERT INTO persons (kind, hidden, cover_face_id, face_count) VALUES ($1, true, $2, 1) RETURNING id",
                        &[kind, face],
                    )
                    .await?
                    .get(0);
                tx.execute("UPDATE faces SET person_id = $2 WHERE id = $1", &[face, &person]).await?;
                tx.execute(
                    "INSERT INTO edges (src_type, src_id, rel, dst_type, dst_id)
                     SELECT 'asset', asset_id, 'depicts', 'person', $2::text FROM faces WHERE id = $1
                     ON CONFLICT DO NOTHING",
                    &[face, &person.to_string()],
                )
                .await?;
                hidden += 1;
            }
        }
    }
    tx.commit().await?;
    Ok(Json(json!({ "faces": faces.len(), "hidden": hidden })))
}

/// The square avatar the face worker wrote. Face ids are never reused, so
/// the crop is immutable.
pub async fn face_crop(State(app): State<AppState>, Path(id): Path<i64>, headers: HeaderMap) -> Response {
    media::immutable_file(app.cfg.faces_dir().join(format!("{id}.webp")), headers).await
}

/// Keeps every person showable, run hourly: unnamed people left without
/// faces are removed (a named person is never removed: their name is the
/// owner's work, and a re-run of the vision stage may leave them without
/// faces for a moment), and a person whose cover is missing, hidden (archived, locked,
/// trashed) or has no crop on disk gets their best visible face instead.
/// A cover the owner chose stays while it is visible. Returns (removed,
/// covers set).
pub async fn tidy(app: &App) -> ApiResult<(u64, usize)> {
    let c = app.pool.get().await?;
    let removed = c
        .execute(
            "DELETE FROM persons p
             WHERE p.merged_into IS NULL
               AND p.display_name IS NULL
               AND NOT EXISTS (SELECT 1 FROM faces WHERE person_id = p.id)
               AND NOT EXISTS (SELECT 1 FROM persons m WHERE m.merged_into = p.id)
               AND NOT EXISTS (SELECT 1 FROM edges WHERE dst_type = 'person' AND dst_id = p.id::text)",
            &[],
        )
        .await?;
    let faces = app.cfg.faces_dir();
    let has_crop = |id: i64| faces.join(format!("{id}.webp")).is_file();
    let rows = c
        .query(
            &format!(
                "SELECT p.id, p.cover_face_id,
                        EXISTS (SELECT 1 FROM faces f JOIN assets ON assets.id = f.asset_id
                                WHERE f.id = p.cover_face_id AND {VISIBLE})
                 FROM persons p
                 WHERE p.merged_into IS NULL"
            ),
            &[],
        )
        .await?;
    let mut set = 0;
    for r in rows {
        let (person, cover, visible): (i64, Option<i64>, bool) = (r.get(0), r.get(1), r.get(2));
        if visible && cover.is_some_and(has_crop) {
            continue;
        }
        // the sharpest, largest faces first
        let candidates = c
            .query(
                &format!(
                    "SELECT f.id FROM faces f JOIN assets ON assets.id = f.asset_id
                     WHERE f.person_id = $1 AND {VISIBLE}
                     ORDER BY coalesce(f.quality, 0) * (f.bbox[3] - f.bbox[1]) * (f.bbox[4] - f.bbox[2]) DESC NULLS LAST
                     LIMIT 20"
                ),
                &[&person],
            )
            .await?;
        if let Some(face) = candidates.iter().map(|r| r.get::<_, i64>(0)).find(|&id| has_crop(id))
            && Some(face) != cover
        {
            c.execute("UPDATE persons SET cover_face_id = $2 WHERE id = $1", &[&person, &face]).await?;
            set += 1;
        }
    }
    Ok((removed, set))
}
