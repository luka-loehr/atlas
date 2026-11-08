//! Text: PP-OCRv6 (medium) detection and recognition on ONNX Runtime.
//!
//!   1. the detector (DB) gives every pixel a probability of being text, on
//!      the image fitted into 1536 px; connected regions above the threshold
//!      whose mean probability is high enough are lines, grown a little
//!      (DB's "unclip") because the detector marks their shrunken core
//!   2. each line is cut out of the full-resolution image, scaled to 48 px
//!      high and read by the recognizer (CTC over 18,708 characters: Latin
//!      with every diacritic, Greek, Cyrillic, CJK, symbols), in batches of
//!      similar width
//!
//! PP-OCRv6 replaced the first choice, PP-OCRv5 (server detector, Latin
//! recognizer), after a side-by-side on the library (2026-11-07): it read
//! chat screenshots as whole lines where v5 broke words apart, and runs in
//! a fraction of the time on the GPU.

use std::path::Path;

use anyhow::{Context, Result, ensure};
use fast_image_resize::FilterType;
use image::RgbImage;
use ort::value::Tensor;

use crate::runtime::{self, Device};
use crate::pixels::{self, IMAGENET_MEAN, IMAGENET_STD};

const DETECT_SIDE: u32 = 1536;
const PIXEL_THRESHOLD: f32 = 0.2;
const BOX_THRESHOLD: f32 = 0.45;
const UNCLIP_RATIO: f32 = 1.4;
const LINE_HEIGHT: u32 = 48;
const MAX_LINE_WIDTH: u32 = 3200;
const BATCH: usize = 8;
/// A line read with less confidence than this is noise (an icon read as a
/// character, a texture read as letters).
const MIN_CONFIDENCE: f32 = 0.75;

pub struct Line {
    pub text: String,
    /// x1, y1, x2, y2 in pixels of the source image
    pub bbox: [u32; 4],
    pub confidence: f32,
}

pub struct TextEngine {
    detector: runtime::Model,
    recognizer: runtime::Model,
    /// index 0 is CTC's blank; the last entry is the space
    characters: Vec<String>,
}

impl TextEngine {
    pub fn load(detector: &Path, recognizer: &Path, dictionary: &Path, devices: [Device; 2]) -> Result<Self> {
        let dict = std::fs::read_to_string(dictionary).with_context(|| format!("cannot read {}", dictionary.display()))?;
        let mut characters = vec![String::new()];
        characters.extend(dict.lines().map(str::to_string));
        characters.push(" ".into());
        Ok(TextEngine {
            detector: runtime::session(detector, devices[0])?,
            recognizer: runtime::session(recognizer, devices[1])?,
            characters,
        })
    }

    /// The lines in reading order: top to bottom, left to right.
    pub fn read(&mut self, image: &RgbImage) -> Result<Vec<Line>> {
        let boxes = self.detect(image)?;
        let mut lines = self.recognize(image, &boxes)?;
        lines.retain(|l| l.confidence >= MIN_CONFIDENCE && meaningful(&l.text));
        // rows of about one line height, then left to right
        lines.sort_by_key(|l| (l.bbox[1] / 24, l.bbox[0]));
        Ok(lines)
    }

