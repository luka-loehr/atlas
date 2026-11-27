//! `atlas photos` — native AI search, similarity, deduplicated upload, and library views.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use atlas_common::models::MediaSearchResponse;
use atlas_common::validate::uri_encode;
use clap::{Parser, Subcommand};
use serde_json::{Value, json};

use crate::client::{AtlasClient, hash_file_sha256};
use crate::cmd::{argv_with_name, run_async};
use crate::sanitize::{format_bytes, format_i64_bytes, sanitize_for_tty};
use crate::{DIM, GREEN, RESET};

const MEDIA_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "png", "webp", "heic", "heif", "gif", "bmp", "tif", "tiff", "avif", "dng",
    "raw", "cr2", "nef", "arw", "mp4", "mov", "m4v", "mkv", "webm", "avi", "3gp",
];

#[derive(Parser)]
#[command(
    name = "atlas photos",
    about = "Search, upload, and browse the Atlas photo & video library"
)]
struct PhotosCli {
    #[command(subcommand)]
    cmd: PhotosCmd,
}

#[derive(Subcommand)]
enum PhotosCmd {
    /// Semantic & metadata search across photos and videos
    Search {
        /// Search query (natural language, person, place, OCR text)
        query: String,
        /// Maximum number of results
        #[arg(long, default_value_t = 25)]
        limit: u32,
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// Find visually similar photos/videos to an existing asset
    Similar {
        /// Asset ID (64-char SHA-256 hex)
        asset_id: String,
        /// Maximum number of results
        #[arg(long, default_value_t = 25)]
        limit: u32,
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// Walk files/directories, deduplicate by SHA-256, and upload missing media
    Upload {
        /// Files or directories to scan for images and videos
        #[arg(required = true)]
        paths: Vec<PathBuf>,
    },
    /// Download an asset's original bytes or WebP thumbnail
    Get {
        /// Asset ID
        asset_id: String,
        /// Output path (defaults to <asset_id>.bin or <asset_id>-<thumb>.webp; '-' for stdout)
        out_path: Option<PathBuf>,
        /// Download a WebP thumbnail instead of the original: 512 or 2048
        #[arg(long)]
        thumb: Option<u32>,
    },
    /// List recognized people and pets
    People {
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// List albums
    Albums {
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// Show library and storage statistics
    Stats {
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
}

pub fn run(args: &[String]) {
    let cli = PhotosCli::parse_from(argv_with_name("photos", args));
    run_async(exec(cli.cmd));
}

async fn exec(cmd: PhotosCmd) -> Result<()> {
    let client = AtlasClient::from_env()?;
    match cmd {
        PhotosCmd::Search { query, limit, json } => {
            let path = format!(
                "/v1/media/search?q={}&limit={limit}",
                uri_encode(&query, true)
            );
            let res: MediaSearchResponse = client.get_json(&path).await?;
            print_media_search(&res, json)
        }
        PhotosCmd::Similar {
            asset_id,
            limit,
            json,
        } => {
            let path = format!(
                "/v1/media/similar/{}?limit={limit}",
                uri_encode(&asset_id, true)
            );
            let res: MediaSearchResponse = client.get_json(&path).await?;
            print_media_search(&res, json)
        }
        PhotosCmd::Upload { paths } => upload_media(&client, &paths).await,
        PhotosCmd::Get {
            asset_id,
            out_path,
            thumb,
        } => {
            let encoded_id = uri_encode(&asset_id, true);
            let (endpoint, default_name) = match thumb {
                None => (
                    format!("/v1/assets/{encoded_id}/original"),
                    format!("{asset_id}.bin"),
                ),
                Some(512) => (
                    format!("/v1/assets/{encoded_id}/thumb/512"),
                    format!("{asset_id}-512.webp"),
                ),
                Some(2048) => (
                    format!("/v1/assets/{encoded_id}/thumb/2048"),
                    format!("{asset_id}-2048.webp"),
                ),
                Some(other) => bail!("invalid --thumb size {other} (supported: 512 or 2048)"),
            };
            let dest = out_path.unwrap_or_else(|| PathBuf::from(default_name));
            let bytes = client.download_bearer_to_path(&endpoint, &dest).await?;
            if dest != Path::new("-") {
                println!(
                    "{GREEN}downloaded{RESET} {} -> {} ({})",
                    sanitize_for_tty(&asset_id),
                    dest.display(),
                    format_bytes(bytes)
                );
            }
            Ok(())
        }
        PhotosCmd::People { json } => {
            let val: Value = client.get_json("/v1/people").await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&val)?);
                return Ok(());
            }
            let people = val
                .get("people")
                .and_then(|v| v.as_array())
                .or_else(|| val.as_array());
            let Some(list) = people else {
                println!("{}", serde_json::to_string_pretty(&val)?);
                return Ok(());
            };
            if list.is_empty() {
                println!("(no people)");
                return Ok(());
            }
            println!("{:<8} {:<24} {:<10} {:>8}", "ID", "NAME", "KIND", "PHOTOS");
            for p in list {
                let id = p.get("id").and_then(|v| v.as_i64()).unwrap_or(0);
                let name = p
                    .get("name")
                    .and_then(|v| v.as_str())
                    .map(sanitize_for_tty)
                    .unwrap_or_else(|| "(unnamed)".into());
                let kind = p
                    .get("kind")
                    .and_then(|v| v.as_str())
                    .map(sanitize_for_tty)
                    .unwrap_or_else(|| "person".into());
                let photos = p.get("photos").and_then(|v| v.as_i64()).unwrap_or(0);
                println!("{:<8} {:<24} {:<10} {:>8}", id, name, kind, photos);
            }
            Ok(())
        }
        PhotosCmd::Albums { json } => {
            let val: Value = client.get_json("/v1/albums").await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&val)?);
                return Ok(());
            }
            let albums = val
                .get("albums")
                .and_then(|v| v.as_array())
                .or_else(|| val.as_array());
            let Some(list) = albums else {
                println!("{}", serde_json::to_string_pretty(&val)?);
                return Ok(());
            };
            if list.is_empty() {
                println!("(no albums)");
                return Ok(());
            }
            println!("{:<8} {:<32} {:>8}", "ID", "TITLE", "ITEMS");
            for a in list {
                let id = a.get("id").and_then(|v| v.as_i64()).unwrap_or(0);
                let title = a
                    .get("title")
                    .and_then(|v| v.as_str())
                    .map(sanitize_for_tty)
                    .unwrap_or_else(|| "(untitled)".into());
                let count = a.get("count").and_then(|v| v.as_i64()).unwrap_or(0);
                println!("{:<8} {:<32} {:>8}", id, title, count);
            }
            Ok(())
        }
        PhotosCmd::Stats { json } => {
            let val: Value = client.get_json("/v1/stats").await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&val)?);
                return Ok(());
            }
            if let Some(p) = val.get("photos") {
                let photos = p.get("photos").and_then(|v| v.as_i64()).unwrap_or(0);
                let videos = p.get("videos").and_then(|v| v.as_i64()).unwrap_or(0);
                let bytes = p.get("bytes").and_then(|v| v.as_i64()).unwrap_or(0);
                println!(
                    "Photos:   {} photos, {} videos ({})",
                    photos,
                    videos,
                    format_i64_bytes(bytes)
                );
            }
            if let Some(d) = val.get("drive") {
                let files = d.get("files").and_then(|v| v.as_i64()).unwrap_or(0);
                let bytes = d.get("bytes").and_then(|v| v.as_i64()).unwrap_or(0);
                println!("Drive:    {} files ({})", files, format_i64_bytes(bytes));
            }
            if let Some(albums) = val.get("albums").and_then(|v| v.as_i64()) {
                println!("Albums:   {albums}");
            }
            if let Some(people) = val.get("people").and_then(|v| v.as_i64()) {
                println!("People:   {people}");
            }
            Ok(())
        }
    }
}

