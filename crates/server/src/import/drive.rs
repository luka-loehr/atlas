//! Google Takeout drive -> the drive.
//!
//!   atlas-server import drive ~/takeout/drive/*.zip
//!
//! Mirrors the `Takeout/Drive/` tree into folders and files, storing each
//! file's bytes once under its SHA-256. Modification times come from the
//! archive entries. Re-running skips rows that already carry the same
//! content and updates rows whose content changed. Drive allows two files of
//! one name in a folder; the second and later become "name (2).ext".

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::path::PathBuf;

use anyhow::{Context, Result};
use atlas_core::queue;
use chrono::{DateTime, NaiveDate, Utc};
use deadpool_postgres::Pool;
use zip::ZipArchive;

use super::extract_hashed;
use crate::{Config, drive::mime_for};

const PREFIX: &str = "Takeout/Drive/";

pub async fn run(cfg: &Config, pool: &Pool, paths: &[PathBuf]) -> Result<()> {
    anyhow::ensure!(!paths.is_empty(), "no archives given");
    let blobs = cfg.blobs_dir();
    let incoming = blobs.join(".incoming");
    let c = pool.get().await?;
    let mut folders: HashMap<(Option<i64>, String), i64> = HashMap::new();
    let mut seen: HashSet<(Option<i64>, String)> = HashSet::new();
    let (mut added, mut updated, mut unchanged) = (0usize, 0usize, 0usize);

    for path in paths {
        let file = File::open(path).with_context(|| format!("cannot open {}", path.display()))?;
        let mut archive = ZipArchive::new(file).with_context(|| format!("{} is not a complete zip", path.display()))?;
        let entries: Vec<usize> = (0..archive.len())
            .filter(|&i| archive.by_index_raw(i).is_ok_and(|e| !e.is_dir() && e.name().starts_with(PREFIX)))
            .collect();
        println!("{}: {} files", path.display(), entries.len());

        for (n, index) in entries.iter().enumerate() {
            let (relative, modified, extracted) = tokio::task::block_in_place(|| -> Result<_> {
                let mut entry = archive.by_index(*index)?;
                let relative = entry.name()[PREFIX.len()..].to_string();
                let modified = entry.last_modified().and_then(|t| {
                    NaiveDate::from_ymd_opt(i32::from(t.year()), u32::from(t.month()), u32::from(t.day()))?
                        .and_hms_opt(u32::from(t.hour()), u32::from(t.minute()), u32::from(t.second()))
                });
                Ok((relative, modified, extract_hashed(&mut entry, &incoming)?))
            })?;
            let (tmp, hash, size) = extracted;
            let modified: DateTime<Utc> = modified.map(|m| m.and_utc()).unwrap_or_else(Utc::now);

            let dest = blobs.join(&hash);
            if dest.exists() {
                std::fs::remove_file(&tmp)?;
            } else {
                std::fs::rename(&tmp, &dest)?;
            }

            let mut parts: Vec<&str> = relative.split('/').collect();
            let mut name = parts.pop().unwrap_or("file").to_string();
            let mut folder: Option<i64> = None;
            for part in parts {
                let key = (folder, part.to_string());
                folder = Some(match folders.get(&key) {
                    Some(id) => *id,
                    None => {
                        let row = c
                            .query_one(
                                "INSERT INTO drive_folders (parent_id, name) VALUES ($1, $2)
                                 ON CONFLICT (parent_id, name) DO UPDATE SET name = EXCLUDED.name
                                 RETURNING id",
                                &[&folder, &part],
                            )
                            .await?;
                        folders.insert(key, row.get(0));
                        row.get(0)
                    }
                });
            }

            // a second file of the same name in this run gets a counter
            let (stem, ext) = match name.rsplit_once('.') {
                Some((stem, ext)) => (stem.to_string(), format!(".{ext}")),
                None => (name.clone(), String::new()),
            };
            let mut counter = 2;
            while !seen.insert((folder, name.clone())) {
                name = format!("{stem} ({counter}){ext}");
                counter += 1;
            }

            let existing = c
                .query_opt(
                    "SELECT id, hash FROM drive_files
                     WHERE folder_id IS NOT DISTINCT FROM $1 AND name = $2 AND trashed_at IS NULL",
                    &[&folder, &name],
                )
                .await?;
            let mime = mime_for(&name);
            let size = size as i64;
            let changed = match existing {
                None => {
                    let row = c
                        .query_one(
                            "INSERT INTO drive_files (folder_id, name, hash, size_bytes, mime, modified_at, source)
                             VALUES ($1, $2, $3, $4, $5, $6, 'takeout') RETURNING id",
                            &[&folder, &name, &hash, &size, &mime, &modified],
                        )
                        .await?;
                    added += 1;
                    Some(row.get::<_, i64>(0))
                }
                Some(row) if row.get::<_, String>(1) != hash => {
                    let id: i64 = row.get(0);
                    c.execute(
                        "UPDATE drive_files SET hash = $2, size_bytes = $3, mime = $4, modified_at = $5, text = NULL
                         WHERE id = $1",
                        &[&id, &hash, &size, &mime, &modified],
                    )
                    .await?;
                    updated += 1;
                    Some(id)
                }
                Some(_) => {
                    unchanged += 1;
                    None
                }
            };
            if let Some(id) = changed {
                queue::requeue(&c, queue::DRIVE_TEXT, "drive_file", &id.to_string(), queue::PRIORITY_DEFAULT).await?;
            }
            if (n + 1) % 200 == 0 {
                println!("  {}/{}", n + 1, entries.len());
            }
        }
    }
    println!("done: {added} added, {updated} updated, {unchanged} unchanged");
    Ok(())
}
