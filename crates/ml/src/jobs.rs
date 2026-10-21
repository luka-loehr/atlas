//! The model stages of the job queue: `embed` and `faces`.
//!
//! Two loops side by side: embeddings on the GPU, as many at once as the
//! embedding server has slots to spare for the queue, and faces on the CPU,
//! one at a time. Both work from the 2048px thumbnail the server's workers
//! make (the thumbnail job queues them), so a job whose thumbnail is missing
//! is put back without spending an attempt, unless the thumbnail is not
//! coming: then it is parked as stuck and starts over when the thumbnail
//! is made after all.
//!
//! As in the server, nothing stays stuck: jobs are heartbeated while they
//! run, an embedding has a time limit, jobs a crashed predecessor held are
//! recovered at start and a clean shutdown hands its jobs back.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use atlas_core::queue::{self, Job};
use pgvector::Vector;
use tokio::sync::Semaphore;

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
const IDLE_POLL: Duration = Duration::from_secs(60);
/// One embedding, frames and all; its HTTP request and tools have their own
/// shorter limits.
const EMBED_LIMIT: Duration = Duration::from_secs(15 * 60);
const PREFIX: &str = "ml:";

/// Jobs this process is running, kept alive by the heartbeat.
type Running = Arc<Mutex<HashSet<i64>>>;

fn worker_name(stage: &str) -> String {
    format!("{PREFIX}{}:{stage}", std::process::id())
}

/// At a clean shutdown: the jobs this process holds go back unspent.
pub async fn release(worker: &Worker) {
    if let Ok(c) = worker.pool.get().await {
        for stage in ["embed", "faces"] {
            let _ = queue::release(&c, &worker_name(stage)).await;
        }
    }
}

enum Outcome {
    Done,
    /// the thumbnail this stage reads is not there yet
    NotReady,
}

pub async fn run(worker: Arc<Worker>) {
    // what an earlier process of ours held when it went down
    if let Ok(c) = worker.pool.get().await {
        match queue::recover(&c, PREFIX).await {
            Ok(0) => {}
            Ok(n) => tracing::warn!("recovered {n} jobs a stopped atlas-ml left running"),
            Err(e) => tracing::warn!("could not recover jobs: {e:#}"),
        }
    }
    let running: Running = Arc::default();
    // two slots stay free for searches (a search asks twice: for stills and
    // for clips)
    let parallel = worker.embedder.slots.saturating_sub(2).max(1) as usize;
    tokio::join!(
        heartbeat(worker.clone(), running.clone()),
        embeddings(worker.clone(), parallel, running.clone()),
        faces_loop(worker, running),
    );
}

/// Running jobs are marked alive once a minute, so the reaper leaves them be.
async fn heartbeat(worker: Arc<Worker>, running: Running) {
    loop {
        tokio::time::sleep(Duration::from_secs(60)).await;
        let ids: Vec<i64> = running.lock().unwrap().iter().copied().collect();
        if let Ok(c) = worker.pool.get().await {
            let _ = queue::heartbeat(&c, &ids).await;
        }
    }
}

/// Claims one job of `kind`, or waits for Postgres to announce one.
async fn next_job(worker: &Worker, name: &str, kind: &str, notifications: &mut tokio::sync::mpsc::UnboundedReceiver<&'static str>) -> Option<Job> {
    let claimed = match worker.pool.get().await {
        Ok(c) => queue::claim(&c, name, &[kind], 1).await.map_err(anyhow::Error::from),
        Err(e) => Err(e.into()),
    };
    match claimed {
        Ok(mut jobs) if !jobs.is_empty() => Some(jobs.remove(0)),
        Ok(_) => {
            tokio::select! {
                _ = notifications.recv() => {}
                _ = tokio::time::sleep(IDLE_POLL) => {}
            }
            None
        }
        Err(e) => {
            tracing::warn!("queue unavailable: {e:#}");
            tokio::time::sleep(Duration::from_secs(5)).await;
            None
        }
    }
}

async fn embeddings(worker: Arc<Worker>, parallel: usize, running: Running) {
    let name = worker_name("embed");
    let mut notifications = atlas_core::db::listen(&["atlas_jobs"]);
    let slots = Arc::new(Semaphore::new(parallel));
    loop {
        let slot = slots.clone().acquire_owned().await.expect("semaphore open");
        let Some(job) = next_job(&worker, &name, queue::EMBED, &mut notifications).await else { continue };
        let (worker, running) = (worker.clone(), running.clone());
        running.lock().unwrap().insert(job.id);
        tokio::spawn(async move {
            let started = Instant::now();
            let result = match tokio::time::timeout(EMBED_LIMIT, embed(&worker, &job)).await {
                Ok(result) => result,
                Err(_) => Err(anyhow::anyhow!("took longer than {EMBED_LIMIT:?}")),
            };
            settle(&worker, &job, result, started).await;
            running.lock().unwrap().remove(&job.id);
            drop(slot);
        });
    }
}

