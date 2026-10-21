//! The embedding model, behind a llama.cpp server this process owns.
//!
//! The server is started on first use and stopped after a stretch of
//! idleness, which returns its GPU memory. It has a few slots, so requests
//! run side by side: the lock here only guards starting and stopping it. It
//! runs on the GPU only: pinned to one CUDA device with every layer and the
//! vision tower on it, a server that cannot get that device fails to start
//! instead of crawling along on the CPU.
//!
//! Inputs follow WeMM-Embedding's own recipe (its processor, chat template
//! and MMEB evaluation): the content is the user turn, closed by the
//! `<embedding>` token, whose last hidden state is the vector. A still is
//! resized by `smart_resize` with a bicubic filter, so llama.cpp receives
//! pixels it does not touch again. A video is read at one frame per second
//! of the clip (4 to 64 frames, spread over the whole of a longer one), each
//! frame at most 256 tokens; the vision tower merges consecutive frames in
//! pairs, and every pair is preceded by its time in the clip, as in
//! training ("<12.5 seconds>"). See `recipe` for the numbers.

use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail, ensure};
use atlas_core::EMBED_DIM as DIM;
use base64::Engine;
use fast_image_resize::FilterType;
use image::RgbImage;
use serde_json::{Value, json};
use tokio::process::{Child, Command};
use tokio::sync::Mutex;

use crate::config::Config;
use crate::{Worker, pixels};

/// The frame every input sits in: the user turn, then the token whose
/// hidden state is the embedding.
const USER: &str = "<|im_start|>user";
const CLOSE: &str = "<|im_end|><embedding>";
/// The instructions of the model's own retrieval training (MMEB): a search
/// asks once for stills and once for clips, and each document says what it
/// is after its pixels. Measured on Flickr30k (1k test, text to image R@1):
/// 84.4 without instructions, 87.6 with them; Qwen3-VL-Embedding-2B, the
/// model before, 78.9.
const FIND_STILL: &str = "Find me an everyday image that matches the given caption: ";
const FIND_CLIP: &str = "Find a video that contains the following visual content: ";
const STILL: &str = "Represent the given image.";
const CLIP: &str = "Understand the content of the provided video.";

/// A clip's frames, encoded for the server, and the time of each merged pair.
type Sampled = (Vec<Vec<u8>>, Vec<f64>);

/// A search, embedded once per kind of document it is matched against.
pub struct Questions {
    pub still: Vec<f32>,
    pub clip: Vec<f32>,
}

const IDLE: u8 = 0;
const LOADING: u8 = 1;
const LOADED: u8 = 2;

pub struct Embedder {
    program: std::path::PathBuf,
    /// the CUDA device the server is pinned to (its vision tower too)
    device: String,
    args: Vec<String>,
    url: String,
    idle_after: Duration,
    http: reqwest::Client,
    running: Mutex<Option<Running>>,
    state: AtomicU8,
    /// requests sent and not answered yet: the server is not stopped under them
    in_flight: AtomicUsize,
    pub slots: u32,
}

struct Running {
    child: Child,
    /// the placeholder this server instance wants where an image goes
    marker: String,
    last_used: Instant,
}

