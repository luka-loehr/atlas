//! Animals: RF-DETR (Large) finds them, pet-recognition-large tells them
//! apart.
//!
//!   1. RF-DETR sees the image stretched to 704x704 (as it was trained),
//!      ImageNet-normalized, and answers 300 boxes with a probability per
//!      COCO class; birds, cats, dogs and horses are kept
//!   2. each animal's box is cut out, scaled to 224x224 and embedded by a
//!      frozen DINOv2-large with a projection trained for re-identifying
//!      individual pets: two photos of the same dog lie at about 0.6-0.7,
//!      different dogs at about 0-0.2 (measured on the library, 2026-11-07)
//!
//! Chosen over YOLOX-M and plain DINOv2-base, the first candidates: RF-DETR
//! reaches about 60 COCO AP against YOLOX-M's 47, and the pet model is
//! trained for exactly the question "which dog is this".
//!
//! The pet model (1.2 GB) runs on the CPU: it sees only animal crops, and the
//! GPU's memory is shared with the embedding model.

use std::path::Path;

use anyhow::{Result, ensure};
use atlas_core::vector::normalize;
use fast_image_resize::FilterType;
use image::RgbImage;
use ort::value::Tensor;

use crate::runtime::{self, Device};
use crate::pixels;

const DETECT_SIZE: u32 = 704;
const EMBED_SIZE: u32 = 224;
/// The COCO classes (RF-DETR's 91-way numbering) kept, and what they are.
const SPECIES: [(usize, &str); 4] = [(16, "bird"), (17, "cat"), (18, "dog"), (19, "horse")];
const THRESHOLD: f32 = 0.5;
/// Animals smaller than this (pixels, the shorter side of the box) are too
/// small to tell apart; they still count as "a dog in the photo".
pub const MIN_IDENTIFY_PX: u32 = 64;
const NMS_THRESHOLD: f32 = 0.6;
const MEAN: [f32; 3] = [0.485, 0.456, 0.406];
const STD: [f32; 3] = [0.229, 0.224, 0.225];

pub struct Animal {
    pub species: &'static str,
    /// x1, y1, x2, y2 in pixels of the source image
    pub bbox: [f32; 4],
    pub score: f32,
    /// unit length, 512 dimensions; None when the animal is too small
    pub look: Option<Vec<f32>>,
}

pub struct AnimalEngine {
    detector: runtime::Model,
    identifier: runtime::Model,
}

impl AnimalEngine {
    pub fn load(detector: &Path, identifier: &Path, device: Device) -> Result<Self> {
        Ok(AnimalEngine { detector: runtime::session(detector, device)?, identifier: runtime::session(identifier, Device::Cpu)? })
    }

