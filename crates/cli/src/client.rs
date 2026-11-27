//! Async HTTP + AWS SigV4 S3 client for the Atlas API.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use atlas_common::crypto::{hex_encode, sha256_hex};
use atlas_common::s3::{EMPTY_SHA256, sign_request_headers};
use atlas_common::validate::uri_encode;
use chrono::Utc;
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderName, HeaderValue, RANGE};
use reqwest::{Client, Method, RequestBuilder, Response};
use serde::Serialize;
use serde::de::DeserializeOwned;
use sha2::{Digest, Sha256};
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use url::Url;

use crate::credentials::{ResolvedConfig, resolve_required};
use crate::sanitize::sanitize_for_tty;

/// Part size for S3 Multipart Uploads (16 MiB).
pub const MULTIPART_PART_SIZE: usize = 16 * 1024 * 1024;
/// Default threshold above which `put` switches to S3 Multipart Upload (64 MiB).
pub const DEFAULT_MULTIPART_THRESHOLD_MB: u64 = 64;

#[derive(Debug, Clone)]
pub struct AtlasClient {
    http: Client,
    cfg: ResolvedConfig,
}

#[derive(Debug, Clone, Serialize)]
pub struct PutSummary {
    pub bucket: String,
    pub key: String,
    pub size: u64,
    pub sha256: String,
    pub etag: Option<String>,
    pub multipart: bool,
    pub parts: usize,
}

impl AtlasClient {
    pub fn from_env() -> Result<Self> {
        let cfg = resolve_required()?;
        Self::from_config(cfg)
    }

    pub fn from_config(cfg: ResolvedConfig) -> Result<Self> {
        let http = Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .user_agent(format!("atlas-cli/{}", env!("CARGO_PKG_VERSION")))
            .build()
            .context("failed to build HTTP client")?;
        Ok(Self { http, cfg })
    }

    pub fn config(&self) -> &ResolvedConfig {
        &self.cfg
    }

    pub fn base_url(&self) -> &str {
        &self.cfg.url
    }

    pub fn has_s3_keys(&self) -> bool {
        self.cfg.auth.s3_keypair().is_some()
    }

    pub fn host_header(&self) -> Result<String> {
        let parsed = Url::parse(&self.cfg.url)?;
        let host = parsed
            .host_str()
            .ok_or_else(|| anyhow!("URL has no host: {}", self.cfg.url))?;
        Ok(match parsed.port() {
            Some(port) => format!("{host}:{port}"),
            None => host.to_string(),
        })
    }

    fn apply_bearer(&self, req: RequestBuilder) -> RequestBuilder {
        if let Some(tok) = self.cfg.auth.bearer_token() {
            req.header(AUTHORIZATION, format!("Bearer {tok}"))
        } else {
            req
        }
    }

    fn apply_s3_auth(
        &self,
        req: RequestBuilder,
        method: &str,
        raw_path: &str,
        raw_query: Option<&str>,
        payload_hash: &str,
    ) -> Result<RequestBuilder> {
        if let Some((ak, sk)) = self.cfg.auth.s3_keypair() {
            let host = self.host_header()?;
            let (auth, amz_date, sha) = sign_request_headers(
                ak,
                sk,
                &self.cfg.region,
                method,
                raw_path,
                raw_query,
                &host,
                payload_hash,
                Utc::now(),
            );
            Ok(req
                .header(AUTHORIZATION, auth)
                .header("x-amz-date", amz_date)
                .header("x-amz-content-sha256", sha))
        } else {
            Ok(self.apply_bearer(req))
        }
    }

    pub fn url(&self, path: &str) -> String {
        if path.starts_with('/') {
            format!("{}{path}", self.cfg.url)
        } else {
            format!("{}/{path}", self.cfg.url)
        }
    }

    pub async fn get_json<T: DeserializeOwned>(&self, path: &str) -> Result<T> {
        let resp = self
            .apply_bearer(self.http.get(self.url(path)))
            .send()
            .await
            .with_context(|| format!("request failed: GET {path}"))?;
        let resp = check_response(resp).await?;
        resp.json::<T>()
            .await
            .with_context(|| format!("failed to parse JSON from GET {path}"))
    }

