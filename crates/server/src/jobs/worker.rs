//! The worker loops: claim a job, run it, settle it.
//!
//! Two pools drain the queue. The CPU pool runs thumbnails, metadata,
//! geocoding and drive text with as many jobs in parallel as configured; the
//! rendition pool transcodes one video at a time, because the hardware
//! encoder is one device. Idle loops wake the moment Postgres announces a
//! new job.
//!
//! Nothing stays stuck: every job has a time limit, jobs a crashed
//! predecessor held are recovered at start, a clean shutdown hands its jobs
//! back, and an hourly check-up (`heal`) repairs the rest.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use atlas_core::queue::{self, Job};
use tokio::sync::Semaphore;

use super::{drive_text, geocode, heal, meta, preview, thumb};
use crate::AppState;

const CPU_KINDS: &[&str] = &[queue::THUMB, queue::META, queue::GEOCODE, queue::DRIVE_TEXT];
const IDLE_POLL: Duration = Duration::from_secs(30);
const REAP_EVERY: Duration = Duration::from_secs(300);
const HEAL_EVERY: Duration = Duration::from_secs(3600);
const PREFIX: &str = "server:";

/// How long a job may take before its attempt counts as failed (its tools
/// have deadlines of their own, see `atlas_core::process`).
fn limit(kind: &str) -> Duration {
    Duration::from_secs(match kind {
        queue::THUMB => 15 * 60,
        queue::META => 5 * 60,
        queue::GEOCODE => 2 * 60,
        queue::DRIVE_TEXT => 30 * 60,
        // three encoder attempts of up to four hours each
        queue::PREVIEW => 13 * 3600,
        _ => 30 * 60,
    })
}

/// This process in `locked_by`.
pub fn worker_name() -> String {
    format!("{PREFIX}{}:{}", crate::system::metrics::hostname(), std::process::id())
}

/// At a clean shutdown: the jobs this process holds go back to the queue
/// unspent, so the next start picks them up at once.
pub async fn release(app: &AppState) {
    if let Ok(c) = app.pool.get().await
        && let Ok(n) = queue::release(&c, &worker_name()).await
        && n > 0
    {
        tracing::info!("handed {n} running jobs back to the queue");
    }
}

pub fn spawn(app: AppState) {
    if app.cfg.workers == 0 {
        tracing::info!("ingest workers are off (ATLAS_WORKERS=0)");
        return;
    }
    let running = Arc::new(Mutex::new(HashSet::new()));
    tokio::spawn(heartbeat(app.clone(), running.clone()));
    tokio::spawn(checkups(app.clone()));
    tokio::spawn(drain(app.clone(), CPU_KINDS, app.cfg.workers, running.clone()));
    if app.cfg.video_previews {
        tokio::spawn(drain(app, &[queue::PREVIEW], 1, running));
    }
}

/// Keep claimed jobs marked alive, and put jobs of crashed workers back.
async fn heartbeat(app: AppState, running: Arc<Mutex<HashSet<i64>>>) {
    // what an earlier process of ours held when it went down
    if let Ok(c) = app.pool.get().await {
        match queue::recover(&c, PREFIX).await {
            Ok(0) => {}
            Ok(n) => {
                tracing::warn!("recovered {n} jobs a stopped atlas-server left running");
                app.jobs_wake.notify_waiters();
            }
            Err(e) => tracing::warn!("could not recover jobs: {e:#}"),
        }
    }
    let mut last_reap: Option<Instant> = None;
    loop {
        if let Ok(c) = app.pool.get().await {
            if last_reap.is_none_or(|t| t.elapsed() >= REAP_EVERY) {
                match queue::reap(&c).await {
                    Ok(n) if n > 0 => {
                        tracing::info!("requeued {n} stale jobs");
                        app.jobs_wake.notify_waiters();
                    }
                    _ => {}
                }
                last_reap = Some(Instant::now());
            }
            let ids: Vec<i64> = running.lock().unwrap().iter().copied().collect();
            let _ = queue::heartbeat(&c, &ids).await;
        }
        tokio::time::sleep(Duration::from_secs(60)).await;
    }
}

