//! The model stages of the job queue: `embed` and `faces`.
//!
//! One job at a time: there is one GPU. Both stages work from the 2048px
//! thumbnail the server's workers make, so a job whose thumbnail does not
//! exist yet is put back without spending an attempt.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use atlas_core::queue::{self, Job};
use pgvector::Vector;

use crate::faces::{Face, FaceEngine};
use crate::{Worker, pixels};

/// Two detections this similar are the same face in the same photo.
const SAME_DETECTION: f32 = 0.9;
/// A face belongs to the person of an existing face this similar to it ...
const SAME_FACE: f64 = 0.6;
/// ... or to the person whose centroid is this close. Below both it starts a
/// new person.
const SAME_PERSON: f64 = 0.55;
/// Faces smaller than this share of the image are background.
const MIN_FACE_AREA: f32 = 0.02;
const NOT_READY: Duration = Duration::from_secs(60);

enum Outcome {
    Done,
    /// the thumbnail this stage reads is not there yet
    NotReady,
}

pub async fn run(worker: Arc<Worker>) {
    let name = format!("ml:{}", std::process::id());
    let mut notifications = atlas_core::db::listen(&["atlas_jobs"]);
    let mut engine: Option<FaceEngine> = None;
    if let Ok(c) = worker.pool.get().await {
        let _ = queue::reap(&c).await;
    }
    loop {
        let claimed = match worker.pool.get().await {
            Ok(c) => queue::claim(&c, &name, &[queue::FACES, queue::EMBED], 1).await.map_err(anyhow::Error::from),
            Err(e) => Err(e.into()),
        };
        let job = match claimed {
            Ok(mut jobs) if !jobs.is_empty() => jobs.remove(0),
            Ok(_) => {
                // nothing to do: release the face models too, then wait for
                // Postgres to announce a job
                engine = None;
                tokio::select! {
                    _ = notifications.recv() => {}
                    _ = tokio::time::sleep(Duration::from_secs(60)) => {}
                }
                continue;
            }
            Err(e) => {
                tracing::warn!("queue unavailable: {e:#}");
                tokio::time::sleep(Duration::from_secs(5)).await;
                continue;
            }
        };

        let started = std::time::Instant::now();
        let result = match job.kind.as_str() {
            queue::EMBED => embed(&worker, &job).await,
            _ => faces(&worker, &mut engine, &job).await,
        };
        let settled = async {
            let c = worker.pool.get().await?;
            match &result {
                Ok(Outcome::Done) => queue::done(&c, job.id).await?,
                Ok(Outcome::NotReady) => queue::defer(&c, job.id, NOT_READY, Some("no thumbnail yet")).await?,
                Err(e) => queue::fail(&c, job.id, &format!("{e:#}")).await?,
            }
            anyhow::Ok(())
        }
        .await;
        let id = &job.owner_id[..job.owner_id.len().min(12)];
        match (&result, settled) {
            (_, Err(e)) => tracing::warn!("{} {id}: could not settle: {e:#}", job.kind),
            (Ok(Outcome::Done), _) => tracing::info!("{} {id} done in {:.0?}", job.kind, started.elapsed()),
            (Ok(Outcome::NotReady), _) => {}
            (Err(e), _) => tracing::warn!("{} {id} failed: {e:#}", job.kind),
        }
    }
}

// ------------------------------------------------------------------- embed ---

