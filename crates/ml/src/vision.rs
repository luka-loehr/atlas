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

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use image::RgbImage;
use pgvector::Vector;
use tokio_postgres::Transaction;

use crate::animals::{AnimalEngine, iou};
use crate::faces::FaceEngine;
use crate::ocr::TextEngine;
use crate::runtime::{self, Device};
use crate::{Worker, pixels};

pub const MODEL: &str = "adaface-ir101";
/// A photo is analyzed at most this large (long side, pixels).
const MAX_SIDE: u32 = 4096;
/// Video frames are analyzed at most this large.
const MAX_FRAME_SIDE: u32 = 1920;
const MAX_FRAMES: usize = 60;
/// Animals are looked for in every this many sampled frames of a video.
const ANIMAL_EVERY: usize = 4;
/// A redetected face takes the person of the face it overlaps this much.
const SAME_PLACE: f32 = 0.4;
/// Two faces of one video this similar are the same person's track.
const SAME_TRACK: f32 = 0.45;
const SAME_ANIMAL_TRACK: f32 = 0.5;

/// Who a face is, from the faces already known: the mean of its closest
/// faces of a person must reach this ...
pub const ASSIGN_FACE: f32 = 0.38;
/// ... this for a face narrower than `SMALL_FACE` pixels ...
pub const ASSIGN_SMALL_FACE: f32 = 0.42;
pub const SMALL_FACE: f32 = 32.0;
/// ... and beat the runner-up person by this much. Calibrated on the owner's
/// named faces with AdaFace (2026-11-07): two strangers' faces reach 0.26 in
/// one pair of a thousand and 0.40 in one of ten thousand; half of all pairs
/// of one person's faces are above 0.57.
pub const ASSIGN_MARGIN: f32 = 0.05;
/// The same for animals with pet-recognition-large: one individual's photos
/// sit at about 0.6-0.7, different animals at about 0-0.2.
pub const ASSIGN_ANIMAL: f32 = 0.45;
/// A face is named by resemblance only when AdaFace can make it out at
/// least this well ...
pub const MIN_CLARITY_ASSIGN: f32 = 17.0;
/// ... and a new person is gathered only from faces this clear and this
/// surely detected. Measured 2026-11-07: faces of named people 19-24 (scores
/// 0.75-0.89); a junk cluster the first grouping made of concert crowds,
/// walls and toys 13-22, median 17 (scores 0.5-0.7).
pub const MIN_CLARITY_GROUP: f32 = 20.0;
pub const MIN_SCORE_GROUP: f32 = 0.7;

pub struct Engines {
    faces: FaceEngine,
    animals: AnimalEngine,
    text: TextEngine,
    /// on the GPU (within the budget) or all on the CPU
    gpu: bool,
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
        Some(mb) => SHARES.map(|share| Device::Gpu { limit: (mb as f64 * share * 1024.0 * 1024.0) as usize }),
        None => [Device::Cpu; 5],
    }
}

/// The engines, loaded on the first job and dropped again when the queue
/// runs dry: on the GPU, and on the CPU for a job the GPU could not run.
#[derive(Default)]
pub struct Loaded {
    gpu: Option<Engines>,
    cpu: Option<Engines>,
}

pub type Shared = Arc<Mutex<Loaded>>;

struct Frame {
    image: RgbImage,
    /// seconds into the clip; None for a still
    at: Option<f32>,
    /// the frame the server's poster was taken from (where the faces of
    /// earlier versions of this stage were found)
    poster: bool,
    animals: bool,
    text: bool,
}

/// One thing found, before it is stored.
struct Found {
    /// 'person' or a species
    kind: &'static str,
    frame: usize,
    /// x1, y1, x2, y2 relative to the frame
    bbox: [f32; 4],
    width_px: f32,
    score: f32,
    /// AdaFace's quality estimate (faces only)
    clarity: Option<f32>,
    embedding: Option<Vec<f32>>,
    look: Option<Vec<f32>>,
    person: Option<i64>,
    /// the earlier face (same place, same asset) this one replaces
    replaces: Option<i64>,
}

pub enum Outcome {
    Done,
    NotReady,
}

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
    store(worker, id, video, found, &lines, &frames).await?;
    Ok(Outcome::Done)
}

