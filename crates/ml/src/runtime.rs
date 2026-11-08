//! ONNX Runtime for the vision models: the GPU build loaded at start
//! (`ORT_DYLIB_PATH`, installed by scripts/atlas/models.sh), on the GPU
//! within a memory budget, on the CPU when there is no room for it.
//!
//! The card is shared with the embedding model (llama.cpp), which takes
//! about 4.7 GB of it whenever a search or an upload needs it. The vision
//! stage therefore never takes more than the card minus that reserve:
//! every model gets a fixed share as its arena's hard limit, cuDNN picks
//! convolution algorithms without maximum-size workspaces, and a model that
//! cannot get the memory it needs fails its run (and the stage falls back
//! to the CPU, vision/mod.rs) instead of taking the card from the embeddings.
//! Measured 2026-11-07 on the 8 GB RTX 4060 Ti: unbounded, the stage peaked
//! at 3.5 GB, which with the embedding model would have filled the card.

use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result};
use ort::session::{RunOptions, Session};
use ort::session::builder::GraphOptimizationLevel;

/// What the embedding model needs on the card, with headroom (MiB).
const EMBEDDING_RESERVE_MB: u64 = 5 * 1024;
/// Below this much room the vision stage is better off on the CPU (MiB).
const MIN_VISION_MB: u64 = 1536;

/// Where a model runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Device {
    /// on the GPU with at most this many bytes of arena
    Gpu { limit: usize },
    Cpu,
}

/// Loads the runtime once. Without it nothing in the vision stage runs; the
/// embeddings (llama.cpp) are unaffected.
pub fn init() -> Result<()> {
    let path = std::env::var("ORT_DYLIB_PATH").unwrap_or_else(|_| {
        "/usr/local/lib/atlas/onnxruntime/onnxruntime/capi/libonnxruntime.so.1.31.1".into()
    });
    ort::init_from(&path)
        .with_context(|| format!("cannot load ONNX Runtime from {path}"))?
        .with_name("atlas-ml")
        .commit();
    Ok(())
}

/// The vision stage's share of the GPU in MiB: `ATLAS_VISION_VRAM_MB` if
/// set, else the card's memory less the embedding model's reserve. None:
/// no usable GPU, or too little room left on it.
pub fn vision_budget_mb() -> Option<u64> {
    if let Some(mb) = atlas_core::env("ATLAS_VISION_VRAM_MB").and_then(|v| v.parse::<u64>().ok()) {
        return (mb >= MIN_VISION_MB).then_some(mb);
    }
    let out = Command::new("nvidia-smi").args(["--query-gpu=memory.total", "--format=csv,noheader,nounits"]).output().ok()?;
    let total: u64 = String::from_utf8_lossy(&out.stdout).lines().next()?.trim().parse().ok()?;
    let budget = total.saturating_sub(EMBEDDING_RESERVE_MB);
    (budget >= MIN_VISION_MB).then_some(budget)
}

/// A loaded model and where it runs.
pub struct Model {
    pub session: Session,
    gpu: bool,
}

impl Model {
    /// Options for one run. On the GPU the arena gives back what the run
    /// took once it is over: the models run one after another, so the
    /// stage's footprint is their weights plus the largest single run, not
    /// the sum of every model's largest run (3.5 GB measured without, about
    /// 2.5 GB with, 2026-11-07).
    pub fn options(&self) -> Result<RunOptions> {
        let mut options = RunOptions::new()?;
        if self.gpu {
            options.set("memory.enable_memory_arena_shrinkage", "gpu:0")?;
        }
        Ok(options)
    }
}

/// A model on `device`.
pub fn session(path: &Path, device: Device) -> Result<Model> {
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(8);
    let builder = Session::builder()
        .map_err(|e| anyhow::anyhow!("onnxruntime: {e}"))?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .map_err(|e| anyhow::anyhow!("onnxruntime: {e}"))?
        .with_intra_threads(threads)
        .map_err(|e| anyhow::anyhow!("onnxruntime: {e}"))?;
    let mut builder = match device {
        Device::Gpu { limit } => {
            let cuda = ort::ep::CUDA::default()
                .with_memory_limit(limit)
                .with_arena_extend_strategy(ort::ep::ArenaExtendStrategy::SameAsRequested)
                .with_conv_algorithm_search(ort::ep::cuda::ConvAlgorithmSearch::Heuristic)
                .with_conv_max_workspace(false)
                .build()
                .error_on_failure();
            builder.with_execution_providers([cuda]).map_err(|e| anyhow::anyhow!("onnxruntime: {e}"))?
        }
        Device::Cpu => builder,
    };
    let session = builder.commit_from_file(path).with_context(|| format!("cannot load {}", path.display()))?;
    Ok(Model { session, gpu: device != Device::Cpu })
}
