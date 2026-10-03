//! The embedding model, behind a llama.cpp server this process owns.
//!
//! The server is started on first use and stopped after a stretch of
//! idleness, which returns its GPU memory. Requests are serialized: one
//! model, one slot.
//!
//! Inputs follow the model's own recipe exactly (its `Qwen3VLEmbedder`):
//! a system turn carrying the instruction, the content as the user turn, an
//! opened assistant turn, and the hidden state of the last token as the
//! embedding. Images are resized by the model's `smart_resize` rule with a
//! bicubic filter before they are handed over, so llama.cpp receives pixels
//! it does not have to touch again. Vectors produced here are
//! interchangeable with the ones the PyTorch reference wrote (cosine 0.99).

use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail, ensure};
use base64::Engine;
use fast_image_resize::FilterType;
use image::RgbImage;
use serde_json::{Value, json};
use tokio::process::{Child, Command};
use tokio::sync::Mutex;

use crate::config::Config;
use crate::{Worker, pixels};

pub const DIM: usize = 2048;

const SYSTEM: &str = "<|im_start|>system\nRepresent the user's input.<|im_end|>\n<|im_start|>user\n";
const ASSISTANT: &str = "<|im_end|>\n<|im_start|>assistant\n";

/// The vision tower sees 16px patches merged 2x2: one token per 32px square.
const PATCH: u32 = 32;
const MIN_PIXELS: u32 = 4 * PATCH * PATCH;
/// 1800 tokens for a still; a video is six frames of 256 tokens each.
const IMAGE_TOKENS: u32 = 1800;
const FRAME_TOKENS: u32 = 256;
const VIDEO_FRAMES: usize = 6;

const IDLE: u8 = 0;
const LOADING: u8 = 1;
const LOADED: u8 = 2;

pub struct Embedder {
    program: std::path::PathBuf,
    args: Vec<String>,
    url: String,
    idle_after: Duration,
    http: reqwest::Client,
    running: Mutex<Option<Running>>,
    state: AtomicU8,
}

struct Running {
    child: Child,
    /// the placeholder this server instance wants where an image goes
    marker: String,
    last_used: Instant,
}

