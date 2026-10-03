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

/// `count` upright frames spread evenly over a clip.
pub fn video_frames(path: &Path, duration: f64, count: usize) -> Result<Vec<RgbImage>> {
    let mut frames = Vec::with_capacity(count);
    for i in 0..count {
        let at = (duration * (i as f64 + 0.5) / count as f64).max(0.0);
        let out = Command::new("ffmpeg")
            .args(["-v", "error", "-ss", &format!("{at:.3}"), "-i"])
            .arg(path)
            .args(["-frames:v", "1", "-f", "image2pipe", "-c:v", "png", "pipe:1"])
            .output()
            .context("ffmpeg is not installed")?;
        if out.status.success()
            && let Ok(frame) = image::load_from_memory(&out.stdout)
        {
            frames.push(frame.into_rgb8());
        }
    }
    ensure!(!frames.is_empty(), "ffmpeg produced no frames");
    Ok(frames)
}

pub fn normalize(v: &mut [f32]) {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        v.iter_mut().for_each(|x| *x /= norm);
    }
}
