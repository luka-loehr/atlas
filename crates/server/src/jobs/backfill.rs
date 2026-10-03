//! One-off repair passes. Each one only puts jobs (back) in the queue; the
//! running server does the work, so a pass is safe to repeat and to
//! interrupt.

use anyhow::Result;
use atlas_core::queue;
use clap::Subcommand;
use deadpool_postgres::Pool;

use crate::Config;

#[derive(Subcommand)]
pub enum Kind {
    /// Thumbnails and placeholder hashes for assets that lack one
    Thumbs,
    /// Capture dates for undated assets (container tags, then filenames)
    /// and the local-time offset of photos that lack one
    Dates,
    /// Streaming renditions for every video that needs one
    Previews,
    /// Search text for drive files that were never extracted
    DriveText,
    /// Embeddings for assets that have none
    Embeddings,
    /// Face detection for assets it never ran on
    Faces,
}

pub async fn run(_cfg: &Config, pool: &Pool, what: Kind) -> Result<()> {
    let (kind, owner_type, select, priority) = match what {
        Kind::Thumbs => (
            queue::THUMB,
            "asset",
            "SELECT id FROM assets WHERE thumbhash IS NULL OR width IS NULL",
            queue::PRIORITY_DEFAULT + 100,
        ),
        Kind::Dates => (queue::META, "asset", "SELECT id FROM assets WHERE taken_at IS NULL OR tz_offset_s IS NULL", queue::PRIORITY_DEFAULT),
        Kind::Previews => (
            queue::PREVIEW,
            "asset",
            "SELECT id FROM assets WHERE type = 'video' AND preview_at IS NULL AND trashed_at IS NULL",
            queue::PRIORITY_BACKGROUND,
        ),
        Kind::DriveText => (
            queue::DRIVE_TEXT,
            "drive_file",
            "SELECT id::text FROM drive_files WHERE text IS NULL",
            queue::PRIORITY_DEFAULT,
        ),
        Kind::Embeddings => (
            queue::EMBED,
            "asset",
            "SELECT id FROM assets a WHERE NOT EXISTS
               (SELECT 1 FROM embeddings e WHERE e.owner_type = 'asset' AND e.owner_id = a.id)",
            queue::PRIORITY_DEFAULT,
        ),
        Kind::Faces => (
            queue::FACES,
            "asset",
            "SELECT id FROM assets a WHERE type = 'photo' AND NOT EXISTS
               (SELECT 1 FROM ingest_jobs j WHERE j.kind = 'faces' AND j.owner_id = a.id AND j.status = 'done')",
            queue::PRIORITY_DEFAULT,
        ),
    };
    let c = pool.get().await?;
    let queued = c
        .execute(
            &format!(
                "INSERT INTO ingest_jobs (kind, owner_type, owner_id, priority)
                 SELECT $1, $2, owner.id, $3 FROM ({select}) AS owner(id)
                 ON CONFLICT (kind, owner_type, owner_id) DO UPDATE
                     SET status = 'pending', attempts = 0, error = NULL, run_after = now(),
                         locked_by = NULL, heartbeat_at = NULL, priority = EXCLUDED.priority,
                         updated_at = now()
                   WHERE ingest_jobs.status <> 'running'"
            ),
            &[&kind, &owner_type, &priority],
        )
        .await?;
    println!("{queued} {kind} jobs queued");
    Ok(())
}