    pub async fn get_json_opt<T: DeserializeOwned>(&self, path: &str) -> Result<Option<T>> {
        let resp = self
            .apply_bearer(self.http.get(self.url(path)))
            .send()
            .await
            .with_context(|| format!("request failed: GET {path}"))?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        let resp = check_response(resp).await?;
        let val = resp
            .json::<T>()
            .await
            .with_context(|| format!("failed to parse JSON from GET {path}"))?;
        Ok(Some(val))
    }

    pub async fn get_text(&self, path: &str) -> Result<String> {
        let resp = self
            .apply_bearer(self.http.get(self.url(path)))
            .send()
            .await
            .with_context(|| format!("request failed: GET {path}"))?;
        let resp = check_response(resp).await?;
        resp.text()
            .await
            .with_context(|| format!("failed to read text from GET {path}"))
    }

    pub async fn post_json<B: Serialize, T: DeserializeOwned>(
        &self,
        path: &str,
        body: &B,
    ) -> Result<T> {
        let resp = self
            .apply_bearer(self.http.post(self.url(path)).json(body))
            .send()
            .await
            .with_context(|| format!("request failed: POST {path}"))?;
        let resp = check_response(resp).await?;
        resp.json::<T>()
            .await
            .with_context(|| format!("failed to parse JSON from POST {path}"))
    }

    pub async fn post_empty(&self, path: &str) -> Result<()> {
        let resp = self
            .apply_bearer(self.http.post(self.url(path)))
            .send()
            .await
            .with_context(|| format!("request failed: POST {path}"))?;
        check_response(resp).await?;
        Ok(())
    }

    pub async fn delete_empty(&self, path: &str) -> Result<()> {
        let resp = self
            .apply_bearer(self.http.delete(self.url(path)))
            .send()
            .await
            .with_context(|| format!("request failed: DELETE {path}"))?;
        check_response(resp).await?;
        Ok(())
    }

    /// Uploads a local file to `bucket/key`.
    /// - Uses S3 Multipart Upload (`MULTIPART_PART_SIZE` chunks) when file size exceeds `multipart_threshold_bytes`.
    /// - Uses SigV4 against `PUT /s3/{bucket}/{key}` when S3 keys are configured, else Bearer against `PUT /v1/buckets/{bucket}/objects/{key}`.
    pub async fn put_file(
        &self,
        bucket: &str,
        key: &str,
        local_path: &Path,
        content_type: Option<&str>,
        metadata: &BTreeMap<String, String>,
        multipart_threshold_bytes: u64,
    ) -> Result<PutSummary> {
        let meta = tokio::fs::metadata(local_path)
            .await
            .with_context(|| format!("cannot stat {}", local_path.display()))?;
        if !meta.is_file() {
            bail!("not a regular file: {}", local_path.display());
        }
        let file_size = meta.len();

        if file_size > multipart_threshold_bytes {
            return self
                .put_file_multipart(bucket, key, local_path, file_size, content_type, metadata)
                .await;
        }

        // Single-part upload
        let bytes = tokio::fs::read(local_path)
            .await
            .with_context(|| format!("cannot read {}", local_path.display()))?;
        let sha256 = sha256_hex(&bytes);
        let encoded_key = uri_encode(key, false);

        let extra_headers = build_meta_headers(content_type, metadata)?;

        let resp = if self.has_s3_keys() {
            let raw_path = format!("/s3/{bucket}/{encoded_key}");
            let req = self
                .http
                .request(Method::PUT, self.url(&raw_path))
                .headers(extra_headers)
                .body(bytes);
            let req = self.apply_s3_auth(req, "PUT", &raw_path, None, &sha256)?;
            req.send()
                .await
                .with_context(|| format!("upload failed: PUT {raw_path}"))?
        } else {
            let raw_path = format!("/v1/buckets/{bucket}/objects/{encoded_key}");
            let req = self.apply_bearer(
                self.http
                    .put(self.url(&raw_path))
                    .headers(extra_headers)
                    .body(bytes),
            );
            req.send()
                .await
                .with_context(|| format!("upload failed: PUT {raw_path}"))?
        };

        let resp = check_response(resp).await?;
        let etag = resp
            .headers()
            .get("etag")
            .and_then(|v| v.to_str().ok())
            .map(|s| s.trim_matches('"').to_string());

        Ok(PutSummary {
            bucket: bucket.to_string(),
            key: key.to_string(),
            size: file_size,
            sha256,
            etag,
            multipart: false,
            parts: 1,
        })
    }