fn print_media_search(res: &MediaSearchResponse, json_out: bool) -> Result<()> {
    if json_out {
        println!("{}", serde_json::to_string_pretty(res)?);
        return Ok(());
    }
    if res.items.is_empty() {
        println!("(no results for '{}')", sanitize_for_tty(&res.query));
        return Ok(());
    }
    println!(
        "Found {} item(s) (semantic: {}):",
        res.total,
        sanitize_for_tty(&res.semantic)
    );
    for item in &res.items {
        let short_id = if item.id.len() > 12 {
            &item.id[..12]
        } else {
            &item.id
        };
        let date = item
            .taken_at
            .map(|d| d.format("%Y-%m-%d").to_string())
            .unwrap_or_else(|| "undated   ".into());
        let score = item
            .score
            .map(|s| format!("{s:.2}"))
            .unwrap_or_else(|| "  - ".into());
        let place = item
            .place
            .as_deref()
            .map(sanitize_for_tty)
            .unwrap_or_default();
        println!(
            "  {}  {:<5}  {}  score={}  {}  {DIM}{}{RESET}",
            sanitize_for_tty(short_id),
            sanitize_for_tty(&item.media_type),
            date,
            score,
            sanitize_for_tty(&item.key),
            place
        );
    }
    Ok(())
}