async fn embed(worker: &Worker, job: &Job) -> Result<Outcome> {
    let id = &job.owner_id;
    let c = worker.pool.get().await?;
    let row = c
        .query_opt("SELECT type, orig_path, duration_s FROM assets WHERE id = $1", &[id])
        .await?
        .context("asset is gone")?;
    drop(c);
    let is_video = row.get::<_, &str>(0) == "video";
    let original = std::path::PathBuf::from(row.get::<_, String>(1));
    let duration: Option<f64> = row.get(2);

    let vec = match (is_video && original.exists(), duration) {
        (true, Some(duration)) if duration > 0.0 => worker.embedder.embed_video(&original, duration).await?,
        _ => {
            let Some(thumb) = worker.cfg.thumb(id) else { return Ok(Outcome::NotReady) };
            let image = tokio::task::spawn_blocking(move || pixels::open(&thumb)).await??;
            worker.embedder.embed_image(&image).await?
        }
    };

    let c = worker.pool.get().await?;
    c.execute(
        "INSERT INTO embeddings (owner_type, owner_id, model, vec, updated_at)
         VALUES ('asset', $1, 'qwen3vl', $2, now())
         ON CONFLICT (owner_type, owner_id, model)
         DO UPDATE SET vec = EXCLUDED.vec, updated_at = now()",
        &[id, &Vector::from(vec)],
    )
    .await?;
    Ok(Outcome::Done)
}

// ------------------------------------------------------------------- faces ---

