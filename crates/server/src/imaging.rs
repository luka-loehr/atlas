//! Decoding, resizing and encoding. Everything here is CPU-bound and runs on
//! the blocking pool.
//!
//! Thumbnails are WebP at two sizes (longest side 512 and 2048) and keep the
//! source ICC profile: iPhone photos are Display P3, and a thumbnail that
//! drops the profile has its P3 values read as sRGB and turns pale.

use std::io::BufReader;
use std::path::Path;

use anyhow::{Context, Result, bail};
use fast_image_resize as fr;
use image::{DynamicImage, ImageDecoder, ImageReader, RgbImage};

pub const GRID: u32 = 512;
pub const SCREEN: u32 = 2048;

/// Decoded pixels may not exceed this (default 500 MP): thumbnail jobs read
/// untrusted uploads, and a crafted few-KB PNG can declare gigapixels.
fn max_pixels() -> u64 {
    atlas_core::env("ATLAS_MAX_IMAGE_PIXELS").and_then(|v| v.parse().ok()).unwrap_or(500_000_000)
}

pub struct Decoded {
    pub rgb: RgbImage,
    pub icc: Option<Vec<u8>>,
}

/// Decode any supported still image upright (EXIF orientation applied), as
/// 8-bit RGB with transparency flattened onto white.
pub fn decode(path: &Path) -> Result<Decoded> {
    let ext = crate::util::lower_ext(&path.to_string_lossy());
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

/// Scale so the longest side is at most `max`; never enlarges.
pub fn fit(src: &RgbImage, max: u32) -> Result<RgbImage> {
    let (w, h) = src.dimensions();
    if w.max(h) <= max {
        return Ok(src.clone());
    }
    let scale = f64::from(max) / f64::from(w.max(h));
    let dw = ((f64::from(w) * scale).round() as u32).max(1);
    let dh = ((f64::from(h) * scale).round() as u32).max(1);
    resize(src, dw, dh)
}

pub fn resize(src: &RgbImage, dw: u32, dh: u32) -> Result<RgbImage> {
    let (w, h) = src.dimensions();
    let view = fr::images::ImageRef::new(w, h, src.as_raw(), fr::PixelType::U8x3)?;
    let mut dst = fr::images::Image::new(dw, dh, fr::PixelType::U8x3);
    let options = fr::ResizeOptions::new().resize_alg(fr::ResizeAlg::Convolution(fr::FilterType::Lanczos3));
    fr::Resizer::new().resize(&view, &mut dst, &options)?;
    RgbImage::from_raw(dw, dh, dst.into_vec()).context("resize: buffer size mismatch")
}

/// Lossy WebP, with the ICC profile carried in the extended container.
pub fn encode_webp(img: &RgbImage, quality: f32, icc: Option<&[u8]>) -> Vec<u8> {
    let simple = webp::Encoder::from_rgb(img.as_raw(), img.width(), img.height()).encode(quality);
    match icc {
        Some(profile) if !profile.is_empty() => with_icc(&simple, img.width(), img.height(), profile),
        _ => simple.to_vec(),
    }
}

/// Rewrap a simple-format WebP (RIFF/WEBP + one `VP8 ` chunk) as the extended
/// format: `VP8X` header with the ICC flag, `ICCP`, then the original bitmap
/// chunk untouched. libwebp's encoder cannot attach a profile by itself.
fn with_icc(simple: &[u8], width: u32, height: u32, icc: &[u8]) -> Vec<u8> {
    if simple.len() < 12 || &simple[..4] != b"RIFF" || &simple[8..12] != b"WEBP" {
        return simple.to_vec();
    }
    let bitmap = &simple[12..];
    let padded = |n: usize| n + (n & 1);
    let payload = 4 + (8 + 10) + (8 + padded(icc.len())) + bitmap.len();
    let mut out = Vec::with_capacity(payload + 8);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(payload as u32).to_le_bytes());
    out.extend_from_slice(b"WEBP");
    out.extend_from_slice(b"VP8X");
    out.extend_from_slice(&10u32.to_le_bytes());
    out.extend_from_slice(&[0x20, 0, 0, 0]); // flags: ICC profile present
    out.extend_from_slice(&(width - 1).to_le_bytes()[..3]);
    out.extend_from_slice(&(height - 1).to_le_bytes()[..3]);
    out.extend_from_slice(b"ICCP");
    out.extend_from_slice(&(icc.len() as u32).to_le_bytes());
    out.extend_from_slice(icc);
    if icc.len() & 1 == 1 {
        out.push(0);
    }
    out.extend_from_slice(bitmap);
    out
}

/// A ~25 byte perceptual placeholder (https://evanw.github.io/thumbhash/).
pub fn thumbhash(img: &RgbImage) -> Result<Vec<u8>> {
    let small = fit(img, 100)?;
    let mut rgba = Vec::with_capacity(small.as_raw().len() / 3 * 4);
    for p in small.pixels() {
        rgba.extend_from_slice(&[p[0], p[1], p[2], 255]);
    }
    Ok(thumbhash::rgba_to_thumb_hash(small.width() as usize, small.height() as usize, &rgba))
}

/// Write atomically: a reader never sees a half-written thumbnail.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = path.parent().context("no parent directory")?;
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(crate::util::temp_name(".tmp"));
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })?;
    Ok(())
}

pub struct Thumbs {
    pub width: u32,
    pub height: u32,
    pub thumbhash: Vec<u8>,
}

/// Both library thumbnails plus the placeholder hash, from one decode.
pub fn write_thumbs(decoded: &Decoded, grid: &Path, screen: &Path) -> Result<Thumbs> {
    let (width, height) = decoded.rgb.dimensions();
    let icc = decoded.icc.as_deref();
    let large = fit(&decoded.rgb, SCREEN)?;
    write_atomic(screen, &encode_webp(&large, 86.0, icc))?;
    // the grid size comes from the screen size: same result, a fraction of the work
    let small = fit(&large, GRID)?;
    write_atomic(grid, &encode_webp(&small, 82.0, icc))?;
    Ok(Thumbs { width, height, thumbhash: thumbhash(&small)? })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn icc_wrap_produces_a_valid_extended_webp() {
        let img = RgbImage::from_fn(64, 40, |x, y| image::Rgb([x as u8 * 3, y as u8 * 5, 90]));
        let profile = vec![7u8; 33]; // odd length exercises the padding byte
        let bytes = encode_webp(&img, 80.0, Some(&profile));
        assert_eq!(&bytes[..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize, bytes.len() - 8);
        assert_eq!(&bytes[12..16], b"VP8X");
        let mut decoder = image::codecs::webp::WebPDecoder::new(std::io::Cursor::new(&bytes)).unwrap();
        assert_eq!(decoder.dimensions(), (64, 40));
        assert_eq!(decoder.icc_profile().unwrap().unwrap(), profile);
    }

    #[test]
    fn fit_never_enlarges_and_keeps_the_aspect() {
        let img = RgbImage::new(4000, 3000);
        assert_eq!(fit(&img, 2048).unwrap().dimensions(), (2048, 1536));
        assert_eq!(fit(&RgbImage::new(300, 200), 512).unwrap().dimensions(), (300, 200));
    }

    #[test]
    fn thumbhash_is_small() {
        let img = RgbImage::from_fn(512, 384, |x, y| image::Rgb([(x / 2) as u8, (y / 2) as u8, 128]));
        let hash = thumbhash(&img).unwrap();
        assert!((5..=30).contains(&hash.len()), "{} bytes", hash.len());
    }
}