async fn upload_media(client: &AtlasClient, paths: &[PathBuf]) -> Result<()> {
    let mut media_files = Vec::new();
    for p in paths {
        collect_media_files(p, &mut media_files)?;
    }
    if media_files.is_empty() {
        println!("(no image/video files found)");
        return Ok(());
    }

    // Stream-hash all candidate files
    let mut hashed: Vec<(PathBuf, String, u64)> = Vec::with_capacity(media_files.len());
    for path in media_files {
        let (sha, size) = hash_file_sha256(&path).await?;
        hashed.push((path, sha, size));
    }

    // Query POST /v1/assets/exists in batches of 500
    let mut existing: HashSet<String> = HashSet::new();
    for chunk in hashed.chunks(500) {
        let hashes: Vec<&str> = chunk.iter().map(|(_, h, _)| h.as_str()).collect();
        let resp: Value = client
            .post_json("/v1/assets/exists", &json!({ "hashes": hashes }))
            .await?;
        if let Some(arr) = resp.get("have").and_then(|v| v.as_array()) {
            for item in arr {
                if let Some(s) = item.as_str() {
                    existing.insert(s.to_string());
                }
            }
        }
    }

    let mut uploaded = 0usize;
    let mut skipped = 0usize;
    let mut seen_this_run: HashSet<String> = HashSet::new();

    for (path, sha, size) in hashed {
        if existing.contains(&sha) || !seen_this_run.insert(sha.clone()) {
            skipped += 1;
            continue;
        }
        let filename = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("upload.bin");
        client.upload_photo_asset(&path, filename, &sha).await?;
        println!(
            "{GREEN}uploaded{RESET} {} ({}, sha256={})",
            path.display(),
            format_bytes(size),
            &sha[..12]
        );
        uploaded += 1;
    }

    println!("upload complete: {uploaded} uploaded, {skipped} already in library");
    Ok(())
}

pub fn is_media_file(path: &Path) -> bool {
    let Some(ext) = path.extension().and_then(|e| e.to_str()) else {
        return false;
    };
    let lower = ext.to_ascii_lowercase();
    MEDIA_EXTENSIONS.contains(&lower.as_str())
}

fn collect_media_files(path: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    let meta =
        std::fs::metadata(path).with_context(|| format!("cannot access {}", path.display()))?;
    if meta.is_file() {
        if is_media_file(path) {
            out.push(path.to_path_buf());
        }
        return Ok(());
    }
    if meta.is_dir() {
        let mut entries: Vec<PathBuf> = std::fs::read_dir(path)
            .with_context(|| format!("cannot read directory {}", path.display()))?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .collect();
        entries.sort();
        for entry in entries {
            collect_media_files(&entry, out)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_media_extensions() {
        assert!(is_media_file(Path::new("IMG_0001.HEIC")));
        assert!(is_media_file(Path::new("vacation.jpg")));
        assert!(is_media_file(Path::new("clip.MOV")));
        assert!(!is_media_file(Path::new("notes.txt")));
        assert!(!is_media_file(Path::new("archive.zip")));
    }
}
