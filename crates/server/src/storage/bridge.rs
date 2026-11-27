//! Bidirectional synchronization between the unified `objects` catalog and the
//! domain-specific `assets` (`media` bucket) and `drive_folders`/`drive_files`
//! (`files` bucket) tables.

use std::path::Path;

use atlas_core::queue;
use chrono::{DateTime, Utc};
use tokio_postgres::Client;

use crate::drive::mime_for;
use crate::{ApiResult, App, util};

/// Computes the canonical `files` bucket key for `(folder_id, name)`.
pub async fn drive_key_for(c: &Client, folder_id: Option<i64>, name: &str) -> ApiResult<String> {
    let clean_file = name.trim_matches('/').replace('/', "-");
    let Some(fid) = folder_id else {
        return Ok(clean_file);
    };
    let rows = c
        .query(
            "WITH RECURSIVE up AS (
                 SELECT id, parent_id, name, 0 AS depth FROM drive_folders WHERE id = $1
               UNION ALL
                 SELECT f.id, f.parent_id, f.name, up.depth + 1
                 FROM drive_folders f JOIN up ON f.id = up.parent_id
             )
             SELECT name FROM up ORDER BY depth DESC",
            &[&fid],
        )
        .await?;
    let mut parts: Vec<String> = rows
        .iter()
        .map(|r| r.get::<_, String>(0).trim_matches('/').replace('/', "-"))
        .filter(|s| !s.is_empty())
        .collect();
    parts.push(clean_file);
    Ok(parts.join("/"))
}

/// Ensures every folder component of `key` (`a/b/c.pdf` -> folders `a`, `b`) exists
/// in `drive_folders`, and upserts the corresponding `drive_files` row, returning its `id`.
pub async fn sync_files_object_to_drive(
    app: &App,
    key: &str,
    sha256: &str,
    size_bytes: i64,
    content_type: &str,
    modified_at: DateTime<Utc>,
) -> ApiResult<Option<i64>> {
    if key.ends_with('/') {
        return Ok(None);
    }
    let segments: Vec<&str> = key.split('/').filter(|s| !s.is_empty()).collect();
    let Some((&file_name, folder_segs)) = segments.split_last() else {
        return Ok(None);
    };

    let c = app.pool.get().await?;
    let mut parent_id: Option<i64> = None;
    for seg in folder_segs {
        let row = c
            .query_one(
                "INSERT INTO drive_folders (parent_id, name)
                 VALUES ($1, $2)
                 ON CONFLICT (parent_id, name) DO UPDATE SET name = EXCLUDED.name
                 RETURNING id",
                &[&parent_id, &seg],
            )
            .await?;
        parent_id = Some(row.get(0));
    }

    let mime = if content_type == "application/octet-stream" {
        mime_for(file_name)
    } else {
        content_type
    };

    let existing = c
        .query_opt(
            "SELECT id FROM drive_files
              WHERE folder_id IS NOT DISTINCT FROM $1 AND name = $2 AND trashed_at IS NULL",
            &[&parent_id, &file_name],
        )
        .await?;

    let id: i64 = match existing {
        Some(r) => {
            let id: i64 = r.get(0);
            c.execute(
                "UPDATE drive_files
                    SET hash = $2, size_bytes = $3, mime = $4, modified_at = $5, source = 's3', text = NULL
                  WHERE id = $1",
                &[&id, &sha256, &size_bytes, &mime, &modified_at],
            )
            .await?;
            id
        }
        None => {
            c.query_one(
                "INSERT INTO drive_files (folder_id, name, hash, size_bytes, mime, modified_at, source)
                 VALUES ($1, $2, $3, $4, $5, $6, 's3')
                 RETURNING id",
                &[&parent_id, &file_name, &sha256, &size_bytes, &mime, &modified_at],
            )
            .await?
            .get(0)
        }
    };

    queue::requeue(
        &c,
        queue::DRIVE_TEXT,
        "drive_file",
        &id.to_string(),
        queue::PRIORITY_INTERACTIVE,
    )
    .await?;
    drop(c);
    app.jobs_wake.notify_waiters();
    Ok(Some(id))
}

/// Syncs a `/v1/drive` mutation (upload/rename/move) into `objects` (`bucket = 'files'`).
pub async fn sync_drive_file_to_objects(app: &App, drive_file_id: i64) -> ApiResult<()> {
    let c = app.pool.get().await?;
    let Some(r) = c
        .query_opt(
            "SELECT folder_id, name, hash, size_bytes, mime, modified_at, trashed_at
               FROM drive_files WHERE id = $1",
            &[&drive_file_id],
        )
        .await?
    else {
        c.execute(
            "DELETE FROM objects WHERE bucket = 'files' AND drive_file_id = $1",
            &[&drive_file_id],
        )
        .await?;
        return Ok(());
    };

    let folder_id: Option<i64> = r.get(0);
    let name: String = r.get(1);
    let sha256: String = r.get(2);
    let size_bytes: i64 = r.get(3);
    let mime: Option<String> = r.get(4);
    let modified_at: Option<DateTime<Utc>> = r.get(5);
    let trashed_at: Option<DateTime<Utc>> = r.get(6);

    let base_key = drive_key_for(&c, folder_id, &name).await?;
    let key = if trashed_at.is_some() {
        format!("{base_key}.trashed-{drive_file_id}")
    } else {
        base_key
    };
    let etag = format!("\"{}\"", &sha256[..sha256.len().min(32)]);
    let content_type = mime.unwrap_or_else(|| mime_for(&name).to_string());
    let updated = modified_at.unwrap_or_else(Utc::now);

    c.execute(
        "DELETE FROM objects WHERE bucket = 'files' AND drive_file_id = $1 AND key <> $2",
        &[&drive_file_id, &key],
    )
    .await?;
    c.execute(
        "INSERT INTO objects (bucket, key, sha256, etag, size_bytes, content_type, drive_file_id, trashed_at, updated_at)
         VALUES ('files', $1, $2, $3, $4, $5, $6, $7, $8)
         ON CONFLICT (bucket, key) DO UPDATE
           SET sha256 = EXCLUDED.sha256,
               etag = EXCLUDED.etag,
               size_bytes = EXCLUDED.size_bytes,
               content_type = EXCLUDED.content_type,
               drive_file_id = EXCLUDED.drive_file_id,
               trashed_at = EXCLUDED.trashed_at,
               updated_at = EXCLUDED.updated_at",
        &[
            &key,
            &sha256,
            &etag,
            &size_bytes,
            &content_type,
            &drive_file_id,
            &trashed_at,
            &updated,
        ],
    )
    .await?;
    Ok(())
}