impl Embedder {
    pub fn new(cfg: &Config) -> Self {
        // the longest input is a full video plus its timestamps and the
        // prompt frame; the context is shared by the slots, a batch holds one
        // whole input
        let per_slot = recipe::IMAGE_MAX_TOKENS.max(recipe::VIDEO_TOKENS) + 512;
        let context = (per_slot * cfg.slots).to_string();
        let batch = per_slot.to_string();
        let args = [
            "--model", &cfg.embed_model.to_string_lossy(),
            "--mmproj", &cfg.embed_mmproj.to_string_lossy(),
            "--embedding", "--pooling", "last",
            "--device", &cfg.device, "--n-gpu-layers", "999",
            "--ctx-size", &context, "--batch-size", &batch, "--ubatch-size", &batch,
            "--parallel", &cfg.slots.to_string(),
            // inputs arrive at their final size; llama.cpp must not resize them
            "--image-min-tokens", &recipe::FRAME_MIN_TOKENS.to_string(),
            "--image-max-tokens", &recipe::IMAGE_MAX_TOKENS.to_string(),
            "--host", "127.0.0.1", "--port", &cfg.llama_port.to_string(),
            "--no-webui",
        ]
        .map(str::to_string)
        .to_vec();
        Embedder {
            program: cfg.llama_server.clone(),
            device: cfg.device.clone(),
            args,
            url: format!("http://127.0.0.1:{}", cfg.llama_port),
            idle_after: cfg.idle,
            http: reqwest::Client::builder().timeout(Duration::from_secs(180)).build().expect("http client"),
            running: Mutex::new(None),
            state: AtomicU8::new(IDLE),
            in_flight: AtomicUsize::new(0),
            slots: cfg.slots,
        }
    }