    async fn put_file_multipart(
        &self,
        bucket: &str,
        key: &str,
        local_path: &Path,
        file_size: u64,
        content_type: Option<&str>,
        metadata: &BTreeMap<String, String>,
    ) -> Result<PutSummary> {
        let encoded_key = uri_encode(key, false);
        let raw_path = format!("/s3/{bucket}/{encoded_key}");
        let extra_headers = build_meta_headers(content_type, metadata)?;

        // 1. Initiate multipart upload
        let init_query = "uploads=";
        let init_url = format!("{}?uploads", self.url(&raw_path));
        let req = self.http.post(&init_url).headers(extra_headers);
        let req = self.apply_s3_auth(req, "POST", &raw_path, Some(init_query), EMPTY_SHA256)?;
        let resp = check_response(
            req.send()
                .await
                .context("failed to initiate multipart upload")?,
        )
        .await?;
        let init_xml = resp.text().await?;
        let upload_id = parse_xml_tag(&init_xml, "UploadId")
            .ok_or_else(|| anyhow!("multipart init response missing <UploadId>"))?;

        // 2. Upload parts in 16 MiB streaming chunks; abort on any error
        let upload_res: Result<(String, String, usize)> = async {
            let mut file = File::open(local_path).await?;
            let mut whole_hasher = Sha256::new();
            let mut parts: Vec<(usize, String)> = Vec::new();
            let mut part_number = 1usize;

            loop {
                let chunk = read_chunk(&mut file, MULTIPART_PART_SIZE).await?;
                if chunk.is_empty() {
                    break;
                }
                whole_hasher.update(&chunk);
                let part_sha = sha256_hex(&chunk);
                let query = format!(
                    "partNumber={part_number}&uploadId={}",
                    uri_encode(&upload_id, true)
                );
                let part_url = format!("{}?{query}", self.url(&raw_path));
                let req = self.http.put(&part_url).body(chunk);
                let req = self.apply_s3_auth(req, "PUT", &raw_path, Some(&query), &part_sha)?;
                let resp = check_response(
                    req.send()
                        .await
                        .with_context(|| format!("failed to upload part {part_number}"))?,
                )
                .await?;
                let etag = resp
                    .headers()
                    .get("etag")
                    .and_then(|v| v.to_str().ok())
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| format!("\"{part_sha}\""));
                parts.push((part_number, etag));
                part_number += 1;
            }

            // 3. Complete multipart upload
            let mut xml = String::from("<CompleteMultipartUpload>");
            for (num, etag) in &parts {
                let clean_etag = etag.trim_matches('"');
                xml.push_str(&format!(
                    "<Part><PartNumber>{num}</PartNumber><ETag>\"{clean_etag}\"</ETag></Part>"
                ));
            }
            xml.push_str("</CompleteMultipartUpload>");
            let xml_sha = sha256_hex(xml.as_bytes());
            let complete_query = format!("uploadId={}", uri_encode(&upload_id, true));
            let complete_url = format!("{}?{complete_query}", self.url(&raw_path));
            let req = self
                .http
                .post(&complete_url)
                .header(CONTENT_TYPE, "application/xml")
                .body(xml);
            let req =
                self.apply_s3_auth(req, "POST", &raw_path, Some(&complete_query), &xml_sha)?;
            let resp = check_response(
                req.send()
                    .await
                    .context("failed to complete multipart upload")?,
            )
            .await?;
            let complete_xml = resp.text().await.unwrap_or_default();
            let final_etag = parse_xml_tag(&complete_xml, "ETag")
                .map(|s| s.trim_matches('"').to_string())
                .unwrap_or_else(|| format!("multipart-{}", parts.len()));
            let whole_sha = hex_encode(&whole_hasher.finalize());
            Ok((whole_sha, final_etag, parts.len()))
        }
        .await;