async fn faces(worker: &Worker, engine: &mut Option<FaceEngine>, job: &Job) -> Result<Outcome> {
    let id = &job.owner_id;
    let Some(thumb) = worker.cfg.thumb(id) else { return Ok(Outcome::NotReady) };
    if engine.is_none() {
        let (detector, recognizer) = (worker.cfg.face_detector.clone(), worker.cfg.face_recognizer.clone());
        *engine = Some(tokio::task::spawn_blocking(move || FaceEngine::load(&detector, &recognizer)).await??);
        tracing::info!("face models loaded");
    }
    let engine = engine.as_mut().expect("just loaded");
    let (image, found) = tokio::task::block_in_place(|| -> Result<_> {
        let image = pixels::open(&thumb)?;
        let found = engine.analyze(&image)?;
        Ok((image, found))
    })?;
    let (w, h) = (image.width() as f32, image.height() as f32);
    let found: Vec<Face> = found
        .into_iter()
        .filter(|f| (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]) >= MIN_FACE_AREA * w * h)
        .collect();

    let mut c = worker.pool.get().await?;
    let tx = c.transaction().await?;
    // the stage owns this asset's faces: replace them, rows and crop files
    // ... but who a face was assigned to survives a re-run: a person the
    // owner put it under by hand may not be the one it resembles most
    let previous: Vec<(i64, Option<i64>, Option<Vector>)> = tx
        .query(
            "SELECT f.id, f.person_id, f.embedding FROM faces f
             LEFT JOIN persons p ON p.id = f.person_id
             WHERE f.asset_id = $1 AND (p.id IS NULL OR p.merged_into IS NULL)",
            &[id],
        )
        .await?
        .iter()
        .map(|r| (r.get(0), r.get(1), r.get(2)))
        .collect();
    tx.execute("DELETE FROM faces WHERE asset_id = $1", &[id]).await?;
    tx.execute("DELETE FROM edges WHERE src_type = 'asset' AND src_id = $1 AND rel = 'depicts'", &[id]).await?;

    let mut touched = Vec::new();
    let mut crops = Vec::new();
    for face in &found {
        let embedding = Vector::from(face.embedding.clone());
        // Whose face is this? First by the single most similar face already
        // known: a person is many looks (ages, angles, glasses), and clusters
        // merged by hand are held together by exactly such links, which one
        // averaged centroid cannot represent. Then by the nearest centroid.
        // Otherwise it is someone new.
        let by_face = tx
            .query_opt(
                "SELECT person_id, 1 - (embedding <=> $1) FROM faces
                 WHERE person_id IS NOT NULL AND embedding IS NOT NULL
                 ORDER BY embedding <=> $1 LIMIT 1",
                &[&embedding],
            )
            .await?
            .filter(|row| row.get::<_, Option<f64>>(1).is_some_and(|s| s > SAME_FACE));
        let by_centroid = match by_face {
            Some(_) => None,
            None => tx
                .query_opt(
                    "SELECT id, 1 - (centroid <=> $1) FROM persons
                     WHERE merged_into IS NULL AND centroid IS NOT NULL
                     ORDER BY centroid <=> $1 LIMIT 1",
                    &[&embedding],
                )
                .await?
                .filter(|row| row.get::<_, Option<f64>>(1).is_some_and(|s| s > SAME_PERSON)),
        };
        let kept = previous.iter().find_map(|(_, person, old)| {
            let old = old.as_ref()?.as_slice();
            let same: f32 = old.iter().zip(&face.embedding).map(|(a, b)| a * b).sum();
            (same > SAME_DETECTION).then_some((*person)?)
        });
        let (person, similarity) = match (kept, by_face.or(by_centroid)) {
            (Some(person), _) => (person, 1.0),
            (None, Some(row)) => (row.get::<_, i64>(0), row.get::<_, f64>(1)),
            (None, None) => {
                let row = tx
                    .query_one("INSERT INTO persons (centroid, face_count) VALUES ($1, 0) RETURNING id", &[&embedding])
                    .await?;
                (row.get(0), 1.0)
            }
        };
        let relative: Vec<f32> = vec![
            (face.bbox[0] / w).clamp(0.0, 1.0),
            (face.bbox[1] / h).clamp(0.0, 1.0),
            (face.bbox[2] / w).clamp(0.0, 1.0),
            (face.bbox[3] / h).clamp(0.0, 1.0),
        ];
        let face_id: i64 = tx
            .query_one(
                "INSERT INTO faces (asset_id, person_id, bbox, quality, embedding)
                 VALUES ($1, $2, $3, $4, $5) RETURNING id",
                &[id, &person, &relative, &face.score, &embedding],
            )
            .await?
            .get(0);
        tx.execute("UPDATE persons SET cover_face_id = $2 WHERE id = $1 AND cover_face_id IS NULL", &[&person, &face_id])
            .await?;
        tx.execute(
            "INSERT INTO edges (src_type, src_id, rel, dst_type, dst_id, confidence)
             VALUES ('asset', $1, 'depicts', 'person', $2, $3)
             ON CONFLICT (src_type, src_id, rel, dst_type, dst_id)
             DO UPDATE SET confidence = GREATEST(edges.confidence, EXCLUDED.confidence)",
            &[id, &person.to_string(), &(similarity as f32)],
        )
        .await?;
        // the centroid follows its faces immediately, so two faces of one
        // new person in the same photo batch find each other
        tx.execute(
            "UPDATE persons p SET face_count = c.n, centroid = c.a
             FROM (SELECT count(*) AS n, avg(embedding) AS a FROM faces WHERE person_id = $1) c
             WHERE p.id = $1",
            &[&person],
        )
        .await?;
        touched.push(person);
        crops.push((face_id, face.bbox));
    }
    // people who lost their last face here keep their row (and name) but
    // stop attracting new faces
    tx.execute(
        "UPDATE persons p SET face_count = 0, centroid = NULL
         WHERE p.merged_into IS NULL AND p.face_count > 0
           AND NOT EXISTS (SELECT 1 FROM faces f WHERE f.person_id = p.id)",
        &[],
    )
    .await?;
    tx.commit().await?;

    let faces_dir = worker.cfg.faces_dir();
    tokio::task::block_in_place(|| {
        let _ = std::fs::create_dir_all(&faces_dir);
        for (old, _, _) in &previous {
            let _ = std::fs::remove_file(faces_dir.join(format!("{old}.webp")));
        }
        for (face_id, bbox) in crops {
            if let Err(e) = save_crop(&image, bbox, &faces_dir.join(format!("{face_id}.webp"))) {
                tracing::warn!("face crop {face_id}: {e:#}"); // cosmetic: never fails the job
            }
        }
    });
    Ok(Outcome::Done)
}

/// A square avatar: the face box with a 25% margin, at most 256px.
fn save_crop(image: &image::RgbImage, bbox: [f32; 4], path: &std::path::Path) -> Result<()> {
    let (w, h) = (image.width() as f32, image.height() as f32);
    let (cx, cy) = ((bbox[0] + bbox[2]) / 2.0, (bbox[1] + bbox[3]) / 2.0);
    let side = (bbox[2] - bbox[0]).max(bbox[3] - bbox[1]) * 1.5;
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
