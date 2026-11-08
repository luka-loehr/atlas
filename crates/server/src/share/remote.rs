//! atlas-share's admin API: what the Worker stores and serves.

use std::path::Path;
use std::time::Duration;

use anyhow::{Result, anyhow};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::io::AsyncReadExt;

use super::upload::with_retries;
use crate::App;

/// Files up to this size go up in one request; larger ones in parts. Small
/// parts keep the progress the app shows moving (R2's minimum is 5 MiB).
const SINGLE_MAX: u64 = 16 << 20;
const PART: usize = 16 << 20;

pub(super) struct Remote {
    http: reqwest::Client,
    base: String,
    token: String,
}

impl Remote {
    pub(super) fn new(app: &App) -> Option<Self> {
        Some(Self {
            http: reqwest::Client::builder().timeout(Duration::from_secs(600)).build().ok()?,
            base: app.cfg.share_url.clone()?,
            token: app.cfg.share_token.clone()?,
        })
    }

    fn file_url(&self, id: &str, kind: &str, asset: &str) -> String {
        format!("{}/api/shares/{id}/files/{kind}/{asset}", self.base)
    }

    async fn send(&self, req: reqwest::RequestBuilder) -> Result<reqwest::Response> {
        let res = req.bearer_auth(&self.token).send().await?;
        if !res.status().is_success() {
            let status = res.status();
            let body = res.text().await.unwrap_or_default();
            return Err(anyhow!("atlas-share answered {status}: {}", body.chars().take(200).collect::<String>()));
        }
        Ok(res)
    }

    /// Stores one file, skipping one already there at the same size.
    /// `sent` hears the bytes of every part as it lands.
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn put_file(
        &self,
        id: &str,
        kind: &str,
        asset: &str,
        path: &Path,
        mime: &str,
        size: u64,
        sent: &(dyn Fn(u64) + Sync),
    ) -> Result<()> {
        let url = self.file_url(id, kind, asset);
        let head = self.http.head(&url).bearer_auth(&self.token).send().await?;
        if head.status().is_success() && head.content_length() == Some(size) {
            return Ok(());
        }
        if size <= SINGLE_MAX {
            let body = tokio::fs::read(path).await?;
            self.send(self.http.put(&url).header("content-type", mime).body(body)).await?;
            return Ok(());
        }
        #[derive(Deserialize)]
        struct Started {
            upload_id: String,
        }
        #[derive(Deserialize)]
        struct Part {
            etag: String,
        }
        let started: Started =
            self.send(self.http.post(format!("{url}?uploads")).header("content-type", mime)).await?.json().await?;
        let mut file = tokio::fs::File::open(path).await?;
        let mut parts = Vec::new();
        let mut buf = vec![0u8; PART];
        for n in 1.. {
            let read = read_full(&mut file, &mut buf).await?;
            if read == 0 {
                break;
            }
            let chunk = buf[..read].to_vec();
            let part_url = format!("{url}?upload_id={}&part={n}", started.upload_id);
            let part: Part = with_retries(|| async {
                Ok(self.send(self.http.put(&part_url).body(chunk.clone())).await?.json().await?)
            })
            .await?;
            parts.push(json!({ "part": n, "etag": part.etag }));
            sent(read as u64);
            if read < PART {
                break;
            }
        }
        self.send(
            self.http
                .post(format!("{url}?upload_id={}&complete", started.upload_id))
                .json(&json!({ "parts": parts })),
        )
        .await?;
        Ok(())
    }

    /// Stores the link preview; false when this atlas-share predates them
    /// (the page then shows the first thumbnail, as before).
    pub(super) async fn preview(&self, id: &str, jpeg: &[u8]) -> Result<bool> {
        let url = format!("{}/api/shares/{id}/og", self.base);
        let req = self.http.put(&url).header("content-type", "image/jpeg").body(jpeg.to_vec());
        match self.send(req).await {
            Ok(_) => Ok(true),
            Err(e) if e.to_string().starts_with("atlas-share answered 404") => {
                tracing::warn!("share {id}: atlas-share has no link previews yet; `atlas share setup` updates it");
                Ok(false)
            }
            Err(e) => Err(e),
        }
    }

    pub(super) async fn progress(&self, id: &str, body: &Value) -> Result<()> {
        self.send(self.http.put(format!("{}/api/shares/{id}/progress", self.base)).json(body)).await?;
        Ok(())
    }

    /// Every share id atlas-share holds files for.
    pub(super) async fn ids(&self) -> Result<Vec<String>> {
        #[derive(Deserialize)]
        struct Ids {
            ids: Vec<String>,
        }
        Ok(self.send(self.http.get(format!("{}/api/shares", self.base))).await?.json::<Ids>().await?.ids)
    }

    pub(super) async fn manifest(&self, id: &str, manifest: &Value) -> Result<()> {
        self.send(self.http.put(format!("{}/api/shares/{id}", self.base)).json(manifest)).await?;
        Ok(())
    }

    pub(super) async fn delete(&self, id: &str) -> Result<()> {
        self.send(self.http.delete(format!("{}/api/shares/{id}", self.base))).await?;
        Ok(())
    }
}

/// Fills `buf` unless the file ends first; returns the bytes read.
async fn read_full(file: &mut tokio::fs::File, buf: &mut [u8]) -> Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        let n = file.read(&mut buf[filled..]).await?;
        if n == 0 {
            break;
        }
        filled += n;
    }
    Ok(filled)
}
