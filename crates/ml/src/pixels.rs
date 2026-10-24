//! Pixel plumbing shared by both models: decode, resize, encode.

use std::path::Path;
use std::process::Command;
use std::time::Duration;

use atlas_core::process;

use anyhow::{Context, Result, bail, ensure};
use fast_image_resize as fr;
use image::RgbImage;

pub fn open(path: &Path) -> Result<RgbImage> {
    Ok(image::open(path).with_context(|| format!("cannot decode {}", path.display()))?.into_rgb8())
}

pub fn resize(src: &RgbImage, width: u32, height: u32, filter: fr::FilterType) -> Result<RgbImage> {
    if src.dimensions() == (width, height) {
        return Ok(src.clone());
    }
    let view = fr::images::ImageRef::new(src.width(), src.height(), src.as_raw(), fr::PixelType::U8x3)?;
    let mut dst = fr::images::Image::new(width, height, fr::PixelType::U8x3);
    let options = fr::ResizeOptions::new().resize_alg(fr::ResizeAlg::Convolution(filter));
    fr::Resizer::new().resize(&view, &mut dst, &options)?;
    RgbImage::from_raw(width, height, dst.into_vec()).context("resize: buffer size mismatch")
}

/// PNG with fast compression: this only crosses a loopback socket.
pub fn png(img: &RgbImage) -> Result<Vec<u8>> {
    use image::ImageEncoder;
    use image::codecs::png::{CompressionType, FilterType, PngEncoder};
    let mut out = Vec::with_capacity(img.as_raw().len() / 2);
    PngEncoder::new_with_quality(&mut out, CompressionType::Fast, FilterType::Adaptive).write_image(
        img.as_raw(),
        img.width(),
        img.height(),
        image::ExtendedColorType::Rgb8,
    )?;
    Ok(out)
}

/// HDR to SDR, as for the server's video posters (jobs/video.rs there).
const TONE_MAP: &str = "zscale=t=linear:npl=203,format=gbrpf32le,zscale=p=bt709,\
                        tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=pc,format=rgb24";

/// What sampling a clip needs to know: when each of its frames is shown,
/// its average frame rate, and whether it is HDR.
#[derive(Debug, Clone)]
pub struct Clip {
    /// presentation time of every frame a decoder puts out, in order
    pub times: Vec<f64>,
    pub fps: f64,
    pub hdr: bool,
}

/// Reads the first video stream's packets (no decoding). A frame is
/// addressed by its index, as a decoder counts them; its time comes from its
/// own packet, so a clip with a variable frame rate (any iPhone video) is
/// sampled at the frames meant, not at index / average rate. Packets flagged
/// discard (edit lists) are never shown and are not counted. Times are
/// relative to the start of the file, as ffmpeg's `-ss` counts them (a
/// Pixel clip's first frame can sit at 0.3 s).
pub fn probe(path: &Path) -> Result<Clip> {
    let out = process::output(
        Command::new("ffprobe")
            .args(["-v", "error", "-select_streams", "v:0", "-show_entries"])
            .args(["stream=avg_frame_rate,r_frame_rate,color_transfer:packet=pts_time,flags:format=start_time", "-of", "json"])
            .arg(path),
        Duration::from_secs(120),
    )?;
    ensure!(out.status.success(), "ffprobe: {}", String::from_utf8_lossy(&out.stderr).trim());
    let probed: serde_json::Value = serde_json::from_slice(&out.stdout)?;
    let stream = probed["streams"].get(0).context("no video stream")?;
    let rate = |v: &serde_json::Value| -> Option<f64> {
        let (num, den) = v.as_str()?.split_once('/')?;
        let (num, den): (f64, f64) = (num.parse().ok()?, den.parse().ok()?);
        (num > 0.0 && den > 0.0).then(|| num / den)
    };
    let mut times: Vec<f64> = probed["packets"]
        .as_array()
        .map(|packets| {
            packets
                .iter()
                .filter(|p| !p["flags"].as_str().unwrap_or("").contains('D'))
                .filter_map(|p| p["pts_time"].as_str()?.parse().ok())
                .collect()
        })
        .unwrap_or_default();
    ensure!(!times.is_empty(), "ffprobe found no frames");
    let start: f64 = probed["format"]["start_time"].as_str().and_then(|s| s.parse().ok()).unwrap_or(0.0);
    times.iter_mut().for_each(|t| *t = (*t - start).max(0.0));
    times.sort_by(f64::total_cmp);
    let fps = rate(&stream["avg_frame_rate"]).or_else(|| rate(&stream["r_frame_rate"])).context("no frame rate")?;
    let hdr = matches!(stream["color_transfer"].as_str(), Some("arib-std-b67" | "smpte2084"));
    Ok(Clip { times, fps, hdr })
}