        match upload_res {
            Ok((sha256, etag, part_count)) => Ok(PutSummary {
                bucket: bucket.to_string(),
                key: key.to_string(),
                size: file_size,
                sha256,
                etag: Some(etag),
                multipart: true,
                parts: part_count,
            }),
            Err(err) => {
                // Best-effort abort so no orphaned parts remain on the server
                let abort_query = format!("uploadId={}", uri_encode(&upload_id, true));
                let abort_url = format!("{}?{abort_query}", self.url(&raw_path));
                if let Ok(req) = self.apply_s3_auth(
                    self.http.delete(&abort_url),
                    "DELETE",
                    &raw_path,
                    Some(&abort_query),
                    EMPTY_SHA256,
                ) {
                    let _ = req.send().await;
                }
                Err(err)
            }
        }
    }

    /// Streams an object download to a local file (atomic temp + rename) or stdout (`out_path == "-"`).
    pub async fn get_object(
        &self,
        bucket: &str,
        key: &str,
        out_path: &Path,
        range: Option<&str>,
    ) -> Result<u64> {
        let encoded_key = uri_encode(key, false);
        let req = if self.has_s3_keys() {
            let raw_path = format!("/s3/{bucket}/{encoded_key}");
            let mut req = self.http.get(self.url(&raw_path));
            if let Some(r) = range {
                req = req.header(RANGE, format!("bytes={r}"));
            }
            self.apply_s3_auth(req, "GET", &raw_path, None, EMPTY_SHA256)?
        } else {
            let raw_path = format!("/v1/buckets/{bucket}/objects/{encoded_key}");
            let mut req = self.apply_bearer(self.http.get(self.url(&raw_path)));
            if let Some(r) = range {
                req = req.header(RANGE, format!("bytes={r}"));
            }
            req
        };

        let resp = check_response(
            req.send()
                .await
                .with_context(|| format!("download failed for {bucket}/{key}"))?,
        )
        .await?;

        stream_response_to_path(resp, out_path).await
    }

    /// Streams any Bearer-authenticated GET endpoint (e.g. photo original/thumb) to a file or `-`.
    pub async fn download_bearer_to_path(&self, path: &str, out_path: &Path) -> Result<u64> {
        let resp = self
            .apply_bearer(self.http.get(self.url(path)))
            .send()
            .await
            .with_context(|| format!("download failed: GET {path}"))?;
        let resp = check_response(resp).await?;
        stream_response_to_path(resp, out_path).await
    }

    /// Uploads a photo/video asset to `PUT /v1/assets` with `X-Filename`, `X-Content-Hash`, `X-Source: cli`.
    pub async fn upload_photo_asset(
        &self,
        local_path: &Path,
        filename: &str,
        sha256: &str,
    ) -> Result<serde_json::Value> {
        let bytes = tokio::fs::read(local_path)
            .await
            .with_context(|| format!("cannot read {}", local_path.display()))?;
        let encoded_name = uri_encode(filename, true);
        let resp = self
            .apply_bearer(
                self.http
                    .put(self.url("/v1/assets"))
                    .header("x-filename", encoded_name)
                    .header("x-content-hash", sha256)
                    .header("x-source", "cli")
                    .body(bytes),
            )
            .send()
            .await
            .with_context(|| format!("upload failed for {}", local_path.display()))?;
        let resp = check_response(resp).await?;
        resp.json::<serde_json::Value>()
            .await
            .context("invalid JSON from PUT /v1/assets")
    }
}