    fn detect(&mut self, image: &RgbImage) -> Result<Vec<[u32; 4]>> {
        let (w, h) = image.dimensions();
        let scale = (f64::from(DETECT_SIDE) / f64::from(w.max(h))).min(2.0);
        let dw = (((f64::from(w) * scale) / 32.0).round() as u32 * 32).max(32);
        let dh = (((f64::from(h) * scale) / 32.0).round() as u32 * 32).max(32);
        let resized = pixels::resize(image, dw, dh, FilterType::Bilinear)?;
        let plane = (dw * dh) as usize;
        let mut input = vec![0f32; 3 * plane];
        // the models were trained on BGR images normalized with these (RGB
        // ordered) statistics, so channel 0 is blue
        for (i, pixel) in resized.pixels().enumerate() {
            for c in 0..3 {
                input[c * plane + i] = (f32::from(pixel[2 - c]) / 255.0 - IMAGENET_MEAN[c]) / IMAGENET_STD[c];
            }
        }
        let tensor = Tensor::from_array(([1usize, 3, dh as usize, dw as usize], input))?;
        let options = self.detector.options()?;
        let outputs = self.detector.session.run_with_options(ort::inputs![tensor], &options)?;
        let (_, prob) = outputs[0].try_extract_tensor::<f32>()?;
        ensure!(prob.len() == plane, "unexpected text detector output");

        let (fx, fy) = (f64::from(w) / f64::from(dw), f64::from(h) / f64::from(dh));
        let mut boxes = Vec::new();
        for region in regions(prob, dw as usize, dh as usize, PIXEL_THRESHOLD) {
            if region.mean < BOX_THRESHOLD || region.width().min(region.height()) < 3 {
                continue;
            }
            let (bw, bh) = (region.width() as f32, region.height() as f32);
            let grow = region.area as f32 * UNCLIP_RATIO / (2.0 * (bw + bh));
            let x0 = ((region.x0 as f32 - grow).max(0.0) as f64 * fx) as u32;
            let y0 = ((region.y0 as f32 - grow).max(0.0) as f64 * fy) as u32;
            let x1 = (((region.x1 + 1) as f32 + grow).min(dw as f32) as f64 * fx) as u32;
            let y1 = (((region.y1 + 1) as f32 + grow).min(dh as f32) as f64 * fy) as u32;
            if x1 > x0 + 2 && y1 > y0 + 2 {
                boxes.push([x0, y0, x1.min(w), y1.min(h)]);
            }
        }
        Ok(boxes)
    }

    fn recognize(&mut self, image: &RgbImage, boxes: &[[u32; 4]]) -> Result<Vec<Line>> {
        // each line as a 48 px high strip; vertical text is turned upright
        let mut strips: Vec<(usize, RgbImage)> = Vec::with_capacity(boxes.len());
        for (i, b) in boxes.iter().enumerate() {
            let mut crop = image::imageops::crop_imm(image, b[0], b[1], b[2] - b[0], b[3] - b[1]).to_image();
            if crop.height() as f32 > 1.5 * crop.width() as f32 {
                crop = image::imageops::rotate270(&crop);
            }
            let width = ((LINE_HEIGHT as f32 * crop.width() as f32 / crop.height() as f32).round() as u32)
                .clamp(16, MAX_LINE_WIDTH);
            strips.push((i, pixels::resize(&crop, width, LINE_HEIGHT, FilterType::Bilinear)?));
        }
        // similar widths batch together with little padding
        strips.sort_by_key(|(_, s)| s.width());
        let mut lines = Vec::with_capacity(strips.len());
        for batch in strips.chunks(BATCH) {
            let width = batch.iter().map(|(_, s)| s.width()).max().unwrap_or(16) as usize;
            let plane = LINE_HEIGHT as usize * width;
            // padding is 0 after normalization, as in PaddleOCR
            let mut input = vec![0f32; batch.len() * 3 * plane];
            for (n, (_, strip)) in batch.iter().enumerate() {
                for (x, y, pixel) in strip.enumerate_pixels() {
                    let at = y as usize * width + x as usize;
                    for c in 0..3 {
                        input[n * 3 * plane + c * plane + at] = (f32::from(pixel[2 - c]) / 255.0 - 0.5) / 0.5;
                    }
                }
            }
            let tensor = Tensor::from_array(([batch.len(), 3, LINE_HEIGHT as usize, width], input))?;
            let options = self.recognizer.options()?;
            let outputs = self.recognizer.session.run_with_options(ort::inputs![tensor], &options)?;
            let (shape, probs) = outputs[0].try_extract_tensor::<f32>()?;
            let (steps, classes) = (shape[1] as usize, shape[2] as usize);
            ensure!(classes == self.characters.len(), "recognizer has {classes} classes, dictionary {}", self.characters.len());
            for (n, (i, _)) in batch.iter().enumerate() {
                let (text, confidence) = decode(&probs[n * steps * classes..(n + 1) * steps * classes], classes, &self.characters);
                if !text.trim().is_empty() {
                    lines.push(Line { text: text.trim().to_string(), bbox: boxes[*i], confidence });
                }
            }
        }
        Ok(lines)
    }
}

