//! The vision stage (the queue's `faces` job): everything the search needs
//! from an asset's pixels.
//!
//! What it looks at:
//!   * a photo: its original at full resolution (up to 4096 px on the long
//!     side), not the 2048 px preview: the back row of a group photo has
//!     twice the pixels to be recognized by
//!   * a video: about one frame a second (at most 60, spread over longer
//!     clips), with the poster frame (1 s in) among them
//!
//! What it finds:
//!   * faces in every frame (faces.rs); in a video the same person's faces
//!     are one track, stored once, at its best frame
//!   * animals (animals.rs), told apart individually where large enough
//!   * text (ocr.rs), in a photo and in four frames of a video
//!
//! Who they are: a face found again where a face was before takes that
//! face's person (names survive every re-run); otherwise the person whose
//! known faces it resembles most, when that is clear (`assign`). The rest
//! wait, unassigned, for the grouping pass (grouping.rs) to find them
//! someone or gather them into someone new. A face of a named person that
//! the detector does not find again is kept as it was.
//!
//!   frames.rs   the pixels: a photo, or a clip's sampled frames
//!   engines.rs  the models, loaded within the GPU budget, over every frame
//!   tracks.rs   a video's detections, one per person and animal
//!   assign.rs   who a face is, and the thresholds that decide it
//!   store.rs    faces, people, the graph and the text, stored

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::Result;

use crate::jobs::Outcome;
use crate::{Worker, runtime};

mod assign;
mod engines;
mod frames;
mod store;
mod tracks;

pub use assign::{
    ASSIGN_ANIMAL, ASSIGN_FACE, ASSIGN_MARGIN, ASSIGN_POOR_FACE, ASSIGN_SMALL_FACE, MIN_CLARITY_ASSIGN, MIN_CLARITY_GROUP,
    MIN_SCORE_GROUP, MIN_WIDTH_GROUP, SMALL_FACE, decide, refresh_people,
};
use engines::{Engines, LoadArgs, analyze};
use frames::frames;
use tracks::tracks;

/// The face recognizer, as stored in faces.model.
pub const MODEL: &str = "adaface-ir101";

/// The engines, loaded on the first job and dropped again when the queue
/// runs dry: on the GPU, and on the CPU for a job the GPU could not run.
#[derive(Default)]
pub struct Loaded {
    gpu: Option<Engines>,
    cpu: Option<Engines>,
}

pub type Shared = Arc<Mutex<Loaded>>;

pub async fn run(worker: &Worker, engines: &Shared, id: &str) -> Result<Outcome> {
    let c = worker.pool.get().await?;
    let Some(row) = c.query_opt("SELECT type, orig_path FROM assets WHERE id = $1", &[&id]).await? else {
        return Ok(Outcome::Done); // deleted meanwhile
    };
    drop(c);
    let video = row.get::<_, &str>(0) == "video";
    let original = PathBuf::from(row.get::<_, String>(1));
    let thumb = worker.cfg.thumb(id);

    let frames = {
        let (original, thumb) = (original.clone(), thumb.clone());
        tokio::task::spawn_blocking(move || frames(&original, thumb.as_deref(), video)).await??
    };
    let Some(frames) = frames else { return Ok(Outcome::NotReady) };

    // the models, one asset at a time
    let frames = Arc::new(frames);
    let args = Engines::load_args(worker);
    let (found, lines) = {
        let (engines, frames) = (engines.clone(), frames.clone());
        tokio::task::spawn_blocking(move || -> Result<_> {
            let mut loaded = engines.lock().unwrap_or_else(|e| e.into_inner());
            if loaded.gpu.is_none() {
                let engines = args.load(true)?;
                tracing::info!("vision models loaded ({})", if engines.gpu { "GPU" } else { "CPU" });
                loaded.gpu = Some(engines);
            }
            let first = analyze(loaded.gpu.as_mut().expect("just loaded"), &frames);
            match first {
                Ok(result) => Ok(result),
                // the GPU had no room for this one (or failed otherwise):
                // this job on the CPU, the next one on the GPU again
                Err(e) if loaded.gpu.as_ref().is_some_and(|g| g.gpu) => {
                    tracing::warn!("vision on the GPU failed ({e:#}); this asset on the CPU");
                    if loaded.cpu.is_none() {
                        loaded.cpu = Some(args.load(false)?);
                    }
                    analyze(loaded.cpu.as_mut().expect("just loaded"), &frames)
                }
                Err(e) => Err(e),
            }
        })
        .await??
    };
    store::store(worker, id, video, found, &lines, &frames).await?;
    Ok(Outcome::Done)
}

/// `atlas-ml analyze FILE...`: what the stage sees in files, printed, with
/// nothing stored. For checking the models on the box.
pub fn analyze_files(worker_paths: [PathBuf; 7], files: &[String]) -> Result<()> {
    let args = LoadArgs { paths: worker_paths };
    let mut engines = args.load(std::env::var("ATLAS_ANALYZE_CPU").is_err())?;
    eprintln!("budget {:?} MiB, on the {}", runtime::vision_budget_mb(), if engines.gpu { "GPU" } else { "CPU" });
    let repeat: usize = std::env::var("ATLAS_ANALYZE_REPEAT").ok().and_then(|v| v.parse().ok()).unwrap_or(1);
    for file in files.iter().flat_map(|f| std::iter::repeat_n(f, repeat)) {
        let path = Path::new(file);
        let video = matches!(
            path.extension().map(|e| e.to_string_lossy().to_lowercase()).as_deref(),
            Some("mov" | "mp4" | "m4v" | "3gp" | "mkv" | "webm" | "avi")
        );
        let started = std::time::Instant::now();
        let Some(frames) = frames(path, None, video)? else { continue };
        let read = started.elapsed();
        let (found, lines) = analyze(&mut engines, &frames)?;
        let found = if video { tracks(found) } else { found };
        let (w, h) = frames[0].image.dimensions();
        println!(
            "{file}: {} frame(s) of {w}x{h}, read in {read:.1?}, analyzed in {:.1?}",
            frames.len(),
            started.elapsed() - read
        );
        let faces = found.iter().filter(|f| f.kind == "person").count();
        println!("  faces: {faces}");
        for f in found.iter().filter(|f| f.kind == "person") {
            println!(
                "    {:>5.0} px wide, score {:.2}, clarity {:.1}, frame {}, box {:?}",
                f.width_px,
                f.score,
                f.clarity.unwrap_or(0.0),
                f.frame,
                f.bbox
            );
        }
        for f in found.iter().filter(|f| f.kind != "person") {
            println!("  {}: {:.0} px wide, score {:.2}, identifiable {}, box {:?}", f.kind, f.width_px, f.score, f.look.is_some(), f.bbox);
        }
        if !lines.is_empty() {
            println!("  text: {}", lines.join(" | "));
        }
    }
    Ok(())
}
