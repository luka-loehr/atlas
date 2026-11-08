//! The vision models: loaded on the GPU within the stage's budget (or all on
//! the CPU), and run over every frame they apply to.

use std::path::PathBuf;

use anyhow::Result;

use super::frames::Frame;
use crate::Worker;
use crate::animals::AnimalEngine;
use crate::faces::FaceEngine;
use crate::ocr::TextEngine;
use crate::runtime::{self, Device};

pub struct Engines {
    pub(super) faces: FaceEngine,
    pub(super) animals: AnimalEngine,
    pub(super) text: TextEngine,
    /// on the GPU (within the budget) or all on the CPU
    pub(super) gpu: bool,
}

/// Each GPU model's arena limit as a share of the vision stage's VRAM
/// budget (SCRFD, AdaFace, RF-DETR, text detector, text recognizer). The
/// models run one at a time and give back what a run took (runtime::Model),
/// so each may use most of the budget for its run; what stays resident is
/// only the weights (about 0.6 GB). Measured peaks above that, 2026-11-07:
/// faces 0.7 GB, animals 0.6 GB, text 1.6 GB (a 1536 px page). The pet
/// model always runs on the CPU.
const SHARES: [f64; 5] = [0.6, 0.6, 0.6, 0.7, 0.6];

fn devices(gpu: bool) -> [Device; 5] {
    match runtime::vision_budget_mb().filter(|_| gpu) {
        Some(mb) => SHARES.map(|share| Device::Gpu {
            limit: (mb as f64 * share * 1024.0 * 1024.0) as usize,
        }),
        None => [Device::Cpu; 5],
    }
}

/// One thing found, before it is stored.
pub(super) struct Found {
    /// 'person' or a species
    pub(super) kind: &'static str,
    pub(super) frame: usize,
    /// x1, y1, x2, y2 relative to the frame
    pub(super) bbox: [f32; 4],
    pub(super) width_px: f32,
    pub(super) score: f32,
    /// AdaFace's quality estimate (faces only)
    pub(super) clarity: Option<f32>,
    pub(super) embedding: Option<Vec<f32>>,
    pub(super) look: Option<Vec<f32>>,
    pub(super) person: Option<i64>,
    /// the earlier face (same place, same asset) this one replaces
    pub(super) replaces: Option<i64>,
    /// people it must never be assigned to (faces.vetoed)
    pub(super) vetoed: Vec<i64>,
}

/// What loading the engines needs, detached from the worker so it can move
/// to the blocking pool.
pub struct LoadArgs {
    pub(super) paths: [PathBuf; 7],
}

impl Engines {
    pub(super) fn load_args(worker: &Worker) -> LoadArgs {
        LoadArgs {
            paths: worker.cfg.vision_models().map(|p| p.clone()),
        }
    }
}

impl LoadArgs {
    pub(super) fn load(&self, gpu: bool) -> Result<Engines> {
        for path in &self.paths {
            anyhow::ensure!(
                path.exists(),
                "missing model file {} (scripts/atlas/models.sh)",
                path.display()
            );
        }
        let [
            face_detector,
            face_recognizer,
            animal_detector,
            animal_identifier,
            text_detector,
            text_recognizer,
            dictionary,
        ] = &self.paths;
        let d = devices(gpu);
        Ok(Engines {
            faces: FaceEngine::load(face_detector, face_recognizer, [d[0], d[1]])?,
            animals: AnimalEngine::load(animal_detector, animal_identifier, d[2])?,
            text: TextEngine::load(text_detector, text_recognizer, dictionary, [d[3], d[4]])?,
            gpu: d[0] != Device::Cpu,
        })
    }
}

/// Every model over every frame it applies to.
pub(super) fn analyze(
    engines: &mut Engines,
    frames: &[Frame],
) -> Result<(Vec<Found>, Vec<String>)> {
    let only = std::env::var("ATLAS_ANALYZE_ONLY").unwrap_or_default();
    let on = |stage: &str| only.is_empty() || only.contains(stage);
    let mut found = Vec::new();
    let mut lines: Vec<String> = Vec::new();
    for (i, frame) in frames.iter().enumerate() {
        let (w, h) = (frame.image.width() as f32, frame.image.height() as f32);
        let relative = |b: [f32; 4]| {
            [
                (b[0] / w).clamp(0.0, 1.0),
                (b[1] / h).clamp(0.0, 1.0),
                (b[2] / w).clamp(0.0, 1.0),
                (b[3] / h).clamp(0.0, 1.0),
            ]
        };
        for face in if on("faces") {
            engines.faces.analyze(&frame.image)?
        } else {
            Vec::new()
        } {
            found.push(Found {
                kind: "person",
                frame: i,
                bbox: relative(face.bbox),
                width_px: face.bbox[2] - face.bbox[0],
                score: face.score,
                clarity: Some(face.clarity),
                embedding: Some(face.embedding),
                look: None,
                person: None,
                replaces: None,
                vetoed: Vec::new(),
            });
        }
        if frame.animals && on("animals") {
            for animal in engines.animals.find(&frame.image)? {
                found.push(Found {
                    kind: animal.species,
                    frame: i,
                    bbox: relative(animal.bbox),
                    width_px: animal.bbox[2] - animal.bbox[0],
                    score: animal.score,
                    clarity: None,
                    embedding: None,
                    look: animal.look,
                    person: None,
                    replaces: None,
                    vetoed: Vec::new(),
                });
            }
        }
        if frame.text && on("text") {
            for line in engines.text.read(&frame.image)? {
                if !lines.contains(&line.text) {
                    lines.push(line.text);
                }
            }
        }
    }
    Ok((found, lines))
}
