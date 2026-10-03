//! Crash-safe job queue on top of `ingest_jobs`.
//!
//!   enqueue    ON CONFLICT (kind, owner_type, owner_id) DO NOTHING
//!   claim      one UPDATE ... FOR UPDATE SKIP LOCKED: no double claims
//!   heartbeat  every minute while a job runs
//!   done/fail  terminal transitions; fail retries with linear backoff
//!   reap       running jobs with a stale heartbeat go back to pending, so a
//!              power cut mid-job heals itself at the next start
//!
//! Every call is one small statement on an autocommit connection.

use std::time::Duration;

use tokio_postgres::{Client, Error};

pub const MAX_ATTEMPTS: i32 = 5;

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

/// Enqueue, or put a finished/failed job back in line (a forced re-run).
pub async fn requeue(c: &Client, kind: &str, owner_type: &str, owner_id: &str, priority: i32) -> Result<(), Error> {
    c.execute(
        "INSERT INTO ingest_jobs (kind, owner_type, owner_id, priority)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (kind, owner_type, owner_id) DO UPDATE
             SET status = 'pending', attempts = 0, error = NULL, run_after = now(),
                 locked_by = NULL, heartbeat_at = NULL, priority = EXCLUDED.priority,
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
          RETURNING id, kind, owner_id",
            &[&worker, &kinds, &limit],
        )
        .await?;
    Ok(rows.iter().map(|r| Job { id: r.get(0), kind: r.get(1), owner_id: r.get(2) }).collect())
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

/// One more attempt used; after MAX_ATTEMPTS the job is failed for good,
/// until then it waits `attempts * 5 min`.
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
pub async fn defer(c: &Client, id: i64, delay: Duration, note: Option<&str>) -> Result<(), Error> {
    c.execute(
        "UPDATE ingest_jobs
            SET status = 'pending', error = $3, run_after = now() + $2 * interval '1 second',
                locked_by = NULL, heartbeat_at = NULL, updated_at = now()
          WHERE id = $1",
        &[&id, &(delay.as_secs_f64()), &note],
    )
    .await?;
    Ok(())
}

/// Requeue running jobs whose heartbeat is over ten minutes old.
pub async fn reap(c: &Client) -> Result<u64, Error> {
    c.execute(
        "UPDATE ingest_jobs
            SET status = 'pending', locked_by = NULL, updated_at = now()
          WHERE status = 'running'
            AND (heartbeat_at IS NULL OR heartbeat_at < now() - interval '10 minutes')",
        &[],
    )
    .await
}
