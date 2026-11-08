//! The model stages of the job queue: `embed` and `faces` (the vision
//! stage: faces, animals, text; vision/).
//!
//! Two loops side by side: embeddings, as many at once as the embedding
//! server has slots to spare for the queue, and vision, a few assets
//! prepared at once (originals decoded, video frames read) while one at a
//! time is on the GPU. Both work from the 2048px thumbnail the server's workers
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

use crate::{Worker, pixels, vision};

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

/// How a model job went, short of failing.
pub enum Outcome {
    Done,
    /// the thumbnail (or original) this stage reads is not there yet
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
        vision_loop(worker, running),
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
async fn next_job(
    worker: &Worker,
    name: &str,
    kind: &str,
    notifications: &mut tokio::sync::mpsc::UnboundedReceiver<&'static str>,
) -> Option<Job> {
    let claimed = match worker.pool.get().await {
        Ok(c) => queue::claim(&c, name, &[kind], 1)
            .await
            .map_err(anyhow::Error::from),
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
        let Some(job) = next_job(&worker, &name, queue::EMBED, &mut notifications).await else {
            continue;
        };
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

async fn vision_loop(worker: Arc<Worker>, running: Running) {
    let name = worker_name("faces");
    let mut notifications = atlas_core::db::listen(&["atlas_jobs"]);
    let engines: vision::Shared = Arc::default();
    let slots = Arc::new(Semaphore::new(worker.cfg.vision_jobs));
    loop {
        let slot = slots.clone().acquire_owned().await.expect("semaphore open");
        let Some(job) = next_job(&worker, &name, queue::FACES, &mut notifications).await else {
            // nothing to do: once every job in hand is finished, the models'
            // memory (GPU and RAM) goes back
            drop(slot);
            if slots.available_permits() == worker.cfg.vision_jobs {
                *engines.lock().unwrap_or_else(|e| e.into_inner()) = vision::Loaded::default();
            }
            continue;
        };
        running.lock().unwrap().insert(job.id);
        let (worker, running, engines) = (worker.clone(), running.clone(), engines.clone());
        tokio::spawn(async move {
            let started = Instant::now();
            let result = vision::run(&worker, &engines, &job.owner_id).await;
            settle(&worker, &job, result, started).await;
            running.lock().unwrap().remove(&job.id);
            drop(slot);
        });
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
    match thumb
        .as_ref()
        .map(|r| (r.get::<_, String>(0), r.get::<_, Option<String>>(1)))
    {
        Some((status, error)) if status == "failed" || status == "stuck" => {
            queue::stick(
                c,
                job.id,
                &format!("its thumbnail failed: {}", error.unwrap_or_default()),
            )
            .await
        }
        _ if job.defers >= queue::MAX_DEFERS => {
            queue::stick(c, job.id, "no thumbnail after an hour of waiting").await
        }
        None => {
            queue::enqueue(
                c,
                queue::THUMB,
                "asset",
                &job.owner_id,
                queue::PRIORITY_DEFAULT,
            )
            .await?;
            queue::defer(
                c,
                job.id,
                NOT_READY,
                Some("no thumbnail yet; its job was missing and is queued"),
            )
            .await
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
        (Ok(Outcome::Done), _) => {
            tracing::info!("{} {id} done in {:.1?}", job.kind, started.elapsed())
        }
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
        anyhow::ensure!(
            original.exists(),
            "the original is missing: {}",
            original.display()
        );
        worker.embedder.embed_video(&original).await?
    } else {
        None
    };
    let vec = match clip {
        Some(vec) => vec,
        // a still, or a "clip" of a single frame
        None => {
            let Some(thumb) = worker.cfg.thumb(id) else {
                return Ok(Outcome::NotReady);
            };
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
