//! The atlas-ml client: query embeddings with a small LRU in front.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use atlas_core::vector::normalize;
use serde::Deserialize;
use serde_json::{Value, json};

use super::vectors::{DIM, Questions, VectorIndex};
use crate::Config;

pub struct Ml {
    http: reqwest::Client,
    url: String,
    cache: Mutex<QueryCache>,
    pub vectors: Arc<VectorIndex>,
}

#[derive(Default)]
struct QueryCache {
    vectors: HashMap<String, Arc<Questions>>,
    order: VecDeque<String>,
}

impl Ml {
    pub fn new(cfg: &Config) -> Self {
        Ml {
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(60))
                .connect_timeout(Duration::from_secs(2))
                .build()
                .expect("http client"),
            url: cfg.ml_url.trim_end_matches('/').to_string(),
            cache: Mutex::default(),
            vectors: Arc::default(),
        }
    }

    /// The search as atlas-ml embeds it: the question for stills and the one
    /// for clips.
    pub async fn embed_text(&self, text: &str) -> Result<Arc<Questions>> {
        let key = text.to_lowercase();
        if let Some(hit) = self.cache.lock().unwrap().vectors.get(&key) {
            return Ok(hit.clone());
        }
        #[derive(Deserialize)]
        struct Embedding {
            still: Vec<f32>,
            clip: Vec<f32>,
        }
        let mut embedding: Embedding = self
            .http
            .post(format!("{}/embed", self.url))
            .json(&json!({ "text": text }))
            .send()
            .await
            .context("atlas-ml unreachable")?
            .error_for_status()?
            .json()
            .await?;
        for v in [&mut embedding.still, &mut embedding.clip] {
            anyhow::ensure!(v.len() == DIM, "atlas-ml returned {} dimensions", v.len());
            normalize(v);
        }
        let vec = Arc::new(Questions {
            still: embedding.still,
            clip: embedding.clip,
        });
        let mut cache = self.cache.lock().unwrap();
        if cache.vectors.insert(key.clone(), vec.clone()).is_none() {
            cache.order.push_back(key);
            if cache.order.len() > 512
                && let Some(oldest) = cache.order.pop_front()
            {
                cache.vectors.remove(&oldest);
            }
        }
        Ok(vec)
    }

    /// atlas-ml's own status report, None when it does not answer.
    pub async fn health(&self) -> Option<Value> {
        let response = self
            .http
            .get(format!("{}/health", self.url))
            .timeout(Duration::from_secs(2))
            .send()
            .await
            .ok()?;
        response.json().await.ok()
    }

    pub async fn warm(&self) -> bool {
        self.http
            .post(format!("{}/warm", self.url))
            .send()
            .await
            .is_ok_and(|r| r.status().is_success())
    }
}
