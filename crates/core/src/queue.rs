//! Crash-safe, self-healing job queue on top of `ingest_jobs`.
//!
//!   enqueue    ON CONFLICT (kind, owner_type, owner_id) DO NOTHING
//!   ensure     enqueue, or revive a failed/stuck job whose input is back
//!   claim      one UPDATE ... FOR UPDATE SKIP LOCKED: no double claims
//!   heartbeat  every minute while a job runs
//!   done/fail  terminal transitions; fail retries with linear backoff
//!   defer      input not there yet: back in line without spending an attempt
//!   stick      parked as 'stuck' with its reason; nothing waits on it
//!   recover    at start, the jobs a crashed predecessor held go back
//!   release    at shutdown, held jobs go back as they were
//!   reap       running jobs with a stale heartbeat go back
//!   heal       failed jobs get fresh attempts later; for good: 'stuck'
//!
//! No job can hold up another: claims skip what is locked, a job that
//! crashes or hangs its worker spends an attempt each time, and whatever
//! keeps failing ends as a 'stuck' row instead of being retried forever.
//! Every call is one small statement on an autocommit connection.

use std::time::Duration;

use tokio_postgres::{Client, Error};

pub const MAX_ATTEMPTS: i32 = 5;
/// Times the healer gives a failed job a new set of attempts (spaced
/// [`HEAL_AFTER`] apart) before it is parked as stuck.
pub const MAX_HEALS: i32 = 3;
pub const HEAL_AFTER: Duration = Duration::from_secs(6 * 3600);
/// A job deferred this often (about an hour at one try a minute) waits for
/// something that is not coming.
pub const MAX_DEFERS: i32 = 60;

/// CPU stages, run inside atlas-server.
pub const THUMB: &str = "thumb";
pub const META: &str = "meta";
pub const GEOCODE: &str = "geocode";
pub const EVENT_SCAN: &str = "event_scan";
pub const DRIVE_TEXT: &str = "drive_text";
pub const PREVIEW: &str = "preview";
/// Model stages, run by atlas-ml.
pub const EMBED: &str = "embed";
pub const FACES: &str = "faces";
/// Every kind some worker runs; a pending job of any other kind is parked.
pub const KINDS: &[&str] = &[THUMB, META, GEOCODE, DRIVE_TEXT, PREVIEW, EMBED, FACES];

/// A fresh upload jumps the backlog: the grid should show it within a second.
pub const PRIORITY_INTERACTIVE: i32 = 10;
pub const PRIORITY_DEFAULT: i32 = 100;
/// Video renditions take minutes each and nothing waits on them.
pub const PRIORITY_BACKGROUND: i32 = 500;

#[derive(Debug, Clone)]
pub struct Job {
    pub id: i64,
    pub kind: String,
    pub owner_id: String,
    pub priority: i32,
    /// times it was deferred so far
    pub defers: i32,
}

pub async fn enqueue(c: &Client, kind: &str, owner_type: &str, owner_id: &str, priority: i32) -> Result<(), Error> {
    c.execute(
        "INSERT INTO ingest_jobs (kind, owner_type, owner_id, priority)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (kind, owner_type, owner_id) DO NOTHING",
        &[&kind, &owner_type, &owner_id, &priority],
    )
    .await?;
    Ok(())
}

/// Enqueue, or give a failed or stuck job a fresh start: what it was
/// waiting for is there now. Done, pending and running jobs are left alone.
pub async fn ensure(c: &Client, kind: &str, owner_type: &str, owner_id: &str, priority: i32) -> Result<(), Error> {
    c.execute(
        "INSERT INTO ingest_jobs (kind, owner_type, owner_id, priority)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (kind, owner_type, owner_id) DO UPDATE
             SET status = 'pending', attempts = 0, defers = 0, heals = 0, error = NULL, stuck_at = NULL,
                 run_after = now(), priority = EXCLUDED.priority, updated_at = now()
           WHERE ingest_jobs.status IN ('failed', 'stuck')",
        &[&kind, &owner_type, &owner_id, &priority],
    )
    .await?;
    Ok(())
}

