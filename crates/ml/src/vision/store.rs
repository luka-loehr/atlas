//! Storing what was found: faces (a face found again keeps its person),
//! people's counts and centroids, the graph, the text, and the crops.

use std::collections::HashSet;
use std::path::Path;

use anyhow::Result;
use image::RgbImage;
use pgvector::Vector;

use super::assign::{MIN_CLARITY_ASSIGN, assign_animal, assign_face, founder, refresh_people};
use super::engines::Found;
use super::frames::Frame;
use super::tracks::{tracks, worth};
use super::MODEL;
use crate::animals::iou;
use crate::{Worker, pixels};

/// A redetected face takes the person of the face it overlaps this much.
const SAME_PLACE: f32 = 0.4;

struct Previous {
    id: i64,
    person: Option<i64>,
    named: bool,
    kind: String,
    bbox: [f32; 4],
    vetoed: Vec<i64>,
}

pub(super) async fn store(worker: &Worker, id: &str, video: bool, mut found: Vec<Found>, lines: &[String], frames: &[Frame]) -> Result<()> {
    let mut c = worker.pool.get().await?;
    let tx = c.transaction().await?;
    let previous: Vec<Previous> = tx
        .query(
            "SELECT f.id, f.person_id, p.display_name IS NOT NULL, f.kind, f.bbox, f.vetoed
             FROM faces f LEFT JOIN persons p ON p.id = f.person_id
             WHERE f.asset_id = $1",
            &[&id],
        )
        .await?
        .iter()
        .map(|r| {
            let b: Vec<f32> = r.get::<_, Option<Vec<f32>>>(4).unwrap_or_default();
            Previous {
                id: r.get(0),
                person: r.get(1),
                named: r.get(2),
                kind: r.get(3),
                bbox: [0, 1, 2, 3].map(|i| b.get(i).copied().unwrap_or(0.0)),
                vetoed: r.get(5),
            }
        })
        .collect();

    // a face found where one was before is that face's person: a name never
    // depends on what the recognizer thinks
    let mut inherited: HashSet<i64> = HashSet::new();
    let mut order: Vec<usize> = (0..found.len()).filter(|&i| frames[found[i].frame].poster).collect();
    order.sort_by(|&a, &b| worth(&found[b]).total_cmp(&worth(&found[a])));
    for i in order {
        let best = previous
            .iter()
            .filter(|p| p.kind == found[i].kind && p.person.is_some() && !inherited.contains(&p.id))
            .map(|p| (p, iou(&p.bbox, &found[i].bbox)))
            .filter(|(_, overlap)| *overlap >= SAME_PLACE)
            .max_by(|a, b| a.1.total_cmp(&b.1));
        if let Some((p, _)) = best {
            inherited.insert(p.id);
            found[i].person = p.person;
            found[i].replaces = Some(p.id);
        }
    }
    // and whom it was taken away from: that stays so
    for f in found.iter_mut().filter(|f| frames[f.frame].poster) {
        for p in previous.iter().filter(|p| p.kind == f.kind && iou(&p.bbox, &f.bbox) >= SAME_PLACE) {
            for &v in &p.vetoed {
                if !f.vetoed.contains(&v) {
                    f.vetoed.push(v);
                }
            }
        }
        if f.person.is_some_and(|p| f.vetoed.contains(&p)) {
            f.person = None;
        }
    }
    if video {
        found = tracks(found);
    }

    // the rest by resemblance
    for f in found.iter_mut().filter(|f| f.person.is_none()) {
        f.person = match (&f.embedding, &f.look) {
            (Some(_), _) if f.clarity.unwrap_or(0.0) < MIN_CLARITY_ASSIGN => None,
            (Some(embedding), _) => {
                let founder = founder(f.width_px, f.clarity.unwrap_or(0.0), f.score);
                assign_face(&tx, embedding, f.width_px, founder, &f.vetoed).await?
            }
            (None, Some(look)) => assign_animal(&tx, f.kind, look, &f.vetoed).await?,
            (None, None) => None,
        };
    }

    // what goes: faces found again (replaced) and faces nobody named; a
    // named face the detector missed this time stays
    let dropped: Vec<i64> = previous.iter().filter(|p| inherited.contains(&p.id) || !p.named).map(|p| p.id).collect();

    let mut crops = Vec::new();
    let mut touched: HashSet<i64> = previous.iter().filter_map(|p| p.person).collect();
    for f in &found {
        let embedding = f.embedding.clone().map(Vector::from);
        let look = f.look.clone().map(Vector::from);
        let at = frames[f.frame].at;
        let model = f.embedding.as_ref().map(|_| MODEL);
        let face_id: i64 = tx
            .query_one(
                "INSERT INTO faces (asset_id, person_id, bbox, quality, embedding, kind, look, frame_s, model, width_px, clarity, vetoed)
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, coalesce($9, 'none'), $10, $11, $12) RETURNING id",
                &[&id, &f.person, &f.bbox.to_vec(), &f.score, &embedding, &f.kind, &look, &at, &model, &f.width_px, &f.clarity, &f.vetoed],
            )
            .await?
            .get(0);
        if let Some(person) = f.person {
            touched.insert(person);
            tx.execute("UPDATE persons SET cover_face_id = $2 WHERE id = $1 AND cover_face_id IS NULL", &[&person, &face_id])
                .await?;
        }
        // a cover the owner chose moves to the face that replaces it
        if let Some(old) = f.replaces {
            tx.execute("UPDATE persons SET cover_face_id = $2 WHERE cover_face_id = $1", &[&old, &face_id]).await?;
        }
        crops.push((face_id, f.frame, f.bbox, f.kind == "person"));
    }
    tx.execute("DELETE FROM faces WHERE id = ANY($1)", &[&dropped]).await?;

    // the graph: who is in this asset
    tx.execute("DELETE FROM edges WHERE src_type = 'asset' AND src_id = $1 AND rel = 'depicts'", &[&id]).await?;
    tx.execute(
        "INSERT INTO edges (src_type, src_id, rel, dst_type, dst_id, confidence)
         SELECT DISTINCT 'asset', $1, 'depicts', 'person', person_id::text, 1.0
         FROM faces WHERE asset_id = $1 AND person_id IS NOT NULL
         ON CONFLICT DO NOTHING",
        &[&id],
    )
    .await?;
    let touched: Vec<i64> = touched.into_iter().collect();
    refresh_people(&tx, &touched).await?;

    // what it says
    if lines.is_empty() {
        tx.execute("DELETE FROM asset_text WHERE asset_id = $1", &[&id]).await?;
    } else {
        tx.execute(
            "INSERT INTO asset_text (asset_id, text, updated_at) VALUES ($1, $2, now())
             ON CONFLICT (asset_id) DO UPDATE SET text = EXCLUDED.text, updated_at = now()",
            &[&id, &lines.join("\n")],
        )
        .await?;
    }
    tx.commit().await?;

    let faces_dir = worker.cfg.faces_dir();
    tokio::task::block_in_place(|| {
        let _ = std::fs::create_dir_all(&faces_dir);
        for old in &dropped {
            let _ = std::fs::remove_file(faces_dir.join(format!("{old}.webp")));
        }
        for (face_id, frame, bbox, face) in crops {
            let image = &frames[frame].image;
            let (w, h) = (image.width() as f32, image.height() as f32);
            let px = [bbox[0] * w, bbox[1] * h, bbox[2] * w, bbox[3] * h];
            if let Err(e) = save_crop(image, px, if face { 1.5 } else { 1.15 }, &faces_dir.join(format!("{face_id}.webp"))) {
                tracing::warn!("crop {face_id}: {e:#}"); // cosmetic: never fails the job
            }
        }
    });
    Ok(())
}