    pub fn state(&self) -> &'static str {
        match self.state.load(Ordering::Relaxed) {
            LOADED => "loaded",
            LOADING => "loading",
            _ => "idle",
        }
    }

    /// Start the server if it is not up, and wait until the model is loaded.
    async fn start(&self) -> Result<Running> {
        ensure!(self.program.exists(), "llama.cpp server not found at {} (see docs/SETUP.md)", self.program.display());
        self.state.store(LOADING, Ordering::Relaxed);
        let started = Instant::now();
        let mut child = Command::new(&self.program)
            .args(&self.args)
            .env("MTMD_BACKEND_DEVICE", &self.device)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .with_context(|| format!("cannot start {}", self.program.display()))?;

        let deadline = Instant::now() + Duration::from_secs(180);
        loop {
            if let Some(status) = child.try_wait()? {
                self.state.store(IDLE, Ordering::Relaxed);
                bail!(
                    "llama.cpp server exited while loading ({status}); is {} there (`{} --list-devices`) and not out of memory?",
                    self.device,
                    self.program.display()
                );
            }
            let health = self.http.get(format!("{}/health", self.url)).timeout(Duration::from_secs(2)).send().await;
            if health.is_ok_and(|r| r.status().is_success()) {
                break;
            }
            if Instant::now() > deadline {
                self.state.store(IDLE, Ordering::Relaxed);
                bail!("llama.cpp server did not become ready within 3 minutes");
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        let props: Value = self.http.get(format!("{}/props", self.url)).send().await?.json().await?;
        let marker = props["media_marker"].as_str().unwrap_or("<__media__>").to_string();
        self.state.store(LOADED, Ordering::Relaxed);
        tracing::info!("embedding model loaded in {:.1?}", started.elapsed());
        Ok(Running { child, marker, last_used: Instant::now() })
    }

    /// One request against the (started if necessary) server. `prompt` gets
    /// the server's media marker to place its images; `frames` says they are
    /// consecutive frames of one clip, which the vision tower merges in time.
    async fn request(&self, prompt: impl FnOnce(&str) -> String, images: &[Vec<u8>], frames: bool) -> Result<Vec<f32>> {
        let marker = {
            let mut running = self.running.lock().await;
            if running.as_mut().is_some_and(|r| r.child.try_wait().ok().flatten().is_some()) {
                *running = None; // it died; start over
            }
            if running.is_none() {
                *running = Some(self.start().await?);
            }
            let server = running.as_mut().expect("just started");
            server.last_used = Instant::now();
            // counted under the lock, so the idle check cannot stop the
            // server between here and the request
            self.in_flight.fetch_add(1, Ordering::SeqCst);
            server.marker.clone()
        };
        let result = self.send(prompt(&marker), images, frames).await;
        self.in_flight.fetch_sub(1, Ordering::SeqCst);
        if let Some(server) = self.running.lock().await.as_mut() {
            server.last_used = Instant::now();
        }
        result
    }

    async fn send(&self, prompt: String, images: &[Vec<u8>], frames: bool) -> Result<Vec<f32>> {
        let content = if images.is_empty() {
            json!(prompt)
        } else {
            let encoded: Vec<String> =
                images.iter().map(|png| base64::engine::general_purpose::STANDARD.encode(png)).collect();
            // "video_frames" is Atlas' patch to llama.cpp (scripts/atlas/llama-server-video-frames.patch)
            json!({ "prompt_string": prompt, "multimodal_data": encoded, "video_frames": frames })
        };
        let response = self
            .http
            .post(format!("{}/embeddings", self.url))
            .json(&json!({ "content": content }))
            .send()
            .await
            .context("llama.cpp server did not answer")?;
        let status = response.status();
        let body: Value = response.json().await?;
        ensure!(status.is_success(), "llama.cpp server: {}", body["error"]["message"].as_str().unwrap_or("request failed"));
        // [{"index":0,"embedding":[[...]]}]: one pooled vector, nested
        let embedding = &body[0]["embedding"];
        let values = embedding.get(0).filter(|first| first.is_array()).unwrap_or(embedding);
        let mut vec: Vec<f32> = values
            .as_array()
            .context("no embedding in the response")?
            .iter()
            .filter_map(|x| x.as_f64().map(|f| f as f32))
            .collect();
        ensure!(vec.len() == DIM, "expected {DIM} dimensions, got {}", vec.len());
        pixels::normalize(&mut vec);
        Ok(vec)
    }

    pub async fn warm(&self) -> Result<()> {
        let mut running = self.running.lock().await;
        if running.is_none() {
            *running = Some(self.start().await?);
        }
        if let Some(server) = running.as_mut() {
            server.last_used = Instant::now();
        }
        Ok(())
    }

    /// A search text, as the question for stills and for clips; both run
    /// side by side in the server's slots.
    pub async fn embed_query(&self, text: &str) -> Result<Questions> {
        let (still, clip) = tokio::try_join!(
            self.request(|_| format!("{USER}\n{FIND_STILL}{text}{CLOSE}"), &[], false),
            self.request(|_| format!("{USER}\n{FIND_CLIP}{text}{CLOSE}"), &[], false),
        )?;
        Ok(Questions { still, clip })
    }

    pub async fn embed_image(&self, image: &RgbImage) -> Result<Vec<f32>> {
        let (w, h) = recipe::image_size(image.width(), image.height());
        let prepared = pixels::png(&pixels::resize(image, w, h, FilterType::CatmullRom)?)?;
        self.request(|marker| format!("{USER}{marker}{STILL}{CLOSE}"), &[prepared], false).await
    }

    /// A clip, sampled as the model's video processor does. None when it is
    /// too short to sample (a single frame): the caller embeds its poster.
    pub async fn embed_video(&self, path: &std::path::Path) -> Result<Option<Vec<f32>>> {
        let path = path.to_path_buf();
        let sampled = tokio::task::spawn_blocking(move || -> Result<Option<Sampled>> {
            let clip = pixels::probe(&path)?;
            let Some(count) = recipe::frame_count(clip.times.len(), clip.fps) else { return Ok(None) };
            let indices = recipe::frame_indices(clip.times.len(), count);
            // the frames as shown; their labels in the prompt are index /
            // average rate, as the model's processor computes them
            let shown: Vec<f64> = indices.iter().map(|&i| clip.times[i]).collect();
            let frames = pixels::frames_at(&path, &shown, clip.hdr)?;
            // every frame at the size of the first, as the processor does
            let (w, h) = recipe::frame_size(frames[0].width(), frames[0].height(), count);
            let encoded = frames
                .iter()
                .map(|f| pixels::png(&pixels::resize(f, w, h, FilterType::CatmullRom)?))
                .collect::<Result<Vec<_>>>()?;
            Ok(Some((encoded, recipe::pair_times(&indices, clip.fps))))
        })
        .await??;
        let Some((frames, times)) = sampled else { return Ok(None) };
        let prompt = |marker: &str| {
            let pairs: String = times.iter().map(|t| format!("<{t:.1} seconds>{marker}{marker}")).collect();
            format!("{USER}\n{pairs}{CLIP}{CLOSE}")
        };
        self.request(prompt, &frames, true).await.map(Some)
    }

    pub async fn unload(&self) {
        if let Some(mut server) = self.running.lock().await.take() {
            let _ = server.child.kill().await;
            self.state.store(IDLE, Ordering::Relaxed);
            tracing::info!("embedding model unloaded");
        }
    }

    /// Stops the server when nothing is in flight and nothing used it for
    /// `idle_after`.
    async fn unload_if_idle(&self) {
        let Ok(mut running) = self.running.try_lock() else { return };
        let idle = running.as_ref().is_some_and(|s| s.last_used.elapsed() >= self.idle_after);
        if idle && self.in_flight.load(Ordering::SeqCst) == 0
            && let Some(mut server) = running.take()
        {
            let _ = server.child.kill().await;
            self.state.store(IDLE, Ordering::Relaxed);
            tracing::info!("embedding model unloaded");
        }
    }
}

/// Stop the llama.cpp server once nothing has used it for a while.
pub async fn unload_when_idle(worker: Arc<Worker>) {
    loop {
        tokio::time::sleep(Duration::from_secs(30)).await;
        worker.embedder.unload_if_idle().await;
    }
}

/// How much of a still or a clip the model sees: `qwen_vl_utils` (0.0.14)
/// as WeMM-Embedding's MMEB evaluation calls it. Python rounds halves to
/// even, so these do too.
pub mod recipe {
    /// The vision tower sees 16px patches merged 2x2: one token per 32px square.
    const PATCH: u32 = 32;
    /// A still: at least 64 and at most 1800 tokens (a 2048px thumbnail at 4:3
    /// becomes 1536x1152).
    pub const IMAGE_MIN_TOKENS: u32 = 64;
    pub const IMAGE_MAX_TOKENS: u32 = 1800;
    /// A clip: one frame per second, 4 to 64 frames, each 4 to 256 tokens,
    /// 8192 tokens at most in all (the frames of a pair share their tokens).
    const FPS: f64 = 1.0;
    const MIN_FRAMES: usize = 4;
    const MAX_FRAMES: usize = 64;
    pub const FRAME_MIN_TOKENS: u32 = 4;
    const FRAME_MAX_TOKENS: u32 = 256;
    pub const VIDEO_TOKENS: u32 = 8192;

    /// `smart_resize`: both sides multiples of 32, the area between the two
    /// limits, the aspect kept as closely as that allows. Returns (w, h).
    pub fn smart_size(width: u32, height: u32, min_pixels: f64, max_pixels: f64) -> (u32, u32) {
        let factor = f64::from(PATCH);
        let (w, h) = (f64::from(width.max(1)), f64::from(height.max(1)));
        let round = |v: f64| ((v / factor).round_ties_even() * factor).max(factor);
        let (mut out_w, mut out_h) = (round(w), round(h));
        if out_w * out_h > max_pixels {
            let beta = (w * h / max_pixels).sqrt();
            out_w = ((w / beta / factor).floor() * factor).max(factor);
            out_h = ((h / beta / factor).floor() * factor).max(factor);
        } else if out_w * out_h < min_pixels {
            let beta = (min_pixels / (w * h)).sqrt();
            out_w = (w * beta / factor).ceil() * factor;
            out_h = (h * beta / factor).ceil() * factor;
        }
        (out_w as u32, out_h as u32)
    }

    fn pixels(tokens: u32) -> f64 {
        f64::from(tokens * PATCH * PATCH)
    }

    pub fn image_size(width: u32, height: u32) -> (u32, u32) {
        smart_size(width, height, pixels(IMAGE_MIN_TOKENS), pixels(IMAGE_MAX_TOKENS))
    }

    /// `smart_nframes`: how many frames to read from a clip of `total`
    /// frames at `fps`; even, and None when not even two can be had.
    pub fn frame_count(total: usize, fps: f64) -> Option<usize> {
        let wanted = total as f64 / fps * FPS;
        let n = wanted.max(MIN_FRAMES as f64).min(MAX_FRAMES as f64).min(total as f64);
        let n = (n / 2.0).floor() as usize * 2;
        (n >= 2 && n <= total).then_some(n)
    }

    /// Which frames: `linspace(0, total - 1, count)`, rounded.
    pub fn frame_indices(total: usize, count: usize) -> Vec<usize> {
        let last = total.saturating_sub(1) as f64;
        let step = if count > 1 { last / (count - 1) as f64 } else { 0.0 };
        (0..count).map(|i| (i as f64 * step).round_ties_even() as usize).collect()
    }

    /// The size every frame is brought to: at most 256 tokens, less when
    /// many frames would exceed the clip's total.
    pub fn frame_size(width: u32, height: u32, count: usize) -> (u32, u32) {
        let min = pixels(FRAME_MIN_TOKENS);
        let max = pixels(FRAME_MAX_TOKENS).min(pixels(VIDEO_TOKENS) / count as f64 * 2.0).max((min * 1.05).floor());
        smart_size(width, height, min, max)
    }

    /// The time of each merged pair of frames, in seconds: the mean of its
    /// two frames' times.
    pub fn pair_times(indices: &[usize], fps: f64) -> Vec<f64> {
        indices.chunks(2).map(|pair| (pair[0] + pair[pair.len() - 1]) as f64 / 2.0 / fps).collect()
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn image_sizes_match_the_reference() {
            // qwen_vl_utils.smart_resize(1536, 2048, factor=32, min_pixels=64*1024, max_pixels=1800*1024)
            assert_eq!(image_size(2048, 1536), (1536, 1152));
            // small enough already: only snapped to the patch grid
            assert_eq!(image_size(512, 384), (512, 384));
            assert_eq!(image_size(500, 375), (512, 384));
            // halves round to even, as Python's round() does: 720 / 32 = 22.5
            assert_eq!(image_size(720, 1280), (704, 1280));
            // tiny images are raised to the minimum of 64 tokens
            assert_eq!(image_size(20, 20), (256, 256));
        }

        #[test]
        fn clips_are_sampled_as_the_reference_does() {
            // 10 s at 30 fps: 10 frames
            assert_eq!(frame_count(300, 30.0), Some(10));
            // 3 s: raised to the minimum of 4
            assert_eq!(frame_count(90, 30.0), Some(4));
            // 5 minutes: capped at 64
            assert_eq!(frame_count(9000, 30.0), Some(64));
            // odd counts round down: 7.5 s -> 6
            assert_eq!(frame_count(225, 30.0), Some(6));
            // a clip of 3 frames gives 2, of 1 frame nothing
            assert_eq!(frame_count(3, 30.0), Some(2));
            assert_eq!(frame_count(1, 30.0), None);
            assert_eq!(frame_indices(300, 10), vec![0, 33, 66, 100, 133, 166, 199, 233, 266, 299]);
            assert_eq!(pair_times(&[0, 33, 66, 100], 30.0), vec![0.55, 2.7666666666666666]);
        }

        #[test]
        fn frames_are_sized_as_the_reference_does() {
            // qwen_vl_utils fetch_video with WeMM's min/max/total pixels
            let want = [((1920, 1080, 64), (672, 384)), ((1080, 1920, 10), (384, 672)), ((3840, 2160, 4), (672, 384)), ((640, 360, 64), (640, 352))];
            for ((w, h, n), size) in want {
                assert_eq!(frame_size(w, h, n), size, "{w}x{h}, {n} frames");
                let tokens = (size.0 / 32) * (size.1 / 32);
                assert!(tokens <= 256 && n as u32 / 2 * tokens <= VIDEO_TOKENS);
            }
        }
    }
}