    pub fn find(&mut self, image: &RgbImage) -> Result<Vec<Animal>> {
        let (w, h) = image.dimensions();
        let input = normalized(&pixels::resize(image, DETECT_SIZE, DETECT_SIZE, FilterType::Bilinear)?);
        let tensor = Tensor::from_array(([1usize, 3, DETECT_SIZE as usize, DETECT_SIZE as usize], input))?;
        let options = self.detector.options()?;
        let outputs = self.detector.session.run_with_options(ort::inputs![tensor], &options)?;
        let (_, boxes) = outputs[0].try_extract_tensor::<f32>()?;
        let (shape, logits) = outputs[1].try_extract_tensor::<f32>()?;
        let (queries, classes) = (shape[1] as usize, shape[2] as usize);
        ensure!(boxes.len() == queries * 4 && classes > 19, "unexpected RF-DETR output");

        let mut found: Vec<Animal> = Vec::new();
        for q in 0..queries {
            let row = &logits[q * classes..(q + 1) * classes];
            let Some((species, p)) = SPECIES
                .iter()
                .map(|&(class, name)| (name, sigmoid(row[class])))
                .max_by(|a, b| a.1.total_cmp(&b.1))
            else {
                continue;
            };
            if p < THRESHOLD {
                continue;
            }
            // center x, center y, width, height, relative
            let b = &boxes[q * 4..q * 4 + 4];
            let bbox = [
                ((b[0] - b[2] / 2.0) * w as f32).max(0.0),
                ((b[1] - b[3] / 2.0) * h as f32).max(0.0),
                ((b[0] + b[2] / 2.0) * w as f32).min(w as f32),
                ((b[1] + b[3] / 2.0) * h as f32).min(h as f32),
            ];
            if bbox[2] - bbox[0] < 8.0 || bbox[3] - bbox[1] < 8.0 {
                continue;
            }
            found.push(Animal { species, bbox, score: p, look: None });
        }
        let mut kept = suppress(found);
        for animal in &mut kept {
            let [x0, y0, x1, y1] = animal.bbox.map(|v| v as u32);
            // the identifier knows dogs and cats; a horse or a bird is found,
            // but never told apart from another one
            if (x1 - x0).min(y1 - y0) < MIN_IDENTIFY_PX || !matches!(animal.species, "dog" | "cat") {
                continue;
            }
            let crop = image::imageops::crop_imm(image, x0, y0, x1 - x0, y1 - y0).to_image();
            let input = normalized(&pixels::resize(&crop, EMBED_SIZE, EMBED_SIZE, FilterType::Bilinear)?);
            let tensor = Tensor::from_array(([1usize, 3, EMBED_SIZE as usize, EMBED_SIZE as usize], input))?;
            let options = self.identifier.options()?;
        let outputs = self.identifier.session.run_with_options(ort::inputs![tensor], &options)?;
            let (_, values) = outputs[0].try_extract_tensor::<f32>()?;
            let mut look = values.to_vec();
            ensure!(look.len() == 512, "unexpected pet embedding: {} values", look.len());
            normalize(&mut look);
            animal.look = Some(look);
        }
        Ok(kept)
    }
}

fn sigmoid(x: f32) -> f32 {
    1.0 / (1.0 + (-x).exp())
}

/// RGB planes, ImageNet mean and deviation.
fn normalized(image: &RgbImage) -> Vec<f32> {
    let plane = (image.width() * image.height()) as usize;
    let mut out = vec![0f32; 3 * plane];
    for (i, pixel) in image.pixels().enumerate() {
        for c in 0..3 {
            out[c * plane + i] = (f32::from(pixel[c]) / 255.0 - MEAN[c]) / STD[c];
        }
    }
    out
}

/// DETR rarely answers one animal twice, but a dog read as dog and as cat
/// by two queries would be two animals: the more confident box stays.
fn suppress(mut found: Vec<Animal>) -> Vec<Animal> {
    found.sort_by(|a, b| b.score.total_cmp(&a.score));
    let mut kept: Vec<Animal> = Vec::new();
    for candidate in found {
        if !kept.iter().any(|k| iou(&k.bbox, &candidate.bbox) > NMS_THRESHOLD) {
            kept.push(candidate);
        }
    }
    kept
}

pub fn iou(a: &[f32; 4], b: &[f32; 4]) -> f32 {
    let w = (a[2].min(b[2]) - a[0].max(b[0])).max(0.0);
    let h = (a[3].min(b[3]) - a[1].max(b[1])).max(0.0);
    let i = w * h;
    let union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - i;
    if union <= 0.0 { 0.0 } else { i / union }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlapping_answers_collapse_to_the_surer_one() {
        let a = |x: f32, score: f32, species| Animal { species, bbox: [x, 0.0, x + 100.0, 100.0], score, look: None };
        let kept = suppress(vec![a(0.0, 0.7, "cat"), a(5.0, 0.9, "dog"), a(300.0, 0.6, "dog")]);
        assert_eq!(kept.len(), 2);
        assert_eq!(kept[0].species, "dog");
        assert_eq!(kept[0].score, 0.9);
    }

    #[test]
    fn iou_of_identical_and_disjoint_boxes() {
        assert!((iou(&[0.0, 0.0, 10.0, 10.0], &[0.0, 0.0, 10.0, 10.0]) - 1.0).abs() < 1e-6);
        assert_eq!(iou(&[0.0, 0.0, 10.0, 10.0], &[20.0, 0.0, 30.0, 10.0]), 0.0);
    }
}