/// Enqueue, or put a finished/failed job back in line (a forced re-run).
pub async fn requeue(c: &Client, kind: &str, owner_type: &str, owner_id: &str, priority: i32) -> Result<(), Error> {
    c.execute(
        "INSERT INTO ingest_jobs (kind, owner_type, owner_id, priority)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (kind, owner_type, owner_id) DO UPDATE
             SET status = 'pending', attempts = 0, defers = 0, heals = 0, error = NULL, stuck_at = NULL,
                 run_after = now(), locked_by = NULL, heartbeat_at = NULL, priority = EXCLUDED.priority,
                 updated_at = now()
           WHERE ingest_jobs.status <> 'running'",
        &[&kind, &owner_type, &owner_id, &priority],
    )
    .await?;
    Ok(())
}

pub async fn claim(c: &Client, worker: &str, kinds: &[&str], limit: i64) -> Result<Vec<Job>, Error> {
    let rows = c
        .query(
            "UPDATE ingest_jobs
                SET status = 'running', locked_by = $1, heartbeat_at = now(), updated_at = now()
              WHERE id IN (SELECT id FROM ingest_jobs
                            WHERE status = 'pending' AND kind = ANY($2) AND run_after <= now()
                            ORDER BY priority, id
                            LIMIT $3
                            FOR UPDATE SKIP LOCKED)
          RETURNING id, kind, owner_id, priority, defers",
            &[&worker, &kinds, &limit],
        )
        .await?;
    Ok(rows
        .iter()
        .map(|r| Job { id: r.get(0), kind: r.get(1), owner_id: r.get(2), priority: r.get(3), defers: r.get(4) })
        .collect())
}

pub async fn heartbeat(c: &Client, ids: &[i64]) -> Result<(), Error> {
    if !ids.is_empty() {
        c.execute(
            "UPDATE ingest_jobs SET heartbeat_at = now(), updated_at = now()
              WHERE id = ANY($1) AND status = 'running'",
            &[&ids],
        )
        .await?;
    }
    Ok(())
}

pub async fn done(c: &Client, id: i64) -> Result<(), Error> {
    c.execute(
        "UPDATE ingest_jobs
            SET status = 'done', error = NULL, locked_by = NULL, heartbeat_at = NULL, updated_at = now()
          WHERE id = $1",
        &[&id],
    )
    .await?;
    Ok(())
}

/// One more attempt used; after MAX_ATTEMPTS the job is failed (the healer
/// tries it again later), until then it waits `attempts * 5 min`.
pub async fn fail(c: &Client, id: i64, err: &str) -> Result<(), Error> {
    let err: String = err.chars().take(2000).collect();
    c.execute(
        "UPDATE ingest_jobs
            SET attempts = attempts + 1, error = $2,
                status = CASE WHEN attempts + 1 >= $3 THEN 'failed' ELSE 'pending' END,
                run_after = now() + (attempts + 1) * interval '5 min',
                locked_by = NULL, heartbeat_at = NULL, updated_at = now()
          WHERE id = $1",
        &[&id, &err, &MAX_ATTEMPTS],
    )
    .await?;
    Ok(())
}

/// Back to pending without spending an attempt: the job's input is not there
/// yet (a thumbnail still being made), or it reschedules itself by design.
/// Counted, so a job waiting for something that never comes can be told
/// apart (see [`MAX_DEFERS`]).
pub async fn defer(c: &Client, id: i64, delay: Duration, note: Option<&str>) -> Result<(), Error> {
    c.execute(
        "UPDATE ingest_jobs
            SET status = 'pending', error = $3, run_after = now() + $2 * interval '1 second',
                defers = defers + 1, locked_by = NULL, heartbeat_at = NULL, updated_at = now()
          WHERE id = $1",
        &[&id, &(delay.as_secs_f64()), &note],
    )
    .await?;
    Ok(())
}