/// Greedy CTC: the best class per step, repeats collapsed, blanks dropped;
/// the confidence is the mean probability of the characters kept.
fn decode(probs: &[f32], classes: usize, characters: &[String]) -> (String, f32) {
    let mut text = String::new();
    let (mut sum, mut kept, mut previous) = (0f32, 0usize, 0usize);
    for step in probs.chunks_exact(classes) {
        let (best, p) = step.iter().copied().enumerate().fold((0, f32::MIN), |a, (i, p)| if p > a.1 { (i, p) } else { a });
        if best != 0 && best != previous {
            text.push_str(&characters[best]);
            sum += p;
            kept += 1;
        }
        previous = best;
    }
    (text, if kept == 0 { 0.0 } else { sum / kept as f32 })
}

/// Whether a line says anything: at least two letters or digits, or one
/// that is not a lone symbol.
fn meaningful(text: &str) -> bool {
    text.chars().filter(|c| c.is_alphanumeric()).count() >= 2
}

struct Region {
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
    area: usize,
    mean: f32,
}

impl Region {
    fn width(&self) -> usize {
        self.x1 - self.x0 + 1
    }
    fn height(&self) -> usize {
        self.y1 - self.y0 + 1
    }
}

/// 8-connected regions of the probability map above `threshold`, each with
/// its bounding box, size and mean probability.
fn regions(prob: &[f32], w: usize, h: usize, threshold: f32) -> Vec<Region> {
    let mut seen = vec![false; w * h];
    let mut found = Vec::new();
    let mut stack = Vec::new();
    for start in 0..w * h {
        if seen[start] || prob[start] <= threshold {
            continue;
        }
        seen[start] = true;
        stack.push(start);
        let mut r = Region { x0: usize::MAX, y0: usize::MAX, x1: 0, y1: 0, area: 0, mean: 0.0 };
        let mut sum = 0f32;
        while let Some(i) = stack.pop() {
            let (x, y) = (i % w, i / w);
            r.x0 = r.x0.min(x);
            r.y0 = r.y0.min(y);
            r.x1 = r.x1.max(x);
            r.y1 = r.y1.max(y);
            r.area += 1;
            sum += prob[i];
            for dy in -1i64..=1 {
                for dx in -1i64..=1 {
                    let (nx, ny) = (x as i64 + dx, y as i64 + dy);
                    if nx < 0 || ny < 0 || nx >= w as i64 || ny >= h as i64 {
                        continue;
                    }
                    let j = ny as usize * w + nx as usize;
                    if !seen[j] && prob[j] > threshold {
                        seen[j] = true;
                        stack.push(j);
                    }
                }
            }
        }
        r.mean = sum / r.area as f32;
        found.push(r);
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ctc_collapses_repeats_and_drops_blanks() {
        let chars: Vec<String> = ["", "a", "b", " "].iter().map(|s| s.to_string()).collect();
        // a a _ a b b _ -> "aab"
        let steps = [1, 1, 0, 1, 2, 2, 0];
        let mut probs = vec![0f32; steps.len() * 4];
        for (t, &c) in steps.iter().enumerate() {
            probs[t * 4 + c] = 0.9;
        }
        let (text, confidence) = decode(&probs, 4, &chars);
        assert_eq!(text, "aab");
        assert!((confidence - 0.9).abs() < 1e-6);
    }

    #[test]
    fn regions_are_connected_components() {
        // two blobs, one of them diagonal
        let (w, h) = (6, 4);
        let mut prob = vec![0f32; w * h];
        for i in [0, 7, 14] {
            prob[i] = 0.9;
        }
        prob[5] = 0.5;
        prob[11] = 0.7;
        let found = regions(&prob, w, h, 0.2);
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].area, 3);
        assert_eq!((found[1].x0, found[1].y0, found[1].x1, found[1].y1), (5, 0, 5, 1));
    }

    #[test]
    fn noise_is_not_text() {
        assert!(!meaningful("个"));
        assert!(!meaningful("|"));
        assert!(meaningful("OK"));
        assert!(meaningful("19:06"));
    }
}
