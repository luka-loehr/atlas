//! Everything the server reads from its environment, in one place.

use std::path::PathBuf;

use anyhow::{Result, bail};
use atlas_core::{env, home};
use chrono_tz::Tz;

pub struct Config {
    /// ATLAS_BIND: listen address (default 0.0.0.0:8787). The firewall
    /// confines the port to loopback and the tailnet.
    pub bind: String,
    /// ATLAS_TOKEN: the bearer token every /v1 route requires.
    pub token: String,
    /// ATLAS_PHOTOS_DIR: library root holding originals/, thumbs/, faces/
    /// (default ~/photos).
    pub photos_dir: PathBuf,
    /// ATLAS_PREVIEWS_DIR: streaming renditions of large videos
    /// (default <photos>/previews). They are bulky; point it at the big disk.
    pub previews_dir: PathBuf,
    /// ATLAS_DRIVE_DIR: drive root holding blobs/ (default ~/drive).
    pub drive_dir: PathBuf,
    /// ATLAS_TZ: the timezone photos without their own UTC offset are shown
    /// in, and that dates parsed from filenames are read as (default: the
    /// machine's zone).
    pub tz: Tz,
    /// ATLAS_ML_URL: where atlas-ml answers (default http://127.0.0.1:8786).
    pub ml_url: String,
    /// ATLAS_WORKERS: parallel ingest jobs inside this process; 0 turns the
    /// workers off (default: cores minus two, at most 8).
    pub workers: usize,
    /// ATLAS_VIDEO_PREVIEWS=0 turns the streaming-rendition stage off.
    pub video_previews: bool,
    /// ATLAS_MAX_UPLOAD_GB: largest accepted upload (default 64).
    pub max_upload: u64,
    /// ATLAS_POWER_BASELINE_W / ATLAS_PSU_EFFICIENCY: calibrate the
    /// whole-system power estimate (defaults 35 W, 0.88).
    pub power_baseline_w: f64,
    pub psu_efficiency: f64,
    /// ATLAS_REPO_DIR: checkout whose commits feed the activity heatmap
    /// (default ~/atlas).
    pub repo_dir: PathBuf,
}

impl Config {
    /// `serving` requires the token; the import and backfill commands talk to
    /// the database and the disk only and run without one.
    pub fn from_env(serving: bool) -> Result<Self> {
        let token = env("ATLAS_TOKEN").unwrap_or_default();
        if serving && token.len() < 16 {
            bail!(
                "ATLAS_TOKEN is not set (or shorter than 16 characters). Every API route needs it; \
                 generate one with `openssl rand -hex 32` and put it in /etc/atlas/server.env"
            );
        }
        let home = home();
        let photos_dir = PathBuf::from(env("ATLAS_PHOTOS_DIR").unwrap_or(format!("{home}/photos")));
        let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
        Ok(Self {
            bind: env("ATLAS_BIND").unwrap_or_else(|| "0.0.0.0:8787".into()),
            token,
            previews_dir: env("ATLAS_PREVIEWS_DIR").map(PathBuf::from).unwrap_or_else(|| photos_dir.join("previews")),
            photos_dir,
            drive_dir: PathBuf::from(env("ATLAS_DRIVE_DIR").unwrap_or(format!("{home}/drive"))),
            tz: timezone()?,
            ml_url: env("ATLAS_ML_URL").unwrap_or_else(|| "http://127.0.0.1:8786".into()),
            workers: env("ATLAS_WORKERS")
                .and_then(|v| v.parse().ok())
                .unwrap_or_else(|| cores.saturating_sub(2).clamp(1, 8)),
            video_previews: env("ATLAS_VIDEO_PREVIEWS").as_deref() != Some("0"),
            max_upload: env("ATLAS_MAX_UPLOAD_GB").and_then(|v| v.parse::<u64>().ok()).unwrap_or(64) << 30,
            power_baseline_w: env("ATLAS_POWER_BASELINE_W").and_then(|v| v.parse().ok()).unwrap_or(35.0),
            psu_efficiency: env("ATLAS_PSU_EFFICIENCY")
                .and_then(|v| v.parse().ok())
                .filter(|e: &f64| *e > 0.0)
                .unwrap_or(0.88),
            repo_dir: PathBuf::from(env("ATLAS_REPO_DIR").unwrap_or(format!("{home}/atlas"))),
        })
    }

    pub fn originals_dir(&self) -> PathBuf {
        self.photos_dir.join("originals")
    }
    /// Uploads land here first; it shares a filesystem with originals/ so the
    /// final move is a rename.
    pub fn incoming_dir(&self) -> PathBuf {
        self.originals_dir().join(".incoming")
    }
    pub fn thumbs_dir(&self) -> PathBuf {
        self.photos_dir.join("thumbs")
    }
    pub fn faces_dir(&self) -> PathBuf {
        self.photos_dir.join("faces")
    }
    pub fn blobs_dir(&self) -> PathBuf {
        self.drive_dir.join("blobs")
    }
    pub fn drive_thumbs_dir(&self) -> PathBuf {
        self.drive_dir.join("thumbs")
    }
    pub fn thumb_path(&self, id: &str, size: u32) -> PathBuf {
        self.thumbs_dir().join(format!("{id}.{size}.webp"))
    }
    pub fn preview_path(&self, id: &str) -> PathBuf {
        self.previews_dir.join(format!("{id}.mp4"))
    }
}

fn timezone() -> Result<Tz> {
    let name = env("ATLAS_TZ")
        .or_else(|| env("TZ"))
        .or_else(|| std::fs::read_to_string("/etc/timezone").ok().map(|s| s.trim().to_string()))
        .or_else(|| {
            // /etc/localtime -> /usr/share/zoneinfo/Europe/Berlin
            let target = std::fs::read_link("/etc/localtime").ok()?;
            let s = target.to_string_lossy().into_owned();
            s.split("zoneinfo/").nth(1).map(str::to_string)
        })
        .unwrap_or_else(|| "UTC".into());
    match name.parse::<Tz>() {
        Ok(tz) => Ok(tz),
        Err(_) => bail!("ATLAS_TZ: unknown timezone {name:?} (expected an IANA name like Europe/Berlin)"),
    }
}
