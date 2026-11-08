//! Faces taken from people, and strangers hidden.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{ApiResult, AppState, media};

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
