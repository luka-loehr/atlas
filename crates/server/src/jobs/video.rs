//! Video facts and frames, via ffprobe and ffmpeg.

use std::path::Path;
use std::process::Command;
use std::time::Duration;

use atlas_core::process;

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde_json::Value;

#[derive(Default, Debug)]
pub struct Probe {
    /// as displayed: rotation applied
    pub width: Option<i32>,
    pub height: Option<i32>,
    /// as stored in the stream
    pub coded_width: i32,
    pub coded_height: i32,
    pub duration: Option<f64>,
    pub codec: String,
    pub pixel_format: String,
    /// the video stream's transfer curve: "arib-std-b67" (HLG) or
    /// "smpte2084" (PQ) are HDR
    pub transfer: String,
    pub bitrate: Option<i64>,
    pub container: String,
    pub created: Option<DateTime<Utc>>,
    pub tz_offset_s: Option<i32>,
    pub lat: Option<f64>,
    pub lon: Option<f64>,
    pub camera: Option<String>,
}

pub fn probe(path: &Path) -> Result<Probe> {
    let out = process::output(
        Command::new("ffprobe").args(["-v", "quiet", "-print_format", "json", "-show_streams", "-show_format"]).arg(path),
        Duration::from_secs(60),
    )?;
    let info: Value = serde_json::from_slice(&out.stdout).context("ffprobe returned no data")?;
    let mut probe = Probe::default();
    let format = &info["format"];
    probe.duration = format["duration"].as_str().and_then(|d| d.parse().ok()).filter(|d: &f64| *d > 0.0);
    probe.bitrate = format["bit_rate"].as_str().and_then(|b| b.parse().ok());
    probe.container = format["format_name"].as_str().unwrap_or("").to_string();

    if let Some(stream) = info["streams"].as_array().and_then(|s| s.iter().find(|s| s["codec_type"] == "video")) {
        probe.codec = stream["codec_name"].as_str().unwrap_or("").to_string();
        probe.pixel_format = stream["pix_fmt"].as_str().unwrap_or("").to_string();
        probe.transfer = stream["color_transfer"].as_str().unwrap_or("").to_string();
        probe.coded_width = stream["width"].as_i64().unwrap_or(0) as i32;
        probe.coded_height = stream["height"].as_i64().unwrap_or(0) as i32;
        let rotation = stream["side_data_list"]
            .as_array()
            .and_then(|list| list.iter().find_map(|sd| sd["rotation"].as_f64()))
            .or_else(|| stream["tags"]["rotate"].as_str().and_then(|r| r.parse().ok()))
            .unwrap_or(0.0) as i64;
        let (w, h) = if rotation.rem_euclid(180) == 90 {
            (probe.coded_height, probe.coded_width)
        } else {
            (probe.coded_width, probe.coded_height)
        };
        if w > 0 && h > 0 {
            probe.width = Some(w);
            probe.height = Some(h);
        }
    }

    let tags = &format["tags"];
    let tag = |keys: &[&str]| keys.iter().find_map(|k| tags[*k].as_str()).map(str::to_string);
    // Apple writes the wall-clock time with its offset; the generic
    // creation_time is UTC
    if let Some(local) = tag(&["com.apple.quicktime.creationdate"]).and_then(|s| DateTime::parse_from_rfc3339(&s).ok().or_else(|| DateTime::parse_from_str(&s, "%Y-%m-%dT%H:%M:%S%z").ok())) {
        probe.created = Some(local.with_timezone(&Utc));
        probe.tz_offset_s = Some(local.offset().local_minus_utc());
    } else if let Some(utc) = tag(&["creation_time"]).and_then(|s| DateTime::parse_from_rfc3339(&s).ok()) {
        probe.created = Some(utc.with_timezone(&Utc));
    }
    // cameras without a clock stamp 1904 or 1970
    probe.created = probe.created.filter(|t| t.timestamp() > 315_532_800);
    if let Some((lat, lon)) = tag(&["com.apple.quicktime.location.ISO6709", "location"]).and_then(|s| iso6709(&s)) {
        probe.lat = Some(lat);
        probe.lon = Some(lon);
    }
    probe.camera = tag(&["com.apple.quicktime.model", "com.android.model", "model"])
        .or_else(|| tag(&["com.apple.quicktime.make", "make"]));
    Ok(probe)
}

/// "+48.1374+011.5755+519.000/" -> (48.1374, 11.5755)
pub fn iso6709(s: &str) -> Option<(f64, f64)> {
    let s = s.trim().trim_end_matches('/');
    let starts: Vec<usize> = s.char_indices().filter(|(_, c)| matches!(c, '+' | '-')).map(|(i, _)| i).collect();
    if starts.len() < 2 || starts[0] != 0 {
        return None;
    }
    let lat: f64 = s[starts[0]..starts[1]].parse().ok()?;
    let lon: f64 = s[starts[1]..starts.get(2).copied().unwrap_or(s.len())].parse().ok()?;
    ((-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon) && (lat != 0.0 || lon != 0.0)).then_some((lat, lon))
}

impl Probe {
    /// HLG or PQ: frames need tone mapping before they look right in SDR.
    pub fn hdr(&self) -> bool {
        is_hdr(&self.transfer)
    }
}

pub fn is_hdr(transfer: &str) -> bool {
    matches!(transfer, "arib-std-b67" | "smpte2084")
}

/// HDR to SDR for stills: linear light with HLG/PQ reference white (203
/// nits, BT.2408) as SDR white, BT.709 primaries, Hable's curve for what is
/// brighter. Without it an iPhone clip's frame comes out pale and grey.
pub const TONE_MAP: &str = "zscale=t=linear:npl=203,format=gbrpf32le,zscale=p=bt709,\
                            tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=pc,format=rgb24";

/// One upright frame as BMP (lossless like PNG, without the seconds a 4K
/// PNG takes to compress), tone-mapped when the clip is HDR. Seeks to one
/// second in for something more telling than a fade-in; clips shorter than
/// that fall back to the first frame.
pub fn poster(path: &Path, hdr: bool) -> Result<Vec<u8>> {
    for seek in ["1", "0"] {
        let mut ffmpeg = Command::new("ffmpeg");
        ffmpeg.args(["-v", "error", "-ss", seek, "-i"]).arg(path).args(["-frames:v", "1"]);
        if hdr {
            ffmpeg.args(["-vf", TONE_MAP]);
        }
        let out = process::output(ffmpeg.args(["-f", "image2pipe", "-c:v", "bmp", "pipe:1"]), Duration::from_secs(120))?;
        if out.status.success() && !out.stdout.is_empty() {
            return Ok(out.stdout);
        }
    }
    anyhow::bail!("ffmpeg produced no frame")
}

#[cfg(test)]
mod tests {
    use super::{is_hdr, iso6709};

    #[test]
    fn hlg_and_pq_are_hdr() {
        assert!(is_hdr("arib-std-b67"));
        assert!(is_hdr("smpte2084"));
        assert!(!is_hdr("bt709"));
        assert!(!is_hdr(""));
    }

    #[test]
    fn parses_quicktime_locations() {
        assert_eq!(iso6709("+48.1374+011.5755+519.000/"), Some((48.1374, 11.5755)));
        assert_eq!(iso6709("-33.8688+151.2093/"), Some((-33.8688, 151.2093)));
        assert_eq!(iso6709("+00.0000+000.0000/"), None);
        assert_eq!(iso6709("garbage"), None);
    }
}
