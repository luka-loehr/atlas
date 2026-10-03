//! Google Takeout photos -> the library.
//!
//!   atlas-server import photos ~/takeout/takeout-*.zip
//!
//! Media is read straight out of the archives. Each file's JSON sidecar
//! (which may sit in a different archive of the same export) supplies the
//! capture time, location, description and favorite flag; the folder it sits
//! in becomes its album. Content is deduplicated by SHA-256, the same id the
//! upload path computes, so re-running an import or importing something the
//! phone already uploaded adds nothing twice. Thumbnails, metadata,
//! embeddings and faces are left to the job queue.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use anyhow::{Context, Result};
use atlas_core::queue;
use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use regex::Regex;
use serde_json::Value;
use zip::ZipArchive;

use super::extract_hashed;
use crate::{Config, util};

static DUPLICATE_SUFFIX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(.*)(\(\d+\))(\.[^.]+)$").unwrap());
static YEAR_FOLDER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^Photos from \d{4}$").unwrap());

#[derive(Default)]
struct Sidecar {
    taken: Option<DateTime<Utc>>,
    lat: Option<f64>,
    lon: Option<f64>,
    description: Option<String>,
    favorite: bool,
    camera: Option<String>,
}

/// Every name Google may have given this file's sidecar: `<name>.json`,
/// `<name>.supplemental-metadata.json` and its truncations (sidecar names are
/// capped at 51 characters), and the duplicate swap `IMG(1).jpg` ->
/// `IMG.jpg(1).json`.
fn sidecar_names(media: &str) -> Vec<String> {
    let mut names = Vec::new();
    let swapped = DUPLICATE_SUFFIX.captures(media).map(|c| format!("{}{}{}", &c[1], &c[3], &c[2]));
    for base in [Some(media.to_string()), swapped].into_iter().flatten() {
        for suffix in [".json", ".supplemental-metadata.json", ".supplemental-metad.json", ".suppl.json", ".sup.json"] {
            names.push(format!("{base}{suffix}"));
        }
        for full in [format!("{base}.supplemental-metadata.json"), format!("{base}.json")] {
            if full.chars().count() > 51 {
                let head: String = full.chars().take(46).collect();
                names.push(format!("{head}.json"));
            }
        }
    }
    names
}

fn parse_sidecar(raw: &str) -> Sidecar {
    let Ok(d) = serde_json::from_str::<Value>(raw) else { return Sidecar::default() };
    let mut sidecar = Sidecar {
        taken: d["photoTakenTime"]["timestamp"]
            .as_str()
            .and_then(|t| t.parse::<i64>().ok())
            .and_then(|t| DateTime::from_timestamp(t, 0)),
        description: d["description"].as_str().filter(|s| !s.is_empty()).map(|s| s.chars().take(2000).collect()),
        favorite: d["favorited"].as_bool().unwrap_or(false) || d["favorited"].is_object(),
        camera: d["cameraDetails"]["cameraModel"]
            .as_str()
            .or_else(|| d["googlePhotosOrigin"]["mobileUpload"]["deviceType"].as_str())
            .map(|s| s.chars().take(120).collect()),
        ..Sidecar::default()
    };
    let (lat, lon) = (d["geoData"]["latitude"].as_f64().unwrap_or(0.0), d["geoData"]["longitude"].as_f64().unwrap_or(0.0));
    if lat != 0.0 || lon != 0.0 {
        sidecar.lat = Some(lat);
        sidecar.lon = Some(lon);
    }
    sidecar
}

