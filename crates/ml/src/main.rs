//! atlas-ml — the model worker.
//!
//! Two models, nothing generative:
//!
//!   * Qwen3-VL-Embedding-2B puts photos, videos and search text into one
//!     2048-dimensional space. It runs in a llama.cpp server that this
//!     process starts on demand and stops again when idle, so the GPU is
//!     free whenever nothing is being embedded.
//!   * InsightFace buffalo_l (SCRFD detection + ArcFace recognition) finds
//!     faces and groups them into people, on ONNX Runtime.
//!
//! It drains the `embed` and `faces` jobs of the queue and answers on
//! loopback only:
//!
//!   GET  /health   what is loaded and what the queue holds
//!   POST /embed    {"text": "..."} -> {"vec": [2048 floats]}
//!   POST /warm     load the embedding model now

mod config;
mod embedder;
mod faces;
mod jobs;
mod pixels;

use std::sync::Arc;

use anyhow::{Context, Result};
use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{Value, json};

use config::Config;
use embedder::Embedder;

pub struct Worker {
    pub cfg: Config,
    pub pool: deadpool_postgres::Pool,
    pub embedder: Embedder,
}

#[tokio::main]
async fn main() -> Result<()> {
    atlas_core::init_logging();
    let cfg = Config::from_env()?;
    let pool = atlas_core::db::pool(4)?;
    let worker = Arc::new(Worker { embedder: Embedder::new(&cfg), pool, cfg });

    tokio::spawn(jobs::run(worker.clone()));
    tokio::spawn(embedder::unload_when_idle(worker.clone()));

    let router = Router::new()
        .route("/health", get(health))
        .route("/embed", post(embed))
        .route("/warm", post(warm))
        .with_state(worker.clone());
    let listener = tokio::net::TcpListener::bind(&worker.cfg.bind)
        .await
        .with_context(|| format!("cannot bind {}", worker.cfg.bind))?;
    tracing::info!("atlas-ml {} on {}", env!("CARGO_PKG_VERSION"), worker.cfg.bind);
    axum::serve(listener, router)
        .with_graceful_shutdown(async {
            let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).unwrap();
            tokio::select! {
                _ = term.recv() => {}
                _ = tokio::signal::ctrl_c() => {}
            }
        })
        .await?;
    worker.embedder.unload().await;
    Ok(())
}

async fn health(State(worker): State<Arc<Worker>>) -> Json<Value> {
    let queue = async {
        let c = worker.pool.get().await.ok()?;
        let rows = c
            .query(
                "SELECT kind, status, count(*) FROM ingest_jobs
                 WHERE kind IN ('embed', 'faces') AND status <> 'done' GROUP BY kind, status",
                &[],
            )
            .await
            .ok()?;
        let mut queue = serde_json::Map::new();
        for row in rows {
            let key = format!("{}_{}", row.get::<_, String>(0), row.get::<_, String>(1));
            queue.insert(key, json!(row.get::<_, i64>(2)));
        }
        Some(Value::Object(queue))
    }
    .await;
    Json(json!({
        "version": env!("CARGO_PKG_VERSION"),
        "embedder": worker.embedder.state(),
        "embed_model": worker.cfg.embed_model.file_name().map(|n| n.to_string_lossy().into_owned()),
        "faces": worker.cfg.face_detector.exists() && worker.cfg.face_recognizer.exists(),
        "queue": queue,
    }))
}

#[derive(Deserialize)]
struct EmbedRequest {
    text: String,
}

async fn embed(State(worker): State<Arc<Worker>>, Json(request): Json<EmbedRequest>) -> Result<Json<Value>, (StatusCode, String)> {
    let text: String = request.text.trim().chars().take(400).collect();
    if text.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "text required".into()));
    }
    match worker.embedder.embed_text(&text).await {
        Ok(vec) => Ok(Json(json!({ "vec": vec }))),
        Err(e) => {
            tracing::error!("text embedding failed: {e:#}");
            Err((StatusCode::SERVICE_UNAVAILABLE, format!("{e:#}")))
        }
    }
}

async fn warm(State(worker): State<Arc<Worker>>) -> StatusCode {
    match worker.embedder.warm().await {
        Ok(()) => StatusCode::NO_CONTENT,
        Err(e) => {
            tracing::error!("could not load the embedding model: {e:#}");
            StatusCode::SERVICE_UNAVAILABLE
        }
    }
}