impl Embedder {
    pub fn new(cfg: &Config) -> Self {
        // the longest input is one still (1800 tokens) plus the prompt frame
        let context = (IMAGE_TOKENS + 256).to_string();
        let args = [
            "--model", &cfg.embed_model.to_string_lossy(),
            "--mmproj", &cfg.embed_mmproj.to_string_lossy(),
            "--embedding", "--pooling", "last",
            "--n-gpu-layers", &cfg.gpu_layers.to_string(),
            "--ctx-size", &context, "--batch-size", &context, "--ubatch-size", &context,
            "--parallel", "1",
            "--image-max-tokens", &IMAGE_TOKENS.to_string(),
            "--host", "127.0.0.1", "--port", &cfg.llama_port.to_string(),
            "--no-webui",
        ]
        .map(str::to_string)
        .to_vec();
        Embedder {
            program: cfg.llama_server.clone(),
            args,
            url: format!("http://127.0.0.1:{}", cfg.llama_port),
            idle_after: cfg.idle,
            http: reqwest::Client::builder().timeout(Duration::from_secs(180)).build().expect("http client"),
            running: Mutex::new(None),
            state: AtomicU8::new(IDLE),
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
                bail!("llama.cpp server exited while loading ({status}); is the GPU out of memory?");
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
    /// the server's media marker to place its images.
    async fn request(&self, prompt: impl FnOnce(&str) -> String, images: &[Vec<u8>]) -> Result<Vec<f32>> {
        let mut running = self.running.lock().await;
        if running.as_mut().is_some_and(|r| r.child.try_wait().ok().flatten().is_some()) {
            *running = None; // it died; start over
        }
        if running.is_none() {
            *running = Some(self.start().await?);
        }
        let server = running.as_mut().expect("just started");
        server.last_used = Instant::now();

        let content = if images.is_empty() {
            json!(prompt(&server.marker))
        } else {
            let encoded: Vec<String> =
                images.iter().map(|png| base64::engine::general_purpose::STANDARD.encode(png)).collect();
            json!({ "prompt_string": prompt(&server.marker), "multimodal_data": encoded })
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
        if let Some(server) = running.as_mut() {
            server.last_used = Instant::now();
        }
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

    pub async fn embed_text(&self, text: &str) -> Result<Vec<f32>> {
        let text = text.to_string();
        self.request(move |_| format!("{SYSTEM}{text}{ASSISTANT}"), &[]).await
    }

    pub async fn embed_image(&self, image: &RgbImage) -> Result<Vec<f32>> {
        let prepared = prepare(image, IMAGE_TOKENS)?;
        self.request(|marker| format!("{SYSTEM}{marker}{ASSISTANT}"), &[prepared]).await
    }

    /// A video is embedded as its frames in sequence: six stills spread over
    /// the whole clip, in one prompt, pooled into one vector. Measured against
    /// the reference's own video path this lands closest (cosine 0.81 to 0.92)
    /// of the ways to feed frames; averaging per-frame vectors is worse.
    pub async fn embed_video(&self, path: &std::path::Path, duration: f64) -> Result<Vec<f32>> {
        let path = path.to_path_buf();
        let frames = tokio::task::spawn_blocking(move || -> Result<Vec<Vec<u8>>> {
            pixels::video_frames(&path, duration, VIDEO_FRAMES)?.iter().map(|f| prepare(f, FRAME_TOKENS)).collect()
        })
        .await??;
        let count = frames.len();
        self.request(|marker| format!("{SYSTEM}{}{ASSISTANT}", marker.repeat(count)), &frames).await
    }

    pub async fn unload(&self) {
        if let Some(mut server) = self.running.lock().await.take() {
            let _ = server.child.kill().await;
            self.state.store(IDLE, Ordering::Relaxed);
            tracing::info!("embedding model unloaded");
        }
    }

    async fn idle_for(&self) -> Option<Duration> {
        self.running.try_lock().ok()?.as_ref().map(|s| s.last_used.elapsed())
    }
}

/// Stop the llama.cpp server once nothing has used it for a while.
pub async fn unload_when_idle(worker: Arc<Worker>) {
    loop {
        tokio::time::sleep(Duration::from_secs(30)).await;
        if worker.embedder.idle_for().await.is_some_and(|idle| idle >= worker.embedder.idle_after) {
            worker.embedder.unload().await;
        }
    }
}

/// The model's `smart_resize`: both sides multiples of 32, at most
/// `max_tokens` 32px squares, aspect kept as closely as that allows.
pub fn smart_size(width: u32, height: u32, max_tokens: u32) -> (u32, u32) {
    let factor = f64::from(PATCH);
    let (w, h) = (f64::from(width.max(1)), f64::from(height.max(1)));
    let max_pixels = f64::from(max_tokens * PATCH * PATCH);
    let min_pixels = f64::from(MIN_PIXELS);
    let round = |v: f64| ((v / factor).round() * factor).max(factor);
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

fn prepare(image: &RgbImage, max_tokens: u32) -> Result<Vec<u8>> {
    let (w, h) = smart_size(image.width(), image.height(), max_tokens);
    pixels::png(&pixels::resize(image, w, h, FilterType::CatmullRom)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn smart_size_matches_the_reference() {
        // qwen_vl_utils.smart_resize(1536, 2048, factor=32, max_pixels=1800*32*32)
        assert_eq!(smart_size(2048, 1536, 1800), (1536, 1152));
        // small enough already: only snapped to the patch grid
        assert_eq!(smart_size(512, 384, 1800), (512, 384));
        assert_eq!(smart_size(500, 375, 1800), (512, 384));
        // tiny images are raised to the minimum
        assert_eq!(smart_size(20, 20, 1800), (64, 64));
        let (w, h) = smart_size(4000, 3000, 768);
        assert!(w % 32 == 0 && h % 32 == 0 && (w / 32) * (h / 32) <= 768);
    }
}