pub async fn run(cfg: &Config, pool: &Pool, paths: &[PathBuf]) -> Result<()> {
    anyhow::ensure!(!paths.is_empty(), "no archives given");
    let mut archives = Vec::new();
    for path in paths {
        let file = File::open(path).with_context(|| format!("cannot open {}", path.display()))?;
        archives.push(ZipArchive::new(file).with_context(|| format!("{} is not a complete zip", path.display()))?);
    }

    // pass 1: where every sidecar lives, across all archives
    let mut sidecars: HashMap<String, (usize, usize)> = HashMap::new();
    let mut media: Vec<(usize, usize, String)> = Vec::new();
    for (a, archive) in archives.iter_mut().enumerate() {
        for i in 0..archive.len() {
            let entry = archive.by_index_raw(i)?;
            if entry.is_dir() {
                continue;
            }
            let name = entry.name().to_string();
            let base = name.rsplit('/').next().unwrap_or(&name).to_string();
            if name.ends_with(".json") {
                sidecars.insert(base, (a, i));
            } else if (name.contains("/Google Fotos/") || name.contains("/Google Photos/"))
                && util::media_ext(&base) != "bin"
            {
                media.push((a, i, name));
            }
        }
    }
    println!("{} media files, {} sidecars in {} archives", media.len(), sidecars.len(), archives.len());

    let c = pool.get().await?;
    let mut known: HashSet<String> = c.query("SELECT id FROM assets", &[]).await?.iter().map(|r| r.get(0)).collect();
    let mut albums: HashMap<String, i64> = HashMap::new();
    let (mut added, mut duplicates, mut failed) = (0usize, 0usize, 0usize);

    for (n, (a, i, name)) in media.iter().enumerate() {
        let base = name.rsplit('/').next().unwrap_or(name);
        let folder = name.rsplit('/').nth(1).unwrap_or("");
        let album = (!YEAR_FOLDER.is_match(folder) && !folder.is_empty()).then(|| folder.to_string());

        let mut sidecar = Sidecar::default();
        for candidate in sidecar_names(base) {
            if let Some(&(sa, si)) = sidecars.get(&candidate) {
                let mut raw = String::new();
                if archives[sa].by_index(si).and_then(|mut e| Ok(e.read_to_string(&mut raw)?)).is_ok() {
                    sidecar = parse_sidecar(&raw);
                }
                break;
            }
        }

        let incoming = cfg.incoming_dir();
        let extracted = tokio::task::block_in_place(|| -> Result<_> {
            let mut entry = archives[*a].by_index(*i)?;
            extract_hashed(&mut entry, &incoming)
        });
        let (tmp, id, size) = match extracted {
            Ok(result) => result,
            Err(e) => {
                failed += 1;
                eprintln!("  {base}: {e:#}");
                continue;
            }
        };

        if known.contains(&id) {
            duplicates += 1;
            let _ = std::fs::remove_file(&tmp);
        } else {
            let ext = util::media_ext(base);
            let month = sidecar.taken.map(|t| t.format("%Y/%m").to_string()).unwrap_or_else(|| "0000/00".into());
            let dir = cfg.originals_dir().join(month);
            std::fs::create_dir_all(&dir)?;
            let dest = dir.join(format!("{id}.{ext}"));
            std::fs::rename(&tmp, &dest)?;
            insert(&c, &id, ext, &sidecar, &dest, base, size).await?;
            known.insert(id.clone());
            added += 1;
        }

        if let Some(title) = album {
            let album_id = match albums.get(&title) {
                Some(id) => *id,
                None => {
                    let row = c
                        .query_one(
                            "INSERT INTO albums (title) VALUES ($1)
                             ON CONFLICT (title) DO UPDATE SET title = EXCLUDED.title RETURNING id",
                            &[&title],
                        )
                        .await?;
                    albums.insert(title, row.get(0));
                    row.get(0)
                }
            };
            c.execute(
                "INSERT INTO album_assets (album_id, asset_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                &[&album_id, &id],
            )
            .await?;
        }
        if (n + 1) % 500 == 0 {
            println!("  {}/{} ({added} new, {duplicates} already in the library, {failed} failed)", n + 1, media.len());
        }
    }
    println!("done: {added} new, {duplicates} already in the library, {failed} failed");
    Ok(())
}

async fn insert(
    c: &tokio_postgres::Client,
    id: &str,
    ext: &str,
    sidecar: &Sidecar,
    dest: &Path,
    name: &str,
    size: u64,
) -> Result<()> {
    let kind = if util::is_video_ext(ext) { "video" } else { "photo" };
    c.execute(
        "INSERT INTO assets (id, type, taken_at, taken_src, lat, lon, camera, description, favorite,
                             orig_path, orig_name, size_bytes, source)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, 'takeout')
         ON CONFLICT (id) DO NOTHING",
        &[
            &id,
            &kind,
            &sidecar.taken,
            &sidecar.taken.map(|_| "sidecar"),
            &sidecar.lat,
            &sidecar.lon,
            &sidecar.camera,
            &sidecar.description,
            &sidecar.favorite,
            &dest.to_string_lossy().as_ref(),
            &name,
            &(size as i64),
        ],
    )
    .await?;
    for kind in [queue::THUMB, queue::META, queue::EMBED, queue::FACES] {
        queue::enqueue(c, kind, "asset", id, queue::PRIORITY_DEFAULT).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sidecar_names_cover_googles_variants() {
        let names = sidecar_names("IMG_0001.jpg");
        assert!(names.contains(&"IMG_0001.jpg.json".to_string()));
        assert!(names.contains(&"IMG_0001.jpg.supplemental-metadata.json".to_string()));
        // the duplicate counter moves behind the extension
        assert!(sidecar_names("IMG(1).jpg").contains(&"IMG.jpg(1).json".to_string()));
        // long names are cut to 51 characters including ".json"
        let long = format!("{}.jpg", "x".repeat(60));
        let cut = sidecar_names(&long).into_iter().find(|n| n.chars().count() == 51).unwrap();
        assert!(cut.ends_with(".json") && cut.starts_with("xxxx"));
    }

    #[test]
    fn sidecars_yield_time_place_and_flags() {
        let s = parse_sidecar(
            r#"{"photoTakenTime":{"timestamp":"1722384000"},"geoData":{"latitude":45.08,"longitude":13.63},
                "favorited":true,"description":"Rovinj","googlePhotosOrigin":{"mobileUpload":{"deviceType":"IOS_PHONE"}}}"#,
        );
        assert_eq!(s.taken.unwrap().timestamp(), 1_722_384_000);
        assert_eq!((s.lat, s.lon), (Some(45.08), Some(13.63)));
        assert!(s.favorite);
        assert_eq!(s.description.as_deref(), Some("Rovinj"));
        assert_eq!(s.camera.as_deref(), Some("IOS_PHONE"));
        assert!(parse_sidecar(r#"{"geoData":{"latitude":0.0,"longitude":0.0}}"#).lat.is_none());
    }
}