/// Streams a `reqwest::Response` to stdout (`"-"`) or atomically via a temp file + rename.
pub async fn stream_response_to_path(mut resp: Response, out_path: &Path) -> Result<u64> {
    if out_path == Path::new("-") {
        let mut stdout = tokio::io::stdout();
        let mut total = 0u64;
        while let Some(chunk) = resp.chunk().await? {
            stdout.write_all(&chunk).await?;
            total += chunk.len() as u64;
        }
        stdout.flush().await?;
        return Ok(total);
    }

    let parent = out_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    tokio::fs::create_dir_all(parent)
        .await
        .with_context(|| format!("cannot create directory {}", parent.display()))?;

    let tmp_path = parent.join(format!(
        ".atlas-dl-{}-{}.tmp",
        std::process::id(),
        Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    let mut file = File::create(&tmp_path)
        .await
        .with_context(|| format!("cannot create {}", tmp_path.display()))?;

    let mut total = 0u64;
    let res: Result<()> = async {
        while let Some(chunk) = resp.chunk().await? {
            file.write_all(&chunk).await?;
            total += chunk.len() as u64;
        }
        file.flush().await?;
        file.sync_all().await?;
        Ok(())
    }
    .await;

    if let Err(e) = res {
        drop(file);
        let _ = tokio::fs::remove_file(&tmp_path).await;
        return Err(e);
    }
    drop(file);

    tokio::fs::rename(&tmp_path, out_path)
        .await
        .with_context(|| format!("failed to finalize {}", out_path.display()))?;
    Ok(total)
}

async fn read_chunk(file: &mut File, max_len: usize) -> Result<Vec<u8>> {
    let mut buf = vec![0u8; max_len];
    let mut filled = 0;
    while filled < max_len {
        let n = file.read(&mut buf[filled..]).await?;
        if n == 0 {
            break;
        }
        filled += n;
    }
    buf.truncate(filled);
    Ok(buf)
}

fn build_meta_headers(
    content_type: Option<&str>,
    metadata: &BTreeMap<String, String>,
) -> Result<HeaderMap> {
    let mut headers = HeaderMap::new();
    if let Some(ct) = content_type {
        let val = HeaderValue::from_str(ct)
            .with_context(|| format!("invalid content-type header: {ct}"))?;
        headers.insert(CONTENT_TYPE, val);
    }
    for (k, v) in metadata {
        let name = format!("x-amz-meta-{}", k.to_ascii_lowercase());
        let hname = HeaderName::from_bytes(name.as_bytes())
            .with_context(|| format!("invalid metadata key: {k}"))?;
        let hval =
            HeaderValue::from_str(v).with_context(|| format!("invalid metadata value for {k}"))?;
        headers.insert(hname, hval);
    }
    Ok(headers)
}

/// Checks an HTTP response status and turns non-2xx responses into a sanitized error.
pub async fn check_response(resp: Response) -> Result<Response> {
    let status = resp.status();
    if status.is_success() {
        return Ok(resp);
    }
    let body = resp.text().await.unwrap_or_default();
    let msg = extract_error_message(&body);
    let safe_msg = sanitize_for_tty(&msg);
    if safe_msg.is_empty() {
        bail!("server returned HTTP {}", status);
    } else {
        bail!("server returned HTTP {}: {}", status, safe_msg);
    }
}

fn extract_error_message(body: &str) -> String {
    let trimmed = body.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(trimmed) {
        if let Some(msg) = val.get("error").and_then(|v| v.as_str()) {
            return msg.to_string();
        }
        if let Some(msg) = val.get("message").and_then(|v| v.as_str()) {
            return msg.to_string();
        }
    }
    if let Some(msg) = parse_xml_tag(trimmed, "Message") {
        return msg;
    }
    trimmed.chars().take(300).collect()
}

/// Extracts the text content of the first matching XML tag name using `roxmltree`.
pub fn parse_xml_tag(xml: &str, tag: &str) -> Option<String> {
    let doc = roxmltree::Document::parse(xml).ok()?;
    doc.descendants()
        .find(|n| n.is_element() && n.tag_name().name() == tag)
        .and_then(|n| n.text())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Streaming SHA-256 of a local file without loading it into memory.
pub async fn hash_file_sha256(path: &Path) -> Result<(String, u64)> {
    let mut file = File::open(path)
        .await
        .with_context(|| format!("cannot open {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    let mut total = 0u64;
    loop {
        let n = file.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        total += n as u64;
    }
    Ok((hex_encode(&hasher.finalize()), total))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_s3_xml_tags() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
            <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                <Bucket>files</Bucket>
                <Key>big.bin</Key>
                <UploadId>mpu_123456</UploadId>
            </InitiateMultipartUploadResult>"#;
        assert_eq!(
            parse_xml_tag(xml, "UploadId").as_deref(),
            Some("mpu_123456")
        );
        assert_eq!(parse_xml_tag(xml, "Missing"), None);
    }

    #[test]
    fn extracts_json_and_xml_errors() {
        assert_eq!(
            extract_error_message(r#"{"error":"bucket already exists"}"#),
            "bucket already exists"
        );
        assert_eq!(
            extract_error_message(
                "<Error><Code>NoSuchKey</Code><Message>not found</Message></Error>"
            ),
            "not found"
        );
    }
}
