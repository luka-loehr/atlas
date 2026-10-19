//! Pixel plumbing shared by both models: decode, resize, encode.

use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result, ensure};
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

/// The transfer curve of a clip's video stream ("arib-std-b67", "bt709", ...).
fn transfer(path: &Path) -> String {
    Command::new("ffprobe")
        .args(["-v", "quiet", "-select_streams", "v:0", "-show_entries", "stream=color_transfer", "-of", "csv=p=0"])
        .arg(path)
        .output()
        .map(|out| String::from_utf8_lossy(&out.stdout).trim().trim_end_matches(',').to_string())
        .unwrap_or_default()
}

/// `count` upright frames spread evenly over a clip, tone-mapped when it is
/// HDR. The seeks run side by side, and frames come over as BMP: lossless
/// like PNG, without compressing megapixels only to decode them again.
pub fn video_frames(path: &Path, duration: f64, count: usize) -> Result<Vec<RgbImage>> {
    let hdr = matches!(transfer(path).as_str(), "arib-std-b67" | "smpte2084");
    let frames: Vec<Option<RgbImage>> = std::thread::scope(|scope| {
        let workers: Vec<_> = (0..count)
            .map(|i| {
                scope.spawn(move || {
                    let at = (duration * (i as f64 + 0.5) / count as f64).max(0.0);
                    let mut ffmpeg = Command::new("ffmpeg");
                    ffmpeg.args(["-v", "error", "-ss", &format!("{at:.3}"), "-i"]).arg(path).args(["-frames:v", "1"]);
                    if hdr {
                        ffmpeg.args(["-vf", TONE_MAP]);
                    }
                    let out = ffmpeg.args(["-f", "image2pipe", "-c:v", "bmp", "pipe:1"]).output().ok()?;
                    out.status.success().then_some(())?;
                    image::load_from_memory(&out.stdout).ok().map(|f| f.into_rgb8())
                })
            })
            .collect();
        workers.into_iter().map(|w| w.join().ok().flatten()).collect()
    });
    let frames: Vec<RgbImage> = frames.into_iter().flatten().collect();
    ensure!(!frames.is_empty(), "ffmpeg produced no frames (is it installed?)");
    Ok(frames)
}

pub fn normalize(v: &mut [f32]) {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        v.iter_mut().for_each(|x| *x /= norm);
    }
}