/// Upright frames shown at the given seconds of a clip, tone-mapped when it
/// is HDR. A few seeks run side by side, and frames come over as BMP:
/// lossless like PNG, without compressing megapixels only to decode them
/// again.
pub fn frames_at(path: &Path, seconds: &[f64], hdr: bool) -> Result<Vec<RgbImage>> {
    const SIDE_BY_SIDE: usize = 8;
    // a clip whose index does not seek (some phone editors' exports) is read
    // from a copy remuxed for this job: every seek would otherwise decode
    // from the start, minutes per frame in a long clip
    let last = seconds.iter().copied().fold(0.0, f64::max);
    let remuxed = if seeks_badly(path, last)? { Some(Remuxed::new(path)?) } else { None };
    let path = remuxed.as_ref().map_or(path, |r| r.path.as_path());
    let mut frames = Vec::with_capacity(seconds.len());
    for batch in seconds.chunks(SIDE_BY_SIDE) {
        let decoded: Vec<Result<RgbImage>> = std::thread::scope(|scope| {
            let workers: Vec<_> = batch
                .iter()
                .map(|&at| {
                    scope.spawn(move || -> Result<RgbImage> {
                        // half a millisecond early: the first frame at or after
                        // the seek point is the one shown at `at`, whatever
                        // rounding its printed time went through. A frame that
                        // does not decode (a broken last packet) is taken from
                        // a little earlier, at most half a second.
                        for back in [0.0005, 0.1, 0.25, 0.5] {
                            if let Some(frame) = frame_at(path, (at - back).max(0.0), hdr)? {
                                return Ok(frame);
                            }
                        }
                        bail!("ffmpeg gave no frame at {at:.3} s")
                    })
                })
                .collect();
            workers.into_iter().map(|w| w.join().unwrap_or_else(|_| Err(anyhow::anyhow!("frame reader panicked")))).collect()
        });
        for frame in decoded {
            frames.push(frame?);
        }
    }
    Ok(frames)
}

/// Whether a seek to `at` lands far before it: the demuxer found no index
/// entry near it and would start decoding at the beginning.
fn seeks_badly(path: &Path, at: f64) -> Result<bool> {
    const SLACK: f64 = 30.0;
    if at < SLACK {
        return Ok(false);
    }
    let out = process::output(
        Command::new("ffprobe")
            .args(["-v", "error", "-select_streams", "v:0", "-read_intervals", &format!("{at:.3}%+#1")])
            .args(["-show_entries", "packet=pts_time", "-of", "csv=p=0"])
            .arg(path),
        Duration::from_secs(60),
    )?;
    let landed: Option<f64> = String::from_utf8_lossy(&out.stdout).lines().next().and_then(|l| l.trim().parse().ok());
    Ok(landed.is_some_and(|t| t < at - SLACK))
}

/// A stream copy of a clip with a fresh index, removed when dropped.
struct Remuxed {
    path: std::path::PathBuf,
}

impl Remuxed {
    fn new(src: &Path) -> Result<Self> {
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("atlas-ml-remux-{}-{n}.mp4", std::process::id()));
        let remuxed = Self { path };
        let out = process::output(
            Command::new("ffmpeg")
                .args(["-v", "error", "-y", "-i"])
                .arg(src)
                .args(["-map", "0:v:0", "-c", "copy", "-movflags", "+faststart"])
                .arg(&remuxed.path),
            Duration::from_secs(600),
        )?;
        ensure!(out.status.success(), "remux: {}", String::from_utf8_lossy(&out.stderr).trim());
        Ok(remuxed)
    }
}

impl Drop for Remuxed {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// The first frame at or after `seek`, None when there is none.
fn frame_at(path: &Path, seek: f64, hdr: bool) -> Result<Option<RgbImage>> {
    let mut ffmpeg = Command::new("ffmpeg");
    ffmpeg.args(["-v", "error", "-ss", &format!("{seek:.4}"), "-i"]).arg(path);
    // the stream `probe` read, also when a clip has two
    ffmpeg.args(["-map", "0:v:0", "-frames:v", "1"]);
    if hdr {
        ffmpeg.args(["-vf", TONE_MAP]);
    }
    // a seek deep into a long multi-GB clip, beside the other readers, can
    // take minutes; the job's own limit (EMBED_LIMIT) still bounds the whole
    let out = process::output(ffmpeg.args(["-f", "image2pipe", "-c:v", "bmp", "pipe:1"]), Duration::from_secs(600))?;
    if !out.status.success() || out.stdout.is_empty() {
        return Ok(None);
    }
    Ok(Some(image::load_from_memory(&out.stdout)?.into_rgb8()))
}

pub fn normalize(v: &mut [f32]) {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        v.iter_mut().for_each(|x| *x /= norm);
    }
}