async fn faces_loop(worker: Arc<Worker>, running: Running) {
    let name = worker_name("faces");
    let mut notifications = atlas_core::db::listen(&["atlas_jobs"]);
    let mut engine: Option<FaceEngine> = None;
    loop {
        let Some(job) = next_job(&worker, &name, queue::FACES, &mut notifications).await else {
            // nothing to do: the face models' memory goes back too
            engine = None;
            continue;
        };
        running.lock().unwrap().insert(job.id);
        let started = Instant::now();
        let result = faces(&worker, &mut engine, &job).await;
        settle(&worker, &job, result, started).await;
        running.lock().unwrap().remove(&job.id);
    }
}

/// A job whose thumbnail is missing: wait for it while it is on its way,
/// queue it when nobody will make it, and give up (parked as stuck) when
/// it failed or an hour of waiting brought nothing. The thumbnail job starts
/// parked model jobs over once it succeeds.
async fn not_ready(c: &tokio_postgres::Client, job: &Job) -> Result<(), tokio_postgres::Error> {
    let thumb = c
        .query_opt(
            "SELECT status, error FROM ingest_jobs WHERE kind = $1 AND owner_type = 'asset' AND owner_id = $2",
            &[&queue::THUMB, &job.owner_id],
        )
        .await?;
    match thumb.as_ref().map(|r| (r.get::<_, String>(0), r.get::<_, Option<String>>(1))) {
        Some((status, error)) if status == "failed" || status == "stuck" => {
            queue::stick(c, job.id, &format!("its thumbnail failed: {}", error.unwrap_or_default())).await
        }
        _ if job.defers >= queue::MAX_DEFERS => queue::stick(c, job.id, "no thumbnail after an hour of waiting").await,
        None => {
            queue::enqueue(c, queue::THUMB, "asset", &job.owner_id, queue::PRIORITY_DEFAULT).await?;
            queue::defer(c, job.id, NOT_READY, Some("no thumbnail yet; its job was missing and is queued")).await
        }
        Some(_) => queue::defer(c, job.id, NOT_READY, Some("no thumbnail yet")).await,
    }
}

async fn settle(worker: &Worker, job: &Job, result: Result<Outcome>, started: Instant) {
    let settled = async {
        let c = worker.pool.get().await?;
        match &result {
            Ok(Outcome::Done) => queue::done(&c, job.id).await?,
            Ok(Outcome::NotReady) => not_ready(&c, job).await?,
            Err(e) => queue::fail(&c, job.id, &format!("{e:#}")).await?,
        }
        anyhow::Ok(())
    }
    .await;
    let id = &job.owner_id[..job.owner_id.len().min(12)];
    match (&result, settled) {
        (_, Err(e)) => tracing::warn!("{} {id}: could not settle: {e:#}", job.kind),
        (Ok(Outcome::Done), _) => tracing::info!("{} {id} done in {:.1?}", job.kind, started.elapsed()),
        (Ok(Outcome::NotReady), _) => {}
        (Err(e), _) => tracing::warn!("{} {id} failed: {e:#}", job.kind),
    }
}

// ------------------------------------------------------------------- embed ---

async fn embed(worker: &Worker, job: &Job) -> Result<Outcome> {
    let id = &job.owner_id;
    let c = worker.pool.get().await?;
    let row = c
        .query_opt("SELECT type, orig_path FROM assets WHERE id = $1", &[id])
        .await?
        .context("asset is gone")?;
    drop(c);
    let is_video = row.get::<_, &str>(0) == "video";
    let original = std::path::PathBuf::from(row.get::<_, String>(1));

    // a clip is embedded from its frames, never from its poster: a video
    // whose original cannot be read fails visibly instead of being indexed
    // as a still
    let clip = if is_video {
        anyhow::ensure!(original.exists(), "the original is missing: {}", original.display());
        worker.embedder.embed_video(&original).await?
    } else {
        None
    };
    let vec = match clip {
        Some(vec) => vec,
        // a still, or a "clip" of a single frame
        None => {
            let Some(thumb) = worker.cfg.thumb(id) else { return Ok(Outcome::NotReady) };
            let image = tokio::task::spawn_blocking(move || pixels::open(&thumb)).await??;
            worker.embedder.embed_image(&image).await?
        }
    };

    let c = worker.pool.get().await?;
    c.execute(
        "INSERT INTO embeddings (owner_type, owner_id, model, vec, updated_at)
         VALUES ('asset', $1, $2, $3, now())
         ON CONFLICT (owner_type, owner_id, model)
         DO UPDATE SET vec = EXCLUDED.vec, updated_at = now()",
        &[id, &atlas_core::EMBED_MODEL, &Vector::from(vec)],
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