/// The hourly check-up (`heal`), the first a minute after start.
async fn checkups(app: AppState) {
    tokio::time::sleep(Duration::from_secs(60)).await;
    loop {
        match heal::run(&app).await {
            Ok(r) if r.dropped + r.queued + r.healed.retried + r.healed.stuck == 0 => {}
            Ok(r) => tracing::info!(
                "check-up: {} jobs queued that were missing, {} without an owner dropped, {} failed retried, {} parked as stuck",
                r.queued, r.dropped, r.healed.retried, r.healed.stuck
            ),
            Err(e) => tracing::warn!("check-up failed: {e:#}"),
        }
        tokio::time::sleep(HEAL_EVERY).await;
    }
}

async fn drain(app: AppState, kinds: &'static [&'static str], parallel: usize, running: Arc<Mutex<HashSet<i64>>>) {
    let worker = worker_name();
    let slots = Arc::new(Semaphore::new(parallel));
    loop {
        let slot = slots.clone().acquire_owned().await.expect("semaphore open");
        // register for the wake-up before looking, so a job enqueued in
        // between is not slept through
        let woken = app.jobs_wake.notified();
        let claimed = match app.pool.get().await {
            Ok(c) => queue::claim(&c, &worker, kinds, 1).await.map_err(anyhow::Error::from),
            Err(e) => Err(e.into()),
        };
        match claimed {
            Ok(mut jobs) if !jobs.is_empty() => {
                let job = jobs.remove(0);
                running.lock().unwrap().insert(job.id);
                let (app, running) = (app.clone(), running.clone());
                tokio::spawn(async move {
                    execute(&app, &job).await;
                    running.lock().unwrap().remove(&job.id);
                    drop(slot);
                });
            }
            Ok(_) => {
                drop(slot);
                tokio::select! {
                    _ = woken => {}
                    _ = tokio::time::sleep(IDLE_POLL) => {}
                }
            }
            Err(e) => {
                drop(slot);
                tracing::warn!("queue unavailable: {e:#}");
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        }
    }
}

async fn execute(app: &AppState, job: &Job) {
    let started = Instant::now();
    let work = async {
        match job.kind.as_str() {
            queue::THUMB => thumb::run(app, &job.owner_id, job.priority).await,
            queue::META => meta::run(app, &job.owner_id).await,
            queue::GEOCODE => geocode::run(app, &job.owner_id).await,
            queue::DRIVE_TEXT => drive_text::run(app, &job.owner_id).await,
            queue::PREVIEW => preview::run(app, &job.owner_id).await,
            other => Err(anyhow::anyhow!("no handler for job kind {other}")),
        }
    };
    let limit = limit(&job.kind);
    let result = match tokio::time::timeout(limit, work).await {
        Ok(result) => result,
        Err(_) => Err(anyhow::anyhow!("took longer than {limit:?}")),
    };
    let elapsed = started.elapsed();
    let settled = async {
        let c = app.pool.get().await?;
        match &result {
            Ok(()) => queue::done(&c, job.id).await?,
            Err(e) => queue::fail(&c, job.id, &format!("{e:#}")).await?,
        }
        anyhow::Ok(())
    }
    .await;
    match (&result, settled) {
        (_, Err(e)) => tracing::warn!("{} {}: could not settle: {e:#}", job.kind, job.owner_id),
        (Ok(()), _) => tracing::info!("{} {} done in {elapsed:.1?}", job.kind, short(&job.owner_id)),
        (Err(e), _) => tracing::warn!("{} {} failed after {elapsed:.1?}: {e:#}", job.kind, short(&job.owner_id)),
    }
}

fn short(id: &str) -> &str {
    &id[..id.len().min(12)]
}