/// Parked for good, with the reason. It blocks nothing; `ensure`,
/// `requeue` and the backfill passes bring it back.
pub async fn stick(c: &Client, id: i64, reason: &str) -> Result<(), Error> {
    let reason: String = reason.chars().take(2000).collect();
    c.execute(
        "UPDATE ingest_jobs
            SET status = 'stuck', error = $2, stuck_at = now(),
                locked_by = NULL, heartbeat_at = NULL, updated_at = now()
          WHERE id = $1",
        &[&id, &reason],
    )
    .await?;
    Ok(())
}

/// What happened to a running job whose worker is gone: one attempt spent
/// (it may be the job that took the worker down), failed once they are used up.
const LOST: &str = "attempts = attempts + 1,
                    status = CASE WHEN attempts + 1 >= $1 THEN 'failed' ELSE 'pending' END,
                    error = 'its worker stopped during the job', run_after = now(),
                    locked_by = NULL, heartbeat_at = NULL, updated_at = now()";

/// At start: running jobs of an earlier process of this kind of worker
/// (`locked_by` starting with `prefix`) are what a crash left behind.
pub async fn recover(c: &Client, prefix: &str) -> Result<u64, Error> {
    c.execute(
        &format!("UPDATE ingest_jobs SET {LOST} WHERE status = 'running' AND starts_with(locked_by, $2)"),
        &[&MAX_ATTEMPTS, &prefix],
    )
    .await
}

/// At a clean shutdown: the jobs this worker holds go back as they were,
/// without spending an attempt.
pub async fn release(c: &Client, worker: &str) -> Result<u64, Error> {
    c.execute(
        "UPDATE ingest_jobs
            SET status = 'pending', locked_by = NULL, heartbeat_at = NULL, run_after = now(), updated_at = now()
          WHERE status = 'running' AND locked_by = $1",
        &[&worker],
    )
    .await
}

/// Running jobs whose heartbeat is over ten minutes old go back.
pub async fn reap(c: &Client) -> Result<u64, Error> {
    c.execute(
        &format!(
            "UPDATE ingest_jobs SET {LOST}
              WHERE status = 'running'
                AND (heartbeat_at IS NULL OR heartbeat_at < now() - interval '10 minutes')"
        ),
        &[&MAX_ATTEMPTS],
    )
    .await
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Healed {
    /// failed jobs given a new set of attempts
    pub retried: u64,
    /// failed for good, or of a kind no worker runs: parked as stuck
    pub stuck: u64,
}

/// The periodic check-up: failed jobs get a new set of attempts once
/// [`HEAL_AFTER`] has passed (the cause may be gone: a tool installed, a
/// disk back), up to [`MAX_HEALS`] times; then they are parked as stuck.
/// Pending jobs no worker can run are parked right away.
pub async fn heal(c: &Client) -> Result<Healed, Error> {
    let retried = c
        .execute(
            "UPDATE ingest_jobs
                SET status = 'pending', attempts = 0, defers = 0, heals = heals + 1,
                    run_after = now(), updated_at = now()
              WHERE status = 'failed' AND heals < $1 AND updated_at < now() - $2 * interval '1 second'",
            &[&MAX_HEALS, &(HEAL_AFTER.as_secs_f64())],
        )
        .await?;
    let gave_up = c
        .execute(
            "UPDATE ingest_jobs SET status = 'stuck', stuck_at = now(), updated_at = now()
              WHERE status = 'failed' AND heals >= $1",
            &[&MAX_HEALS],
        )
        .await?;
    let kinds: Vec<&str> = KINDS.to_vec();
    let orphans = c
        .execute(
            "UPDATE ingest_jobs
                SET status = 'stuck', stuck_at = now(), updated_at = now(),
                    error = 'no worker runs jobs of this kind'
              WHERE status = 'pending' AND kind <> ALL($1)",
            &[&kinds],
        )
        .await?;
    Ok(Healed { retried, stuck: gave_up + orphans })
}
