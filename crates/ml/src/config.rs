//! Everything atlas-ml reads from its environment.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::Result;
use atlas_core::{env, home};

pub struct Config {
    /// ATLAS_ML_BIND: loopback address the worker answers on
    /// (default 127.0.0.1:8786). Only atlas-server talks to it.
    pub bind: String,
    /// ATLAS_PHOTOS_DIR: library root (default ~/photos).
    pub photos_dir: PathBuf,
    /// ATLAS_LLAMA_SERVER: the llama.cpp server binary
    /// (default /usr/local/lib/atlas/llama-server).
    pub llama_server: PathBuf,
    /// ATLAS_LLAMA_PORT: loopback port the llama.cpp server gets (default 8785).
    pub llama_port: u16,
    /// ATLAS_EMBED_MODEL / ATLAS_EMBED_MMPROJ: the embedding model and its
    /// vision projector as GGUF
    /// (default <models>/wemm-embedding/{model,mmproj}.gguf).
    pub embed_model: PathBuf,
    pub embed_mmproj: PathBuf,
    /// ATLAS_EMBED_DEVICE: the GPU the embedding model runs on, as
    /// `llama-server --list-devices` names it (default CUDA0). There is no
    /// CPU fallback: without this device the model does not load and the
    /// queue waits.
    pub device: String,
    /// ATLAS_ML_IDLE_S: seconds without work after which the embedding model
    /// is unloaded and its GPU memory returned (default 600).
    pub idle: Duration,
    /// ATLAS_EMBED_SLOTS: requests the embedding server takes side by side
    /// (default 6, at least 3). The queue uses all but two, so a search (two
    /// requests) never waits behind the backlog; four jobs at once keep the
    /// GPU busy while a clip's frames are read on the CPU.
    pub slots: u32,
    /// ATLAS_FACE_DETECTOR / ATLAS_FACE_RECOGNIZER: SCRFD (buffalo_l) and
    /// AdaFace IR-101 as ONNX (default <models>/buffalo_l/det_10g.onnx,
    /// <models>/adaface/ir101.onnx).
    pub face_detector: PathBuf,
    pub face_recognizer: PathBuf,
    /// RF-DETR Large and pet-recognition-large (default
    /// <models>/rfdetr/large.onnx, <models>/pet/model.onnx).
    pub animal_detector: PathBuf,
    pub animal_identifier: PathBuf,
    /// PP-OCRv6 medium: detector, recognizer and its dictionary (default
    /// <models>/ocr6/{det.onnx,rec.onnx,dict.txt}).
    pub text_detector: PathBuf,
    pub text_recognizer: PathBuf,
    pub text_dictionary: PathBuf,
    /// ATLAS_VISION_JOBS: assets the vision stage prepares side by side
    /// (decoding originals, reading video frames) while one at a time is on
    /// the GPU (default 6: decoding originals and the database work take most
    /// of an asset's second; the GPU part is a fraction of it).
    pub vision_jobs: usize,
}

impl Config {
    pub fn from_env() -> Result<Self> {
        let home = home();
        // ATLAS_MODELS_DIR: where the model files live (default ~/models)
        let models = PathBuf::from(env("ATLAS_MODELS_DIR").unwrap_or(format!("{home}/models")));
        let path = |key: &str, default: PathBuf| env(key).map(PathBuf::from).unwrap_or(default);
        Ok(Self {
            bind: env("ATLAS_ML_BIND").unwrap_or_else(|| "127.0.0.1:8786".into()),
            photos_dir: PathBuf::from(env("ATLAS_PHOTOS_DIR").unwrap_or(format!("{home}/photos"))),
            llama_server: path("ATLAS_LLAMA_SERVER", "/usr/local/lib/atlas/llama-server".into()),
            llama_port: env("ATLAS_LLAMA_PORT").and_then(|v| v.parse().ok()).unwrap_or(8785),
            embed_model: path("ATLAS_EMBED_MODEL", models.join("wemm-embedding/model.gguf")),
            embed_mmproj: path("ATLAS_EMBED_MMPROJ", models.join("wemm-embedding/mmproj.gguf")),
            device: env("ATLAS_EMBED_DEVICE").unwrap_or_else(|| "CUDA0".into()),
            idle: Duration::from_secs(env("ATLAS_ML_IDLE_S").and_then(|v| v.parse().ok()).unwrap_or(600)),
            slots: env("ATLAS_EMBED_SLOTS").and_then(|v| v.parse().ok()).unwrap_or(6).clamp(3, 8),
            face_detector: path("ATLAS_FACE_DETECTOR", models.join("buffalo_l/det_10g.onnx")),
            face_recognizer: path("ATLAS_FACE_RECOGNIZER", models.join("adaface/ir101.onnx")),
            animal_detector: models.join("rfdetr/large.onnx"),
            animal_identifier: models.join("pet/model.onnx"),
            text_detector: models.join("ocr6/det.onnx"),
            text_recognizer: models.join("ocr6/rec.onnx"),
            text_dictionary: models.join("ocr6/dict.txt"),
            vision_jobs: env("ATLAS_VISION_JOBS").and_then(|v| v.parse().ok()).unwrap_or(6).clamp(1, 12),
        })
    }

    pub fn thumb(&self, id: &str) -> Option<PathBuf> {
        [2048, 512]
            .into_iter()
            .map(|size| self.photos_dir.join("thumbs").join(format!("{id}.{size}.webp")))
            .find(|p| p.exists())
    }

    /// Every model file the vision stage needs.
    pub fn vision_models(&self) -> [&PathBuf; 7] {
        [
            &self.face_detector,
            &self.face_recognizer,
            &self.animal_detector,
            &self.animal_identifier,
            &self.text_detector,
            &self.text_recognizer,
            &self.text_dictionary,
        ]
    }

    pub fn faces_dir(&self) -> PathBuf {
        self.photos_dir.join("faces")
    }
}