/// Re-syncs all `drive_files` rows in `files` bucket after bulk folder rename/move/trash/restore.
pub async fn resync_drive_ids(app: &App, file_ids: &[i64]) -> ApiResult<()> {
    for &id in file_ids {
        sync_drive_file_to_objects(app, id).await?;
    }
    Ok(())
}

/// Ingests a photo or video uploaded to the `media` bucket into `assets` and queues
/// thumbnail + EXIF/embedding/vision jobs, returning `Some(asset_id)` if it is a media file.
/// Leaves `source_blob_or_temp` intact if another row needs it, or copies/moves into `originals/`.
pub async fn ingest_media_bucket_object(
    app: &App,
    key: &str,
    sha256: &str,
    size_bytes: u64,
    source_file: &Path,
    taken_at: Option<DateTime<Utc>>,
) -> ApiResult<Option<String>> {
    let file_name = key.rsplit('/').next().unwrap_or(key);
    let ext = util::media_ext(file_name);
    if ext == "bin" {
        // Non-photo/video object placed in media bucket stays as a standard blob object
        return Ok(None);
    }

    let c = app.pool.get().await?;
    if c.query_opt("SELECT 1 FROM assets WHERE id = $1", &[&sha256])
        .await?
        .is_some()
    {
        return Ok(Some(sha256.to_string()));
    }

    let month = taken_at
        .map(|t| t.format("%Y/%m").to_string())
        .unwrap_or_else(|| "0000/00".into());
    let dir = app.cfg.originals_dir().join(month);
    tokio::fs::create_dir_all(&dir).await?;
    let dest = dir.join(format!("{sha256}.{ext}"));
    if !tokio::fs::try_exists(&dest).await.unwrap_or(false) {
        // Copy if source is already in blobs_dir or hardlink/copy atomically
        if tokio::fs::hard_link(source_file, &dest).await.is_err() {
            let tmp = dir.join(util::temp_name("asset"));
            tokio::fs::copy(source_file, &tmp).await?;
            tokio::fs::rename(&tmp, &dest).await?;
        }
    }

    let kind = if util::is_video_ext(ext) {
        "video"
    } else {
        "photo"
    };
    c.execute(
        "INSERT INTO assets (id, type, taken_at, taken_src, orig_path, orig_name, size_bytes, source)
         VALUES ($1, $2, $3, $4, $5, $6, $7, 's3')
         ON CONFLICT (id) DO NOTHING",
        &[
            &sha256,
            &kind,
            &taken_at,
            &taken_at.map(|_| "upload"),
            &dest.to_string_lossy().as_ref(),
            &file_name,
            &(size_bytes as i64),
        ],
    )
    .await?;

    queue::enqueue(
        &c,
        queue::THUMB,
        "asset",
        sha256,
        queue::PRIORITY_INTERACTIVE,
    )
    .await?;
    queue::enqueue(
        &c,
        queue::META,
        "asset",
        sha256,
        queue::PRIORITY_INTERACTIVE + 10,
    )
    .await?;
    drop(c);
    app.jobs_wake.notify_waiters();
    Ok(Some(sha256.to_string()))
}

/// Projects an asset uploaded via `PUT /v1/assets` into `objects` (`bucket = 'media'`).
pub async fn sync_asset_to_media_bucket(
    app: &App,
    asset_id: &str,
    ext: &str,
    orig_name: &str,
    size_bytes: i64,
    taken_at: Option<DateTime<Utc>>,
) -> ApiResult<()> {
    let month = taken_at
        .map(|t| t.format("%Y/%m").to_string())
        .unwrap_or_else(|| "0000/00".into());
    let key = format!("{month}/{asset_id}.{ext}");
    let etag = format!("\"{}\"", &asset_id[..asset_id.len().min(32)]);
    let content_type = mime_for(&format!("x.{ext}"));
    let meta = serde_json::json!({ "original-name": orig_name });

    let c = app.pool.get().await?;
    c.execute(
        "INSERT INTO objects (bucket, key, sha256, etag, size_bytes, content_type, custom_metadata, asset_id)
         VALUES ('media', $1, $2, $3, $4, $5, $6, $2)
         ON CONFLICT (bucket, key) DO NOTHING",
        &[&key, &asset_id, &etag, &size_bytes, &content_type, &meta],
    )
    .await?;
    Ok(())
}
