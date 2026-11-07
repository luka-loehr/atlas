//! Decoding any still the library holds, upright, as 8-bit RGB: what the
//! server makes thumbnails from and atlas-ml analyzes at full resolution.

use std::io::BufReader;
use std::path::Path;

use anyhow::{Context, Result, bail};
use image::{DynamicImage, ImageDecoder, ImageReader, RgbImage};

/// Decoded pixels may not exceed this (default 500 MP): thumbnail jobs read
/// untrusted uploads, and a crafted few-KB PNG can declare gigapixels.
fn max_pixels() -> u64 {
    crate::env("ATLAS_MAX_IMAGE_PIXELS").and_then(|v| v.parse().ok()).unwrap_or(500_000_000)
}

pub struct Decoded {
    pub rgb: RgbImage,
    pub icc: Option<Vec<u8>>,
}

/// Decode any supported still image upright (EXIF orientation applied), as
/// 8-bit RGB with transparency flattened onto white.
pub fn decode(path: &Path) -> Result<Decoded> {
    let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    if matches!(ext.as_str(), "heic" | "heif" | "avif") || is_heif(path) {
        return decode_heif(path);
    }
    let mut reader = ImageReader::new(BufReader::new(std::fs::File::open(path)?)).with_guessed_format()?;
    let mut limits = image::Limits::default();
    limits.max_alloc = Some(max_pixels() * 4);
    reader.limits(limits);
    let mut decoder = reader.into_decoder().context("unsupported or corrupt image")?;
    let (w, h) = decoder.dimensions();
    if u64::from(w) * u64::from(h) > max_pixels() {
        bail!("image is {w}x{h}, over the pixel limit");
    }
    let icc = decoder.icc_profile().ok().flatten();
    let orientation = decoder.orientation().unwrap_or(image::metadata::Orientation::NoTransforms);
    let mut img = DynamicImage::from_decoder(decoder)?;
    img.apply_orientation(orientation);
    Ok(Decoded { rgb: flatten(img), icc })
}

/// Decode a JPEG/PNG frame held in memory (video poster frames from ffmpeg).
pub fn decode_bytes(bytes: &[u8]) -> Result<Decoded> {
    let img = image::load_from_memory(bytes).context("cannot decode frame")?;
    Ok(Decoded { rgb: flatten(img), icc: None })
}

fn flatten(img: DynamicImage) -> RgbImage {
    if !img.color().has_alpha() {
        return img.into_rgb8();
    }
    let rgba = img.into_rgba8();
    let mut rgb = RgbImage::new(rgba.width(), rgba.height());
    for (dst, src) in rgb.pixels_mut().zip(rgba.pixels()) {
        let a = u32::from(src[3]);
        for c in 0..3 {
            dst[c] = ((u32::from(src[c]) * a + 255 * (255 - a)) / 255) as u8;
        }
    }
    rgb
}

/// HEIF containers are recognized by their `ftyp` box, whatever the name.
fn is_heif(path: &Path) -> bool {
    use std::io::Read;
    let mut head = [0u8; 12];
    std::fs::File::open(path).and_then(|mut f| f.read_exact(&mut head)).is_ok()
        && &head[4..8] == b"ftyp"
        && matches!(&head[8..12], b"heic" | b"heix" | b"hevc" | b"mif1" | b"msf1" | b"avif" | b"heim" | b"heis")
}

/// libheif applies the container's rotation and mirroring itself, so the
/// result is already upright.
fn decode_heif(path: &Path) -> Result<Decoded> {
    use libheif_rs::{ColorSpace, HeifContext, LibHeif, RgbChroma};
    let lib = LibHeif::new();
    let ctx = HeifContext::read_from_file(&path.to_string_lossy())?;
    let handle = ctx.primary_image_handle()?;
    if u64::from(handle.width()) * u64::from(handle.height()) > max_pixels() {
        bail!("image is over the pixel limit");
    }
    let icc = handle.color_profile_raw().map(|p| p.data);
    let image = lib.decode(&handle, ColorSpace::Rgb(RgbChroma::Rgb), None)?;
    let (w, h) = (image.width(), image.height());
    let planes = image.planes();
    let plane = planes.interleaved.context("heif: no interleaved RGB plane")?;
    let mut buf = Vec::with_capacity((w * h * 3) as usize);
    for row in 0..h as usize {
        let start = row * plane.stride;
        buf.extend_from_slice(&plane.data[start..start + w as usize * 3]);
    }
    let rgb = RgbImage::from_raw(w, h, buf).context("heif: plane size mismatch")?;
    Ok(Decoded { rgb, icc })
}