/// A square avatar: the box with a margin, at most 256 px.
fn save_crop(image: &RgbImage, bbox: [f32; 4], margin: f32, path: &Path) -> Result<()> {
    let (w, h) = (image.width() as f32, image.height() as f32);
    let (cx, cy) = ((bbox[0] + bbox[2]) / 2.0, (bbox[1] + bbox[3]) / 2.0);
    let side = (bbox[2] - bbox[0]).max(bbox[3] - bbox[1]) * margin;
    let x0 = (cx - side / 2.0).max(0.0) as u32;
    let y0 = (cy - side / 2.0).max(0.0) as u32;
    let x1 = (cx + side / 2.0).min(w) as u32;
    let y1 = (cy + side / 2.0).min(h) as u32;
    anyhow::ensure!(x1 > x0 && y1 > y0, "empty crop");
    let crop = image::imageops::crop_imm(image, x0, y0, x1 - x0, y1 - y0).to_image();
    let scale = (256.0 / crop.width().max(crop.height()) as f32).min(1.0);
    let small = pixels::resize(
        &crop,
        ((crop.width() as f32 * scale) as u32).max(1),
        ((crop.height() as f32 * scale) as u32).max(1),
        fast_image_resize::FilterType::Lanczos3,
    )?;
    let encoded = webp::Encoder::from_rgb(small.as_raw(), small.width(), small.height()).encode(86.0);
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, &*encoded)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}
