//! Streaming renditions of videos.
//!
//! A phone films 4K HEVC at 50 Mbit/s and more; streamed from a home uplink
//! that stalls. Sources above 1080p or above a sane bitrate get a 1080p HEVC
//! rendition with the index at the front, which starts instantly and seeks
//! freely; everything else streams as it is. The original is never touched
//! and stays available at /original.
//!
//! Encoding prefers the GPU end to end (decode, scale, encode) and steps
//! down to software decode, then to a pure software encode, so the stage
//! works on any machine and is merely fast on one with NVENC.

use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result, bail};

use super::video::{self, Probe};
use crate::{AppState, util};

const MAX_SHORT_SIDE: i32 = 1080;
/// Above this the original is too heavy to stream as is.
const MAX_BITRATE: i64 = 12_000_000;

pub fn wanted(probe: &Probe) -> bool {
    let short_side = probe.coded_width.min(probe.coded_height);
    let streamable_codec = matches!(probe.codec.as_str(), "h264" | "hevc");
    let streamable_container = probe.container.contains("mp4") || probe.container.contains("mov");
    short_side > MAX_SHORT_SIDE
        || probe.bitrate.is_some_and(|b| b > MAX_BITRATE)
        || !streamable_codec
        || !streamable_container
}

pub async fn run(app: &AppState, id: &str) -> Result<()> {
    let c = app.pool.get().await?;
    let row = c
        .query_opt("SELECT orig_path, type FROM assets WHERE id = $1", &[&id])
        .await?
        .context("asset is gone")?;
    let original: String = row.get(0);
    if row.get::<_, &str>(1) != "video" {
        return Ok(());
    }
    drop(c);

    let source = util::confine(&app.cfg.photos_dir, Path::new(&original))
        .await
        .with_context(|| format!("original missing: {original}"))?;
    let dest = app.cfg.preview_path(id);
    let made = tokio::task::spawn_blocking(move || -> Result<bool> {
        let probe = video::probe(&source)?;
        if !wanted(&probe) {
            return Ok(false);
        }
        transcode(&source, &dest, &probe)?;
        Ok(true)
    })
    .await??;

    if made {
        let c = app.pool.get().await?;
        c.execute("UPDATE assets SET preview_at = now() WHERE id = $1", &[&id]).await?;
    }
    Ok(())
}

/// Target size in stored orientation: short side at most 1080, never
/// enlarged, both even.
pub fn target_size(probe: &Probe) -> (i32, i32) {
    let (w, h) = (probe.coded_width.max(2), probe.coded_height.max(2));
    let short = w.min(h);
    if short <= MAX_SHORT_SIDE {
        return (w & !1, h & !1);
    }
    let scale = f64::from(MAX_SHORT_SIDE) / f64::from(short);
    (((f64::from(w) * scale).round() as i32) & !1, ((f64::from(h) * scale).round() as i32) & !1)
}

fn transcode(source: &Path, dest: &Path, probe: &Probe) -> Result<()> {
    let (w, h) = target_size(probe);
    let ten_bit = probe.pixel_format.contains("10");
    std::fs::create_dir_all(dest.parent().context("no parent directory")?)?;
    let tmp = dest.with_extension("part.mp4");

    // -noautorotate keeps frames in stored orientation and carries the
    // rotation over as metadata, which every player honors; rotating on the
    // GPU would need a filter the hardware path does not have.
    let nvenc = ["-c:v", "hevc_nvenc", "-preset", "p5", "-rc", "vbr", "-cq", "27", "-b:v", "0", "-maxrate", "8M", "-bufsize", "16M"];
    let gpu_scale = format!("scale_cuda={w}:{h}:format={}", if ten_bit { "p010le" } else { "nv12" });
    let cpu_scale = format!("scale={w}:{h}:flags=bicubic");
    let attempts: [(&[&str], &str, &[&str]); 3] = [
        (&["-hwaccel", "cuda", "-hwaccel_output_format", "cuda"], &gpu_scale, &nvenc),
        (&[], &cpu_scale, &nvenc),
        (&[], &cpu_scale, &["-c:v", "libx265", "-preset", "medium", "-crf", "26"]),
    ];

    let mut last_error = String::new();
    for (decode, filter, encode) in attempts {
        let output = Command::new("ffmpeg")
            .args(["-v", "error", "-y", "-noautorotate"])
            .args(decode)
            .arg("-i")
            .arg(source)
            .args(["-map", "0:v:0", "-map", "0:a:0?", "-vf", filter])
            .args(encode)
            .args(["-tag:v", "hvc1", "-c:a", "aac", "-b:a", "160k", "-ac", "2"])
            .args(["-map_metadata", "0", "-movflags", "+faststart"])
            .arg(&tmp)
            .output()
            .context("ffmpeg is not installed")?;
        if output.status.success() && std::fs::metadata(&tmp).is_ok_and(|m| m.len() > 0) {
            std::fs::rename(&tmp, dest)?;
            return Ok(());
        }
        last_error = String::from_utf8_lossy(&output.stderr).lines().last().unwrap_or("").to_string();
        let _ = std::fs::remove_file(&tmp);
    }
    bail!("every encoder failed; last: {last_error}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn probe(w: i32, h: i32, codec: &str, bitrate: i64) -> Probe {
        Probe {
            coded_width: w,
            coded_height: h,
            codec: codec.into(),
            bitrate: Some(bitrate),
            container: "mov,mp4,m4a,3gp,3g2,mj2".into(),
            ..Probe::default()
        }
    }

    #[test]
    fn only_heavy_or_odd_sources_get_a_rendition() {
        assert!(wanted(&probe(3840, 2160, "hevc", 55_000_000)));
        assert!(wanted(&probe(1920, 1080, "h264", 20_000_000)));
        assert!(wanted(&probe(640, 480, "mpeg4", 1_000_000)));
        assert!(!wanted(&probe(1920, 1080, "h264", 8_000_000)));
        assert!(!wanted(&probe(1080, 1920, "hevc", 6_000_000)));
    }

    #[test]
    fn target_keeps_orientation_and_even_sizes() {
        assert_eq!(target_size(&probe(3840, 2160, "hevc", 0)), (1920, 1080));
        assert_eq!(target_size(&probe(2160, 3840, "hevc", 0)), (1080, 1920));
        assert_eq!(target_size(&probe(1281, 721, "h264", 0)), (1280, 720));
    }
}
