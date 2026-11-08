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
use atlas_core::vector::normalize;
use base64::Engine;
use fast_image_resize::FilterType;
use image::RgbImage;
use serde_json::{Value, json};
use tokio::process::{Child, Command};
use tokio::sync::Mutex;

use crate::config::Config;
use crate::{Worker, pixels};

pub mod recipe;

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
        normalize(&mut vec);
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
        if let Some(server) = self.running.lock().await.take() {
            self.stop(server).await;
        }
    }

    /// Stops the server when nothing is in flight and nothing used it for
    /// `idle_after`.
    async fn unload_if_idle(&self) {
        let Ok(mut running) = self.running.try_lock() else { return };
        let idle = running.as_ref().is_some_and(|s| s.last_used.elapsed() >= self.idle_after);
        if idle && self.in_flight.load(Ordering::SeqCst) == 0
            && let Some(server) = running.take()
        {
            self.stop(server).await;
        }
    }

    async fn stop(&self, mut server: Running) {
        let _ = server.child.kill().await;
        self.state.store(IDLE, Ordering::Relaxed);
        tracing::info!("embedding model unloaded");
    }
}

/// Stop the llama.cpp server once nothing has used it for a while.
pub async fn unload_when_idle(worker: Arc<Worker>) {
    loop {
        tokio::time::sleep(Duration::from_secs(30)).await;
        worker.embedder.unload_if_idle().await;
    }
}