/// What loading the engines needs, detached from the worker so it can move
/// to the blocking pool.
pub struct LoadArgs {
    paths: [PathBuf; 7],
}

impl Engines {
    fn load_args(worker: &Worker) -> LoadArgs {
        LoadArgs { paths: worker.cfg.vision_models().map(|p| p.clone()) }
    }
}

impl LoadArgs {
    fn load(&self, gpu: bool) -> Result<Engines> {
        for path in &self.paths {
            anyhow::ensure!(path.exists(), "missing model file {} (scripts/atlas/models.sh)", path.display());
        }
        let [face_detector, face_recognizer, animal_detector, animal_identifier, text_detector, text_recognizer, dictionary] =
            &self.paths;
        let d = devices(gpu);
        Ok(Engines {
            faces: FaceEngine::load(face_detector, face_recognizer, [d[0], d[1]])?,
            animals: AnimalEngine::load(animal_detector, animal_identifier, d[2])?,
            text: TextEngine::load(text_detector, text_recognizer, dictionary, [d[3], d[4]])?,
            gpu: d[0] != Device::Cpu,
        })
    }
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

/// The pixels to look at; None when there is nothing to read yet.
fn frames(original: &Path, thumb: Option<&Path>, video: bool) -> Result<Option<Vec<Frame>>> {
    if !video {
        let image = match atlas_core::decode::decode(original) {
            Ok(decoded) => decoded.rgb,
            Err(e) => match thumb {
                // a format the decoder does not read (some RAW files): the
                // preview the server made from it
                Some(thumb) => {
                    tracing::debug!("{}: {e:#}; using the preview", original.display());
                    pixels::open(thumb)?
                }
                None if original.exists() => return Err(e),
                None => return Ok(None),
            },
        };
        let image = fit(image, MAX_SIDE)?;
        return Ok(Some(vec![Frame { image, at: None, poster: true, animals: true, text: true }]));
    }

    let sampled = original.exists().then(|| sample_video(original)).transpose();
    match sampled {
        Ok(Some(frames)) if !frames.is_empty() => Ok(Some(frames)),
        other => {
            if let Err(e) = other {
                tracing::warn!("{}: cannot read frames: {e:#}; using the poster", original.display());
            }
            // the poster the server made, as the clip's only frame
            let Some(thumb) = thumb else { return Ok(None) };
            let image = pixels::open(thumb)?;
            Ok(Some(vec![Frame { image, at: Some(1.0), poster: true, animals: true, text: true }]))
        }
    }
}

fn sample_video(path: &Path) -> Result<Vec<Frame>> {
    let clip = pixels::probe(path)?;
    let duration = clip.times.last().copied().unwrap_or(0.0);
    let times = sample_times(duration);
    let text_at: HashSet<usize> = text_frames(times.len());
    let mut frames = Vec::with_capacity(times.len());
    for (chunk_index, chunk) in times.chunks(8).enumerate() {
        let decoded = pixels::frames_at(path, chunk, clip.hdr)?;
        for (k, image) in decoded.into_iter().enumerate() {
            let i = chunk_index * 8 + k;
            let at = times[i];
            frames.push(Frame {
                image: fit(image, MAX_FRAME_SIDE)?,
                at: Some(at as f32),
                poster: (at - poster_time(duration)).abs() < 1e-6,
                animals: i % ANIMAL_EVERY == 0,
                text: text_at.contains(&i),
            });
        }
    }
    Ok(frames)
}

/// The server's poster is 1 s into a clip, or its first frame if shorter.
fn poster_time(duration: f64) -> f64 {
    if duration > 1.0 { 1.0 } else { 0.0 }
}

/// About one frame a second, at most [`MAX_FRAMES`], always including the
/// poster's moment.
fn sample_times(duration: f64) -> Vec<f64> {
    let step = (duration / MAX_FRAMES as f64).max(1.0);
    let mut times: Vec<f64> = (0..MAX_FRAMES).map(|k| k as f64 * step).take_while(|&t| t <= duration).collect();
    if times.is_empty() {
        times.push(0.0);
    }
    let poster = poster_time(duration);
    if !times.iter().any(|&t| (t - poster).abs() < 1e-6) {
        times.push(poster);
        times.sort_by(f64::total_cmp);
    }
    times
}

/// Which sampled frames are read for text: the first and three spread over
/// the clip.
fn text_frames(count: usize) -> HashSet<usize> {
    [0, count / 4, count / 2, 3 * count / 4].into_iter().filter(|&i| i < count).collect()
}

fn fit(image: RgbImage, max: u32) -> Result<RgbImage> {
    let (w, h) = image.dimensions();
    if w.max(h) <= max {
        return Ok(image);
    }
    let scale = f64::from(max) / f64::from(w.max(h));
    pixels::resize(
        &image,
        ((f64::from(w) * scale).round() as u32).max(1),
        ((f64::from(h) * scale).round() as u32).max(1),
        fast_image_resize::FilterType::Lanczos3,
    )
}

/// Every model over every frame it applies to.
fn analyze(engines: &mut Engines, frames: &[Frame]) -> Result<(Vec<Found>, Vec<String>)> {
    let only = std::env::var("ATLAS_ANALYZE_ONLY").unwrap_or_default();
    let on = |stage: &str| only.is_empty() || only.contains(stage);
    let mut found = Vec::new();
    let mut lines: Vec<String> = Vec::new();
    for (i, frame) in frames.iter().enumerate() {
        let (w, h) = (frame.image.width() as f32, frame.image.height() as f32);
        let relative = |b: [f32; 4]| {
            [(b[0] / w).clamp(0.0, 1.0), (b[1] / h).clamp(0.0, 1.0), (b[2] / w).clamp(0.0, 1.0), (b[3] / h).clamp(0.0, 1.0)]
        };
        for face in if on("faces") { engines.faces.analyze(&frame.image)? } else { Vec::new() } {
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

/// How much a detection is worth keeping as the face of its track: large
/// and sure.
fn worth(f: &Found) -> f32 {
    f.width_px * f.score
}

fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

/// A video's detections, one per person and per animal: the same face in
/// many frames is one track, kept at its best frame. A track takes the
/// person any of its detections inherited.
fn tracks(found: Vec<Found>) -> Vec<Found> {
    let mut sorted = found;
    sorted.sort_by(|a, b| worth(b).total_cmp(&worth(a)));
    let mut kept: Vec<Found> = Vec::new();
    for f in sorted {
        let same = kept.iter_mut().find(|k| {
            k.kind == f.kind
                && match (&k.embedding, &f.embedding, &k.look, &f.look) {
                    (Some(a), Some(b), _, _) => dot(a, b) >= SAME_TRACK,
                    (_, _, Some(a), Some(b)) => dot(a, b) >= SAME_ANIMAL_TRACK,
                    // animals too small to identify: one per species
                    (None, None, None, None) => f.kind != "person",
                    _ => false,
                }
        });
        match same {
            Some(track) => {
                if track.person.is_none() {
                    track.person = f.person;
                }
                if track.replaces.is_none() {
                    track.replaces = f.replaces;
                }
            }
            None => kept.push(f),
        }
    }
    kept
}

struct Previous {
    id: i64,
    person: Option<i64>,
    named: bool,
    kind: String,
    bbox: [f32; 4],
}

async fn store(worker: &Worker, id: &str, video: bool, mut found: Vec<Found>, lines: &[String], frames: &[Frame]) -> Result<()> {
    let mut c = worker.pool.get().await?;
    let tx = c.transaction().await?;
    let previous: Vec<Previous> = tx
        .query(
            "SELECT f.id, f.person_id, p.display_name IS NOT NULL, f.kind, f.bbox
             FROM faces f LEFT JOIN persons p ON p.id = f.person_id
             WHERE f.asset_id = $1",
            &[&id],
        )
        .await?
        .iter()
        .map(|r| {
            let b: Vec<f32> = r.get::<_, Option<Vec<f32>>>(4).unwrap_or_default();
            Previous {
                id: r.get(0),
                person: r.get(1),
                named: r.get(2),
                kind: r.get(3),
                bbox: [0, 1, 2, 3].map(|i| b.get(i).copied().unwrap_or(0.0)),
            }
        })
        .collect();

    // a face found where one was before is that face's person: a name never
    // depends on what the recognizer thinks
    let mut inherited: HashSet<i64> = HashSet::new();
    let mut order: Vec<usize> = (0..found.len()).filter(|&i| frames[found[i].frame].poster).collect();
    order.sort_by(|&a, &b| worth(&found[b]).total_cmp(&worth(&found[a])));
    for i in order {
        let best = previous
            .iter()
            .filter(|p| p.kind == found[i].kind && p.person.is_some() && !inherited.contains(&p.id))
            .map(|p| (p, iou(&p.bbox, &found[i].bbox)))
            .filter(|(_, overlap)| *overlap >= SAME_PLACE)
            .max_by(|a, b| a.1.total_cmp(&b.1));
        if let Some((p, _)) = best {
            inherited.insert(p.id);
            found[i].person = p.person;
            found[i].replaces = Some(p.id);
        }
    }
    if video {
        found = tracks(found);
    }

    // the rest by resemblance
    for f in found.iter_mut().filter(|f| f.person.is_none()) {
        f.person = match (&f.embedding, &f.look) {
            (Some(_), _) if f.clarity.unwrap_or(0.0) < MIN_CLARITY_ASSIGN => None,
            (Some(embedding), _) => assign_face(&tx, embedding, f.width_px).await?,
            (None, Some(look)) => assign_animal(&tx, f.kind, look).await?,
            (None, None) => None,
        };
    }

    // what goes: faces found again (replaced) and faces nobody named; a
    // named face the detector missed this time stays
    let dropped: Vec<i64> = previous.iter().filter(|p| inherited.contains(&p.id) || !p.named).map(|p| p.id).collect();

    let mut crops = Vec::new();
    let mut touched: HashSet<i64> = previous.iter().filter_map(|p| p.person).collect();
    for f in &found {
        let embedding = f.embedding.clone().map(Vector::from);
        let look = f.look.clone().map(Vector::from);
        let at = frames[f.frame].at;
        let model = f.embedding.as_ref().map(|_| MODEL);
        let face_id: i64 = tx
            .query_one(
                "INSERT INTO faces (asset_id, person_id, bbox, quality, embedding, kind, look, frame_s, model, width_px, clarity)
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, coalesce($9, 'none'), $10, $11) RETURNING id",
                &[&id, &f.person, &f.bbox.to_vec(), &f.score, &embedding, &f.kind, &look, &at, &model, &f.width_px, &f.clarity],
            )
            .await?
            .get(0);
        if let Some(person) = f.person {
            touched.insert(person);
            tx.execute("UPDATE persons SET cover_face_id = $2 WHERE id = $1 AND cover_face_id IS NULL", &[&person, &face_id])
                .await?;
        }
        // a cover the owner chose moves to the face that replaces it
        if let Some(old) = f.replaces {
            tx.execute("UPDATE persons SET cover_face_id = $2 WHERE cover_face_id = $1", &[&old, &face_id]).await?;
        }
        crops.push((face_id, f.frame, f.bbox, f.kind == "person"));
    }
    tx.execute("DELETE FROM faces WHERE id = ANY($1)", &[&dropped]).await?;

    // the graph: who is in this asset
    tx.execute("DELETE FROM edges WHERE src_type = 'asset' AND src_id = $1 AND rel = 'depicts'", &[&id]).await?;
    tx.execute(
        "INSERT INTO edges (src_type, src_id, rel, dst_type, dst_id, confidence)
         SELECT DISTINCT 'asset', $1, 'depicts', 'person', person_id::text, 1.0
         FROM faces WHERE asset_id = $1 AND person_id IS NOT NULL
         ON CONFLICT DO NOTHING",
        &[&id],
    )
    .await?;
    let touched: Vec<i64> = touched.into_iter().collect();
    refresh_people(&tx, &touched).await?;

    // what it says
    if lines.is_empty() {
        tx.execute("DELETE FROM asset_text WHERE asset_id = $1", &[&id]).await?;
    } else {
        tx.execute(
            "INSERT INTO asset_text (asset_id, text, updated_at) VALUES ($1, $2, now())
             ON CONFLICT (asset_id) DO UPDATE SET text = EXCLUDED.text, updated_at = now()",
            &[&id, &lines.join("\n")],
        )
        .await?;
    }
    tx.commit().await?;

    let faces_dir = worker.cfg.faces_dir();
    tokio::task::block_in_place(|| {
        let _ = std::fs::create_dir_all(&faces_dir);
        for old in &dropped {
            let _ = std::fs::remove_file(faces_dir.join(format!("{old}.webp")));
        }
        for (face_id, frame, bbox, face) in crops {
            let image = &frames[frame].image;
            let (w, h) = (image.width() as f32, image.height() as f32);
            let px = [bbox[0] * w, bbox[1] * h, bbox[2] * w, bbox[3] * h];
            if let Err(e) = save_crop(image, px, if face { 1.5 } else { 1.15 }, &faces_dir.join(format!("{face_id}.webp"))) {
                tracing::warn!("crop {face_id}: {e:#}"); // cosmetic: never fails the job
            }
        }
    });
    Ok(())
}

/// The person whose known faces this face resembles clearly most.
pub async fn assign_face(tx: &Transaction<'_>, embedding: &[f32], width_px: f32) -> Result<Option<i64>> {
    let rows = tx
        .query(
            "SELECT f.person_id, 1 - (f.embedding <=> $1) FROM faces f
             JOIN persons p ON p.id = f.person_id AND p.merged_into IS NULL
             WHERE f.model = $2 AND f.kind = 'person' AND f.person_id IS NOT NULL
               AND coalesce(f.clarity, 99) >= $3
             ORDER BY f.embedding <=> $1 LIMIT 40",
            &[&Vector::from(embedding.to_vec()), &MODEL, &MIN_CLARITY_ASSIGN],
        )
        .await?;
    let neighbors: Vec<(i64, f32)> = rows.iter().map(|r| (r.get(0), r.get::<_, f64>(1) as f32)).collect();
    let threshold = if width_px < SMALL_FACE { ASSIGN_SMALL_FACE } else { ASSIGN_FACE };
    Ok(decide(&neighbors, threshold, ASSIGN_MARGIN))
}

pub async fn assign_animal(tx: &Transaction<'_>, species: &str, look: &[f32]) -> Result<Option<i64>> {
    let rows = tx
        .query(
            "SELECT f.person_id, 1 - (f.look <=> $1) FROM faces f
             JOIN persons p ON p.id = f.person_id AND p.merged_into IS NULL
             WHERE f.kind = $2 AND f.look IS NOT NULL AND f.person_id IS NOT NULL
             ORDER BY f.look <=> $1 LIMIT 40",
            &[&Vector::from(look.to_vec()), &species],
        )
        .await?;
    let neighbors: Vec<(i64, f32)> = rows.iter().map(|r| (r.get(0), r.get::<_, f64>(1) as f32)).collect();
    Ok(decide(&neighbors, ASSIGN_ANIMAL, ASSIGN_MARGIN))
}

/// From a face's nearest known faces (person, similarity): the person whose
/// closest three (or fewer) average at least `threshold` and beat every
/// other person's by `margin`. A person with a single face in reach needs
/// that face to clear the bar by a further 0.1: one look-alike is weak
/// evidence.
pub fn decide(neighbors: &[(i64, f32)], threshold: f32, margin: f32) -> Option<i64> {
    let mut by_person: std::collections::HashMap<i64, Vec<f32>> = std::collections::HashMap::new();
    for &(person, similarity) in neighbors {
        by_person.entry(person).or_default().push(similarity);
    }
    let mut scores: Vec<(i64, f32)> = by_person
        .into_iter()
        .map(|(person, mut s)| {
            s.sort_by(|a, b| b.total_cmp(a));
            let top = &s[..s.len().min(3)];
            let mean = top.iter().sum::<f32>() / top.len() as f32;
            (person, if top.len() == 1 { mean - 0.1 } else { mean })
        })
        .collect();
    scores.sort_by(|a, b| b.1.total_cmp(&a.1));
    let (best, score) = *scores.first()?;
    let runner_up = scores.get(1).map_or(f32::MIN, |s| s.1);
    (score >= threshold && score - runner_up >= margin).then_some(best)
}

/// Face counts and centroids follow the faces: the centroid of the current
/// recognizer's faces, an animal's mean look.
pub async fn refresh_people(tx: &Transaction<'_>, people: &[i64]) -> Result<()> {
    if people.is_empty() {
        return Ok(());
    }
    tx.execute(
        "UPDATE persons p SET face_count = c.n,
                centroid = coalesce(c.a, p.centroid), look = coalesce(c.l, p.look)
         FROM (SELECT person_id, count(*) AS n,
                      avg(embedding) FILTER (WHERE model = $2) AS a,
                      avg(look) AS l
               FROM faces WHERE person_id = ANY($1) GROUP BY person_id) c
         WHERE p.id = c.person_id",
        &[&people, &MODEL],
    )
    .await
    .context("refreshing people")?;
    Ok(())
}

/// A square avatar: the box with a margin, at most 256 px.
fn save_crop(image: &RgbImage, bbox: [f32; 4], margin: f32, path: &Path) -> Result<()> {
    let (w, h) = (image.width() as f32, image.height() as f32);
    let (cx, cy) = ((bbox[0] + bbox[2]) / 2.0, (bbox[1] + bbox[3]) / 2.0);
    let side = (bbox[2] - bbox[0]).max(bbox[3] - bbox[1]) * margin;
    let x0 = (cx - side / 2.0).max(0.0) as u32;
    let y0 = (cy - side / 2.0).max(0.0) as u32;
    let x1 = (cx + side / 2.0).min(w) as u32;
    let y1 = (cy + side / 2.0).min(h) as u32;
    anyhow::ensure!(x1 > x0 && y1 > y0, "empty crop");
    let crop = image::imageops::crop_imm(image, x0, y0, x1 - x0, y1 - y0).to_image();
    let scale = (256.0 / crop.width().max(crop.height()) as f32).min(1.0);
    let small = pixels::resize(
        &crop,
        ((crop.width() as f32 * scale) as u32).max(1),
        ((crop.height() as f32 * scale) as u32).max(1),
        fast_image_resize::FilterType::Lanczos3,
    )?;
    let encoded = webp::Encoder::from_rgb(small.as_raw(), small.width(), small.height()).encode(86.0);
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, &*encoded)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_clear_majority_decides() {
        let n = [(1, 0.6), (1, 0.55), (1, 0.5), (2, 0.45), (2, 0.4)];
        assert_eq!(decide(&n, 0.38, 0.05), Some(1));
    }

    #[test]
    fn a_close_race_or_a_weak_match_decides_nothing() {
        assert_eq!(decide(&[(1, 0.5), (1, 0.5), (2, 0.48), (2, 0.48)], 0.38, 0.05), None);
        assert_eq!(decide(&[(1, 0.3), (1, 0.3)], 0.38, 0.05), None);
        // one look-alike alone is not enough ...
        assert_eq!(decide(&[(1, 0.45)], 0.38, 0.05), None);
        // ... unless it is unmistakable
        assert_eq!(decide(&[(1, 0.6)], 0.38, 0.05), Some(1));
        assert_eq!(decide(&[], 0.38, 0.05), None);
    }

    #[test]
    fn videos_sample_about_a_frame_a_second_with_the_poster() {
        let t = sample_times(10.0);
        assert_eq!(t.len(), 11);
        assert!(t.contains(&1.0));
        let long = sample_times(600.0);
        assert!(long.len() <= MAX_FRAMES + 1);
        assert!(long.contains(&1.0));
        assert_eq!(sample_times(0.4), vec![0.0]);
    }

    #[test]
    fn a_track_keeps_its_best_detection_and_any_inherited_person() {
        let f = |w: f32, e: [f32; 2], person| Found {
            kind: "person",
            frame: 0,
            bbox: [0.0; 4],
            width_px: w,
            score: 1.0,
            clarity: None,
            embedding: Some(e.to_vec()),
            look: None,
            person,
            replaces: None,
        };
        let kept = tracks(vec![f(40.0, [1.0, 0.0], Some(7)), f(80.0, [0.99, 0.14], None), f(50.0, [0.0, 1.0], None)]);
        assert_eq!(kept.len(), 2);
        assert_eq!(kept[0].width_px, 80.0);
        assert_eq!(kept[0].person, Some(7));
    }
}
