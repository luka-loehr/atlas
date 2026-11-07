//! Faces: SCRFD detection and AdaFace recognition on ONNX Runtime.
//!
//!   1. SCRFD runs twice: on the image fitted into 640 px, where close-ups
//!      fall into the sizes it was trained on, and at 1600 px, where the
//!      fifth face at the back of a group photo is still 30 px wide. The two
//!      sets are merged by overlap, the more confident detection kept.
//!   2. each face is warped onto the canonical 112x112 landmark layout
//!   3. AdaFace IR-101 (WebFace12M) embeds it and its mirror image; the
//!      mean of the two, L2-normalized, is the face's embedding (the usual
//!      test-time flip, worth a little on profiles and small faces)
//!
//! AdaFace replaced ArcFace R50 (buffalo_l) in Atlas 0.5.0. Measured on the
//! owner's 7,641 named faces (2026-11-07), nearest-face accuracy and true
//! accepts at 1 in 1,000 false accepts: 96.0 / 91.0 % against 95.6 / 89.1 %,
//! and on the same faces shrunk to 20 px, the back row of a group photo,
//! 92.7 / 75.1 % against 90.9 / 65.8 %. ArcFace R100 (Glint360K) was worse
//! than both.

use std::path::Path;

use anyhow::{Result, ensure};
use fast_image_resize::FilterType;
use image::RgbImage;
use ort::session::Session;
use ort::value::Tensor;

use crate::runtime::{self, Device};
use crate::pixels;

/// The sides SCRFD sees the image at, longest edge in pixels.
const SCALES: [u32; 2] = [640, 1600];
const STRIDES: [usize; 3] = [8, 16, 32];
const ANCHORS_PER_CELL: usize = 2;
const DETECT_THRESHOLD: f32 = 0.5;
const NMS_THRESHOLD: f32 = 0.4;
/// Faces narrower than this (pixels of the analyzed image) carry too little
/// identity to be worth keeping.
pub const MIN_FACE_PX: f32 = 14.0;
const FACE_SIZE: usize = 112;
/// Where ArcFace expects the eyes, nose and mouth corners in its 112x112 input.
const TEMPLATE: [[f32; 2]; 5] =
    [[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366], [41.5493, 92.3655], [70.7299, 92.2041]];

pub struct Face {
    /// x1, y1, x2, y2 in pixels of the source image
    pub bbox: [f32; 4],
    pub score: f32,
    /// unit length
    pub embedding: Vec<f32>,
}

pub struct FaceEngine {
    detector: Session,
    recognizer: Session,
}

impl FaceEngine {
    pub fn load(detector: &Path, recognizer: &Path, devices: [Device; 2]) -> Result<Self> {
        Ok(FaceEngine { detector: runtime::session(detector, devices[0])?, recognizer: runtime::session(recognizer, devices[1])? })
    }

    pub fn analyze(&mut self, image: &RgbImage) -> Result<Vec<Face>> {
        let mut detections = Vec::new();
        let long = image.width().max(image.height());
        for side in SCALES {
            // a small image gains nothing from being blown up
            if side > 640 && long < 960 {
                continue;
            }
            detections.extend(self.detect(image, side)?);
        }
        let detections = suppress(detections);
        let mut faces = Vec::with_capacity(detections.len());
        for detection in detections {
            if detection.bbox[2] - detection.bbox[0] < MIN_FACE_PX {
                continue;
            }
            let aligned = align(image, &detection.landmarks);
            faces.push(Face { bbox: detection.bbox, score: detection.score, embedding: self.embed(&aligned)? });
        }
        Ok(faces)
    }

