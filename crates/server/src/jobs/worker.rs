//! The worker loops: claim a job, run it, settle it.
//!
//! Two pools drain the queue. The CPU pool runs thumbnails, metadata,
//! geocoding and drive text with as many jobs in parallel as configured; the
//! rendition pool transcodes one video at a time, because the hardware
//! encoder is one device. Idle loops wake the moment Postgres announces a
//! new job.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use atlas_core::queue::{self, Job};
use tokio::sync::Semaphore;

use super::{drive_text, geocode, meta, preview, thumb};
use crate::AppState;

const CPU_KINDS: &[&str] = &[queue::THUMB, queue::META, queue::GEOCODE, queue::DRIVE_TEXT];
const IDLE_POLL: Duration = Duration::from_secs(30);
const REAP_EVERY: Duration = Duration::from_secs(300);

pub fn spawn(app: AppState) {
    if app.cfg.workers == 0 {
        tracing::info!("ingest workers are off (ATLAS_WORKERS=0)");
        return;
    }
    let running = Arc::new(Mutex::new(HashSet::new()));
    tokio::spawn(heartbeat(app.clone(), running.clone()));
    tokio::spawn(drain(app.clone(), CPU_KINDS, app.cfg.workers, running.clone()));
    if app.cfg.video_previews {
        tokio::spawn(drain(app, &[queue::PREVIEW], 1, running));
    }
}

/// Keep claimed jobs marked alive, and put jobs of crashed workers back.
async fn heartbeat(app: AppState, running: Arc<Mutex<HashSet<i64>>>) {
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

async fn drain(app: AppState, kinds: &'static [&'static str], parallel: usize, running: Arc<Mutex<HashSet<i64>>>) {
    let worker = format!("server:{}:{}", crate::system::metrics::hostname(), std::process::id());
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
    let result = match job.kind.as_str() {
        queue::THUMB => thumb::run(app, &job.owner_id).await,
        queue::META => meta::run(app, &job.owner_id).await,
        queue::GEOCODE => geocode::run(app, &job.owner_id).await,
        queue::DRIVE_TEXT => drive_text::run(app, &job.owner_id).await,
        queue::PREVIEW => preview::run(app, &job.owner_id).await,
        other => Err(anyhow::anyhow!("no handler for job kind {other}")),
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
        (Ok(()), _) => tracing::info!("{} {} done in {elapsed:.0?}", job.kind, short(&job.owner_id)),
        (Err(e), _) => tracing::warn!("{} {} failed after {elapsed:.0?}: {e:#}", job.kind, short(&job.owner_id)),
    }
}

fn short(id: &str) -> &str {
    &id[..id.len().min(12)]
}
