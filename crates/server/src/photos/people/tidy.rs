//! The hourly upkeep of people.

use crate::photos::VISIBLE;
use crate::{ApiResult, App};

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