    fn detect(&mut self, image: &RgbImage, side: u32) -> Result<Vec<Detection>> {
        // fit the long side to `side` keeping the aspect; pad to strides of 32
        let (w, h) = image.dimensions();
        let scale = f64::from(side) / f64::from(w.max(h));
        let (new_w, new_h) = (((f64::from(w) * scale) as u32).max(1), ((f64::from(h) * scale) as u32).max(1));
        let (canvas_w, canvas_h) = (new_w.div_ceil(32) * 32, new_h.div_ceil(32) * 32);
        let resized = pixels::resize(image, new_w, new_h, FilterType::Bilinear)?;
        let plane = (canvas_w * canvas_h) as usize;
        // an empty canvas is black, which is (0 - 127.5) / 128 after scaling
        let mut input = vec![-127.5 / 128.0; 3 * plane];
        for (x, y, pixel) in resized.enumerate_pixels() {
            let at = (y * canvas_w + x) as usize;
            for channel in 0..3 {
                input[channel * plane + at] = (f32::from(pixel[channel]) - 127.5) / 128.0;
            }
        }
        let tensor = Tensor::from_array(([1usize, 3, canvas_h as usize, canvas_w as usize], input))?;
        let outputs = self.detector.run(ort::inputs![tensor])?;
        ensure!(outputs.len() == 9, "unexpected SCRFD model: {} outputs", outputs.len());

        // outputs: scores for strides 8/16/32, then boxes, then landmarks
        let mut found = Vec::new();
        for (level, stride) in STRIDES.iter().enumerate() {
            let (_, scores) = outputs[level].try_extract_tensor::<f32>()?;
            let (_, boxes) = outputs[level + 3].try_extract_tensor::<f32>()?;
            let (_, points) = outputs[level + 6].try_extract_tensor::<f32>()?;
            let (cells_w, cells_h) = (canvas_w as usize / stride, canvas_h as usize / stride);
            ensure!(scores.len() == cells_w * cells_h * ANCHORS_PER_CELL, "unexpected SCRFD output shape");
            for (anchor, &score) in scores.iter().enumerate() {
                if score < DETECT_THRESHOLD {
                    continue;
                }
                let cell = anchor / ANCHORS_PER_CELL;
                let cx = ((cell % cells_w) * stride) as f32;
                let cy = ((cell / cells_w) * stride) as f32;
                let s = *stride as f32;
                let b = &boxes[anchor * 4..anchor * 4 + 4];
                let p = &points[anchor * 10..anchor * 10 + 10];
                let unscale = |v: f32| (f64::from(v) / scale) as f32;
                let mut landmarks = [[0f32; 2]; 5];
                for (i, landmark) in landmarks.iter_mut().enumerate() {
                    *landmark = [unscale(cx + p[i * 2] * s), unscale(cy + p[i * 2 + 1] * s)];
                }
                found.push(Detection {
                    bbox: [
                        unscale(cx - b[0] * s),
                        unscale(cy - b[1] * s),
                        unscale(cx + b[2] * s),
                        unscale(cy + b[3] * s),
                    ],
                    score,
                    landmarks,
                });
            }
        }
        Ok(found)
    }

    /// The face and its mirror image in one batch; their mean, normalized.
    fn embed(&mut self, aligned: &[u8]) -> Result<Vec<f32>> {
        let plane = FACE_SIZE * FACE_SIZE;
        let mut input = vec![0f32; 2 * 3 * plane];
        for y in 0..FACE_SIZE {
            for x in 0..FACE_SIZE {
                let at = y * FACE_SIZE + x;
                let mirrored = y * FACE_SIZE + (FACE_SIZE - 1 - x);
                for channel in 0..3 {
                    // RGB, scaled to [-1, 1]
                    let v = (f32::from(aligned[at * 3 + channel]) / 255.0 - 0.5) / 0.5;
                    input[channel * plane + at] = v;
                    input[3 * plane + channel * plane + mirrored] = v;
                }
            }
        }
        let tensor = Tensor::from_array(([2usize, 3, FACE_SIZE, FACE_SIZE], input))?;
        let outputs = self.recognizer.run(ort::inputs![tensor])?;
        let (_, values) = outputs[0].try_extract_tensor::<f32>()?;
        let dim = values.len() / 2;
        ensure!(dim == 512, "unexpected recognizer output: {} values per face", dim);
        let mut a = values[..dim].to_vec();
        let mut b = values[dim..].to_vec();
        pixels::normalize(&mut a);
        pixels::normalize(&mut b);
        let mut embedding: Vec<f32> = a.iter().zip(&b).map(|(x, y)| x + y).collect();
        pixels::normalize(&mut embedding);
        Ok(embedding)
    }
}

struct Detection {
    bbox: [f32; 4],
    score: f32,
    landmarks: [[f32; 2]; 5],
}

/// Greedy non-maximum suppression, best score first.
fn suppress(mut detections: Vec<Detection>) -> Vec<Detection> {
    detections.sort_by(|a, b| b.score.total_cmp(&a.score));
    let area = |b: &[f32; 4]| (b[2] - b[0] + 1.0) * (b[3] - b[1] + 1.0);
    let mut kept: Vec<Detection> = Vec::new();
    for candidate in detections {
        let overlaps = kept.iter().any(|k| {
            let w = (k.bbox[2].min(candidate.bbox[2]) - k.bbox[0].max(candidate.bbox[0]) + 1.0).max(0.0);
            let h = (k.bbox[3].min(candidate.bbox[3]) - k.bbox[1].max(candidate.bbox[1]) + 1.0).max(0.0);
            let intersection = w * h;
            intersection / (area(&k.bbox) + area(&candidate.bbox) - intersection) > NMS_THRESHOLD
        });
        if !overlaps {
            kept.push(candidate);
        }
    }
    kept
}

