//! Decoding, resizing and encoding. Everything here is CPU-bound and runs on
//! the blocking pool.
//!
//! Thumbnails are WebP at two sizes (longest side 512 and 2048) and keep the
//! source ICC profile: iPhone photos are Display P3, and a thumbnail that
//! drops the profile has its P3 values read as sRGB and turns pale.

use std::path::Path;

use anyhow::{Context, Result};
use fast_image_resize as fr;
use image::RgbImage;

pub const GRID: u32 = 512;
pub const SCREEN: u32 = 2048;

pub use atlas_core::decode::{Decoded, decode, decode_bytes};

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
    let options =
        fr::ResizeOptions::new().resize_alg(fr::ResizeAlg::Convolution(fr::FilterType::Lanczos3));
    fr::Resizer::new().resize(&view, &mut dst, &options)?;
    RgbImage::from_raw(dw, dh, dst.into_vec()).context("resize: buffer size mismatch")
}

/// The side of a grid tile: a square JPEG cropped as an aspect-fill cell
/// shows the photo. 384 px covers an iPhone cell at three and five columns
/// (3x screens: 396 and 237 px).
pub const TILE: u32 = 384;

/// The grid tile of a 2048 thumbnail: the center square, `TILE` px, JPEG,
/// with the thumbnail's ICC profile (Display P3 for iPhone photos: without
/// it the colors would be read as sRGB and look pale). A JPEG because every
/// phone decodes it in hardware, in a fraction of a WebP's time.
pub fn make_tile(thumb: &Path) -> Result<Vec<u8>> {
    use image::ImageDecoder;
    use image::codecs::jpeg::JpegEncoder;
    let file = std::io::BufReader::new(std::fs::File::open(thumb)?);
    let mut decoder =
        image::codecs::webp::WebPDecoder::new(file).context("not a WebP thumbnail")?;
    let icc = decoder.icc_profile().ok().flatten();
    let rgb = image::DynamicImage::from_decoder(decoder)?.into_rgb8();
    let (w, h) = rgb.dimensions();
    let side = w.min(h);
    let square =
        image::imageops::crop_imm(&rgb, (w - side) / 2, (h - side) / 2, side, side).to_image();
    let tile = if side > TILE {
        resize(&square, TILE, TILE)?
    } else {
        square
    };
    let mut out = Vec::with_capacity(48 << 10);
    let mut encoder = JpegEncoder::new_with_quality(&mut out, 80);
    if let Some(icc) = icc {
        let _ = image::ImageEncoder::set_icc_profile(&mut encoder, icc);
    }
    image::ImageEncoder::write_image(
        encoder,
        tile.as_raw(),
        tile.width(),
        tile.height(),
        image::ExtendedColorType::Rgb8,
    )?;
    Ok(out)
}

/// Lossy WebP, with the ICC profile carried in the extended container.
pub fn encode_webp(img: &RgbImage, quality: f32, icc: Option<&[u8]>) -> Vec<u8> {
    let simple = webp::Encoder::from_rgb(img.as_raw(), img.width(), img.height()).encode(quality);
    match icc {
        Some(profile) if !profile.is_empty() => {
            with_icc(&simple, img.width(), img.height(), profile)
        }
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
    Ok(thumbhash::rgba_to_thumb_hash(
        small.width() as usize,
        small.height() as usize,
        &rgba,
    ))
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
    Ok(Thumbs {
        width,
        height,
        thumbhash: thumbhash(&small)?,
    })
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
        assert_eq!(
            u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize,
            bytes.len() - 8
        );
        assert_eq!(&bytes[12..16], b"VP8X");
        use image::ImageDecoder;
        let mut decoder =
            image::codecs::webp::WebPDecoder::new(std::io::Cursor::new(&bytes)).unwrap();
        assert_eq!(decoder.dimensions(), (64, 40));
        assert_eq!(decoder.icc_profile().unwrap().unwrap(), profile);
    }

    #[test]
    fn fit_never_enlarges_and_keeps_the_aspect() {
        let img = RgbImage::new(4000, 3000);
        assert_eq!(fit(&img, 2048).unwrap().dimensions(), (2048, 1536));
        assert_eq!(
            fit(&RgbImage::new(300, 200), 512).unwrap().dimensions(),
            (300, 200)
        );
    }

    #[test]
    fn resize_keeps_colors_where_they_were() {
        // left half red, right half blue: guards the resampler across fast_image_resize bumps
        let (red, blue) = (image::Rgb([200u8, 30, 30]), image::Rgb([30u8, 30, 200]));
        let img = RgbImage::from_fn(400, 300, |x, _| if x < 200 { red } else { blue });
        let out = resize(&img, 100, 75).unwrap();
        assert_eq!(out.dimensions(), (100, 75));
        let near = |a: &image::Rgb<u8>, b: &image::Rgb<u8>| {
            a.0.iter().zip(b.0).all(|(x, y)| x.abs_diff(y) <= 2)
        };
        assert!(
            near(out.get_pixel(10, 37), &red),
            "{:?}",
            out.get_pixel(10, 37)
        );
        assert!(
            near(out.get_pixel(90, 37), &blue),
            "{:?}",
            out.get_pixel(90, 37)
        );
    }

    #[test]
    fn thumbhash_is_small() {
        let img = RgbImage::from_fn(512, 384, |x, y| {
            image::Rgb([(x / 2) as u8, (y / 2) as u8, 128])
        });
        let hash = thumbhash(&img).unwrap();
        assert!((5..=30).contains(&hash.len()), "{} bytes", hash.len());
    }
}