/// The least-squares similarity transform (rotation, uniform scale,
/// translation) taking `from` onto `to`, as the rows [a, -b, tx; b, a, ty].
fn similarity(from: &[[f32; 2]; 5], to: &[[f32; 2]; 5]) -> [f32; 6] {
    let mean = |pts: &[[f32; 2]; 5]| {
        let (sx, sy) = pts.iter().fold((0.0, 0.0), |(x, y), p| (x + p[0], y + p[1]));
        (sx / 5.0, sy / 5.0)
    };
    let (fx, fy) = mean(from);
    let (tx, ty) = mean(to);
    let (mut dot, mut cross, mut norm) = (0f32, 0f32, 0f32);
    for (f, t) in from.iter().zip(to) {
        let (x, y) = (f[0] - fx, f[1] - fy);
        let (u, v) = (t[0] - tx, t[1] - ty);
        dot += x * u + y * v;
        cross += x * v - y * u;
        norm += x * x + y * y;
    }
    let (a, b) = if norm > 0.0 { (dot / norm, cross / norm) } else { (1.0, 0.0) };
    [a, -b, tx - (a * fx - b * fy), b, a, ty - (b * fx + a * fy)]
}

/// Warp the face onto the 112x112 template: for every output pixel, sample
/// the source bilinearly at the inverse-transformed position; outside is
/// black. Returns interleaved RGB.
fn align(image: &RgbImage, landmarks: &[[f32; 2]; 5]) -> Vec<u8> {
    let [a, nb, tx, b, _, ty] = similarity(landmarks, &TEMPLATE);
    let b_ = -nb;
    debug_assert!((b - b_).abs() < 1e-4);
    let det = a * a + b * b;
    let (w, h) = (image.width() as i32, image.height() as i32);
    let raw = image.as_raw();
    let sample = |x: i32, y: i32, channel: usize| -> f32 {
        if x < 0 || y < 0 || x >= w || y >= h { 0.0 } else { f32::from(raw[((y * w + x) * 3) as usize + channel]) }
    };
    let mut out = vec![0u8; FACE_SIZE * FACE_SIZE * 3];
    for v in 0..FACE_SIZE {
        for u in 0..FACE_SIZE {
            // inverse of [a -b; b a] is [a b; -b a] / det
            let (du, dv) = (u as f32 - tx, v as f32 - ty);
            let sx = (a * du + b * dv) / det;
            let sy = (-b * du + a * dv) / det;
            let (x0, y0) = (sx.floor(), sy.floor());
            let (fx, fy) = (sx - x0, sy - y0);
            let (x0, y0) = (x0 as i32, y0 as i32);
            for channel in 0..3 {
                let top = sample(x0, y0, channel) * (1.0 - fx) + sample(x0 + 1, y0, channel) * fx;
                let bottom = sample(x0, y0 + 1, channel) * (1.0 - fx) + sample(x0 + 1, y0 + 1, channel) * fx;
                out[(v * FACE_SIZE + u) * 3 + channel] = (top * (1.0 - fy) + bottom * fy).round().clamp(0.0, 255.0) as u8;
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn similarity_recovers_a_known_transform() {
        // scale 2, rotate 90 degrees, shift (10, 20): (x, y) -> (-2y + 10, 2x + 20)
        let to = TEMPLATE.map(|[x, y]| [-2.0 * y + 10.0, 2.0 * x + 20.0]);
        let m = similarity(&TEMPLATE, &to);
        for (got, want) in m.iter().zip([0.0, -2.0, 10.0, 2.0, 0.0, 20.0]) {
            assert!((got - want).abs() < 1e-3, "{m:?}");
        }
    }

    #[test]
    fn aligning_template_landmarks_is_the_identity() {
        let image = RgbImage::from_fn(112, 112, |x, y| image::Rgb([x as u8, y as u8, 7]));
        let out = align(&image, &TEMPLATE);
        assert_eq!(&out[(40 * 112 + 30) * 3..(40 * 112 + 30) * 3 + 3], &[30, 40, 7]);
    }

    #[test]
    fn overlapping_detections_collapse_to_the_best() {
        let d = |x: f32, score: f32| Detection { bbox: [x, 0.0, x + 100.0, 100.0], score, landmarks: [[0.0; 2]; 5] };
        let kept = suppress(vec![d(0.0, 0.6), d(5.0, 0.9), d(300.0, 0.7)]);
        assert_eq!(kept.len(), 2);
        assert_eq!(kept[0].score, 0.9);
        assert_eq!(kept[1].score, 0.7);
    }
}
