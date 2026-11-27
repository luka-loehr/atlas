//! `atlas files` (alias `atlas s3`) — streaming S3 & object storage operations.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use atlas_common::models::{
    BatchDeleteRequest, BatchDeleteResponse, CopyObjectRequest, ListObjectsResponse, ObjectInfo,
    PresignRequest, PresignResponse,
};
use atlas_common::s3::presign_url;
use atlas_common::validate::{is_valid_bucket_name, normalize_object_key, uri_encode};
use chrono::Utc;
use clap::{Parser, Subcommand};
use serde_json::Value;

use crate::client::{AtlasClient, DEFAULT_MULTIPART_THRESHOLD_MB, hash_file_sha256};
use crate::cmd::buckets::list_buckets;
use crate::cmd::{argv_with_name, run_async};
use crate::sanitize::{format_bytes, format_i64_bytes, sanitize_for_tty};
use crate::{DIM, GREEN, RESET};

#[derive(Parser)]
#[command(
    name = "atlas files",
    about = "Manage objects in Atlas buckets (alias: `atlas s3`)"
)]
struct FilesCli {
    #[command(subcommand)]
    cmd: FilesCmd,
}

#[derive(Subcommand)]
enum FilesCmd {
    /// List buckets or objects under <bucket>[/<prefix>] (or s3://<bucket>[/<prefix>])
    Ls {
        /// Optional target bucket or prefix (omit to list buckets)
        target: Option<String>,
        /// List recursively without '/' delimiter
        #[arg(short = 'r', long)]
        recursive: bool,
        /// Maximum number of entries to return
        #[arg(long)]
        limit: Option<u32>,
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// Upload a local file (streaming; automatic S3 Multipart Upload above --multipart-mb)
    Put {
        /// Local file path
        local_path: PathBuf,
        /// Remote destination: <bucket>/<key> or s3://<bucket>/<key>
        target: String,
        /// Explicit Content-Type header
        #[arg(long = "content-type")]
        content_type: Option<String>,
        /// User metadata entries in k=v format (repeatable)
        #[arg(long = "meta")]
        meta: Vec<String>,
        /// Multipart upload threshold in MiB (default: 64)
        #[arg(long = "multipart-mb", default_value_t = DEFAULT_MULTIPART_THRESHOLD_MB)]
        multipart_mb: u64,
        /// Print machine-readable JSON summary
        #[arg(long)]
        json: bool,
    },
    /// Download an object to a local file (atomic) or '-' for stdout
    Get {
        /// Remote object: <bucket>/<key> or s3://<bucket>/<key>
        target: String,
        /// Local output path (defaults to object filename; '-' for stdout)
        local_path: Option<PathBuf>,
        /// Optional byte range START-END (e.g. 0-1023)
        #[arg(long)]
        range: Option<String>,
    },
    /// Copy between local and remote paths, or server-side remote -> remote
    Cp {
        /// Source path (local or <bucket>/<key> or s3://<bucket>/<key>)
        src: String,
        /// Destination path (local or <bucket>/<key> or s3://<bucket>/<key>)
        dst: String,
        /// Copy directories / prefixes recursively
        #[arg(short = 'r', long)]
        recursive: bool,
    },
    /// Synchronize a local directory and a remote bucket/prefix by size & SHA-256
    Sync {
        /// Source (local dir or remote bucket/prefix)
        src: String,
        /// Destination (remote bucket/prefix or local dir)
        dst: String,
        /// Delete destination files that do not exist at the source
        #[arg(long)]
        delete: bool,
        /// Print planned operations without transferring or deleting anything
        #[arg(long = "dry-run")]
        dry_run: bool,
    },
    /// Remove an object or prefix (-r)
    Rm {
        /// Remote object or prefix: <bucket>/<key> or s3://<bucket>/<key>
        target: String,
        /// Recursively delete all objects under the prefix
        #[arg(short = 'r', long)]
        recursive: bool,
    },
    /// Inspect object metadata, size, ETag, and SHA-256
    Stat {
        /// Remote object: <bucket>/<key> or s3://<bucket>/<key>
        target: String,
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// Search objects within a bucket or across Atlas Drive
    Search {
        /// Search query
        query: String,
        /// Restrict search to a specific bucket
        #[arg(long)]
        bucket: Option<String>,
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// Generate a time-limited presigned URL (server API with offline SigV4 fallback)
    Presign {
        /// Remote object: <bucket>/<key> or s3://<bucket>/<key>
        target: String,
        /// Expiration in seconds (default: 3600)
        #[arg(long, default_value_t = 3600)]
        expires: u64,
        /// HTTP method: GET or PUT
        #[arg(long, default_value = "GET")]
        method: String,
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
}

/// Parsed remote target: `<bucket>` or `<bucket>/<key>` or `s3://<bucket>[/<key>]`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemotePath {
    pub bucket: String,
    pub key: String,
    pub had_trailing_slash: bool,
}

impl RemotePath {
    /// Parses `s3://<bucket>[/<key>]` or `<bucket>[/<key>]`.
    pub fn parse(raw: &str) -> Result<Self> {
        let stripped = raw.strip_prefix("s3://").unwrap_or(raw);
        let stripped = stripped.trim_start_matches('/');
        if stripped.is_empty() {
            bail!("empty remote path");
        }
        let (bucket, rest) = match stripped.split_once('/') {
            Some((b, k)) => (b, k),
            None => (stripped, ""),
        };
        if !is_valid_bucket_name(bucket) {
            bail!("invalid bucket name '{}'", sanitize_for_tty(bucket));
        }
        let had_trailing_slash = rest.ends_with('/');
        let key = if rest.is_empty() {
            String::new()
        } else {
            normalize_object_key(rest)
                .ok_or_else(|| anyhow!("invalid object key '{}'", sanitize_for_tty(rest)))?
        };
        Ok(Self {
            bucket: bucket.to_string(),
            key,
            had_trailing_slash,
        })
    }

    pub fn require_key(&self) -> Result<&str> {
        if self.key.is_empty() {
            bail!(
                "object key required (got bucket '{}' without a key)",
                sanitize_for_tty(&self.bucket)
            );
        }
        Ok(&self.key)
    }
}

/// Returns true if `raw` should be treated as a remote Atlas path rather than a local filesystem path.
fn is_remote_arg(raw: &str) -> bool {
    if raw.starts_with("s3://") {
        return true;
    }
    if raw == "-" || raw.starts_with('/') || raw.starts_with('.') || raw.starts_with('~') {
        return false;
    }
    if Path::new(raw).exists() {
        return false;
    }
    // Check if the first segment is a valid bucket name
    let first = raw.split('/').next().unwrap_or("");
    is_valid_bucket_name(first)
}

pub fn run(args: &[String]) {
    let cli = FilesCli::parse_from(argv_with_name("files", args));
    run_async(exec(cli.cmd));
}

async fn exec(cmd: FilesCmd) -> Result<()> {
    let client = AtlasClient::from_env()?;
    match cmd {
        FilesCmd::Ls {
            target,
            recursive,
            limit,
            json,
        } => cmd_ls(&client, target, recursive, limit, json).await,
        FilesCmd::Put {
            local_path,
            target,
            content_type,
            meta,
            multipart_mb,
            json,
        } => {
            cmd_put(
                &client,
                &local_path,
                &target,
                content_type.as_deref(),
                &meta,
                multipart_mb,
                json,
            )
            .await
        }
        FilesCmd::Get {
            target,
            local_path,
            range,
        } => cmd_get(&client, &target, local_path.as_deref(), range.as_deref()).await,
        FilesCmd::Cp {
            src,
            dst,
            recursive,
        } => cmd_cp(&client, &src, &dst, recursive).await,
        FilesCmd::Sync {
            src,
            dst,
            delete,
            dry_run,
        } => cmd_sync(&client, &src, &dst, delete, dry_run).await,
        FilesCmd::Rm { target, recursive } => cmd_rm(&client, &target, recursive).await,
        FilesCmd::Stat { target, json } => cmd_stat(&client, &target, json).await,
        FilesCmd::Search {
            query,
            bucket,
            json,
        } => cmd_search(&client, &query, bucket.as_deref(), json).await,
        FilesCmd::Presign {
            target,
            expires,
            method,
            json,
        } => cmd_presign(&client, &target, expires, &method, json).await,
    }
}

async fn cmd_ls(
    client: &AtlasClient,
    target: Option<String>,
    recursive: bool,
    limit: Option<u32>,
    json_out: bool,
) -> Result<()> {
    let Some(target) = target else {
        return list_buckets(client, json_out).await;
    };
    let remote = RemotePath::parse(&target)?;
    let mut query_parts = Vec::new();
    if !remote.key.is_empty() {
        query_parts.push(format!("prefix={}", uri_encode(&remote.key, true)));
    }
    if !recursive {
        query_parts.push("delimiter=%2F".to_string());
    }
    if let Some(lim) = limit {
        query_parts.push(format!("limit={lim}"));
    }
    let path = if query_parts.is_empty() {
        format!("/v1/buckets/{}/objects", uri_encode(&remote.bucket, true))
    } else {
        format!(
            "/v1/buckets/{}/objects?{}",
            uri_encode(&remote.bucket, true),
            query_parts.join("&")
        )
    };
    let res: ListObjectsResponse = client.get_json(&path).await?;
    if json_out {
        println!("{}", serde_json::to_string_pretty(&res)?);
        return Ok(());
    }
    if res.common_prefixes.is_empty() && res.objects.is_empty() {
        println!("(empty)");
        return Ok(());
    }
    for prefix in &res.common_prefixes {
        println!(
            "{:>10}  {}/",
            "DIR",
            sanitize_for_tty(prefix.trim_end_matches('/'))
        );
    }
    for obj in &res.objects {
        println!(
            "{:>10}  {}  {}",
            format_i64_bytes(obj.size),
            obj.updated_at.format("%Y-%m-%d %H:%M"),
            sanitize_for_tty(&obj.key)
        );
    }
    if res.is_truncated {
        println!("{DIM}(truncated; pass --limit for more){RESET}");
    }
    Ok(())
}

fn parse_meta_pairs(raw: &[String]) -> Result<BTreeMap<String, String>> {
    let mut map = BTreeMap::new();
    for item in raw {
        let Some((k, v)) = item.split_once('=') else {
            bail!(
                "invalid --meta '{}' (expected key=value)",
                sanitize_for_tty(item)
            );
        };
        let k = k.trim();
        if k.is_empty() {
            bail!("empty metadata key in '{}'", sanitize_for_tty(item));
        }
        map.insert(k.to_string(), v.to_string());
    }
    Ok(map)
}

async fn cmd_put(
    client: &AtlasClient,
    local_path: &Path,
    target: &str,
    content_type: Option<&str>,
    meta_raw: &[String],
    multipart_mb: u64,
    json_out: bool,
) -> Result<()> {
    let remote = RemotePath::parse(target)?;
    let key = if remote.key.is_empty() || remote.had_trailing_slash {
        let fname = local_path
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or_else(|| anyhow!("cannot determine filename from {}", local_path.display()))?;
        if remote.key.is_empty() {
            fname.to_string()
        } else {
            format!("{}{fname}", remote.key)
        }
    } else {
        remote.key.clone()
    };
    let metadata = parse_meta_pairs(meta_raw)?;
    let threshold_bytes = multipart_mb.saturating_mul(1024 * 1024);

    let summary = client
        .put_file(
            &remote.bucket,
            &key,
            local_path,
            content_type,
            &metadata,
            threshold_bytes,
        )
        .await?;

    if json_out {
        println!("{}", serde_json::to_string_pretty(&summary)?);
    } else {
        let mode = if summary.multipart {
            format!("multipart, {} parts", summary.parts)
        } else {
            "single-part".to_string()
        };
        println!(
            "{GREEN}uploaded{RESET} {} -> s3://{}/{} ({}, {mode})",
            local_path.display(),
            sanitize_for_tty(&summary.bucket),
            sanitize_for_tty(&summary.key),
            format_bytes(summary.size)
        );
    }
    Ok(())
}

fn default_local_name_for_key(key: &str) -> Result<PathBuf> {
    let base = key.rsplit('/').next().unwrap_or(key);
    if base.is_empty() || base == "." || base == ".." || base.contains('\\') {
        bail!(
            "cannot derive safe local filename from key '{}'; pass an explicit output path",
            sanitize_for_tty(key)
        );
    }
    Ok(PathBuf::from(base))
}

async fn cmd_get(
    client: &AtlasClient,
    target: &str,
    local_path: Option<&Path>,
    range: Option<&str>,
) -> Result<()> {
    let remote = RemotePath::parse(target)?;
    let key = remote.require_key()?;
    let out = match local_path {
        Some(p) => p.to_path_buf(),
        None => default_local_name_for_key(key)?,
    };

    let bytes = client.get_object(&remote.bucket, key, &out, range).await?;
    if out != Path::new("-") {
        println!(
            "{GREEN}downloaded{RESET} s3://{}/{} -> {} ({})",
            sanitize_for_tty(&remote.bucket),
            sanitize_for_tty(key),
            out.display(),
            format_bytes(bytes)
        );
    }
    Ok(())
}

async fn cmd_cp(client: &AtlasClient, src: &str, dst: &str, recursive: bool) -> Result<()> {
    let src_remote = is_remote_arg(src);
    let dst_remote = is_remote_arg(dst);

    match (src_remote, dst_remote) {
        (true, true) => {
            let s = RemotePath::parse(src)?;
            let d = RemotePath::parse(dst)?;
            if recursive {
                let objs = list_all_objects(client, &s.bucket, &s.key).await?;
                let src_prefix = if s.key.is_empty() || s.key.ends_with('/') {
                    s.key.clone()
                } else {
                    format!("{}/", s.key)
                };
                for obj in objs {
                    let rel = obj.key.strip_prefix(&src_prefix).unwrap_or(&obj.key);
                    let dst_key = join_remote_prefix(&d.key, rel);
                    let req = CopyObjectRequest {
                        src_bucket: s.bucket.clone(),
                        src_key: obj.key.clone(),
                        dst_key: dst_key.clone(),
                        metadata: None,
                    };
                    let _: ObjectInfo = client
                        .post_json(
                            &format!("/v1/buckets/{}/copy", uri_encode(&d.bucket, true)),
                            &req,
                        )
                        .await?;
                    println!(
                        "{GREEN}copied{RESET} s3://{}/{} -> s3://{}/{}",
                        sanitize_for_tty(&s.bucket),
                        sanitize_for_tty(&obj.key),
                        sanitize_for_tty(&d.bucket),
                        sanitize_for_tty(&dst_key)
                    );
                }
            } else {
                let sk = s.require_key()?;
                let dk = if d.key.is_empty() || d.had_trailing_slash {
                    let base = sk.rsplit('/').next().unwrap_or(sk);
                    join_remote_prefix(&d.key, base)
                } else {
                    d.key.clone()
                };
                let req = CopyObjectRequest {
                    src_bucket: s.bucket.clone(),
                    src_key: sk.to_string(),
                    dst_key: dk.clone(),
                    metadata: None,
                };
                let _: ObjectInfo = client
                    .post_json(
                        &format!("/v1/buckets/{}/copy", uri_encode(&d.bucket, true)),
                        &req,
                    )
                    .await?;
                println!(
                    "{GREEN}copied{RESET} s3://{}/{} -> s3://{}/{}",
                    sanitize_for_tty(&s.bucket),
                    sanitize_for_tty(sk),
                    sanitize_for_tty(&d.bucket),
                    sanitize_for_tty(&dk)
                );
            }
        }
        (false, true) => {
            let local = Path::new(src);
            let d = RemotePath::parse(dst)?;
            if local.is_dir() {
                if !recursive {
                    bail!(
                        "{} is a directory; pass -r to copy recursively",
                        local.display()
                    );
                }
                let files = collect_local_files(local)?;
                let threshold = DEFAULT_MULTIPART_THRESHOLD_MB * 1024 * 1024;
                for (rel, full) in files {
                    let key = join_remote_prefix(&d.key, &rel);
                    let summary = client
                        .put_file(&d.bucket, &key, &full, None, &BTreeMap::new(), threshold)
                        .await?;
                    println!(
                        "{GREEN}uploaded{RESET} {} -> s3://{}/{} ({})",
                        full.display(),
                        sanitize_for_tty(&d.bucket),
                        sanitize_for_tty(&key),
                        format_bytes(summary.size)
                    );
                }
            } else {
                cmd_put(
                    client,
                    local,
                    dst,
                    None,
                    &[],
                    DEFAULT_MULTIPART_THRESHOLD_MB,
                    false,
                )
                .await?;
            }
        }
        (true, false) => {
            let s = RemotePath::parse(src)?;
            let local_dst = Path::new(dst);
            if recursive {
                let objs = list_all_objects(client, &s.bucket, &s.key).await?;
                let src_prefix = if s.key.is_empty() || s.key.ends_with('/') {
                    s.key.clone()
                } else {
                    format!("{}/", s.key)
                };
                for obj in objs {
                    let rel = obj.key.strip_prefix(&src_prefix).unwrap_or(&obj.key);
                    let out = safe_join_local(local_dst, rel)?;
                    let bytes = client.get_object(&s.bucket, &obj.key, &out, None).await?;
                    println!(
                        "{GREEN}downloaded{RESET} s3://{}/{} -> {} ({})",
                        sanitize_for_tty(&s.bucket),
                        sanitize_for_tty(&obj.key),
                        out.display(),
                        format_bytes(bytes)
                    );
                }
            } else {
                let sk = s.require_key()?;
                let out = if local_dst.is_dir() {
                    local_dst.join(default_local_name_for_key(sk)?)
                } else {
                    local_dst.to_path_buf()
                };
                let bytes = client.get_object(&s.bucket, sk, &out, None).await?;
                println!(
                    "{GREEN}downloaded{RESET} s3://{}/{} -> {} ({})",
                    sanitize_for_tty(&s.bucket),
                    sanitize_for_tty(sk),
                    out.display(),
                    format_bytes(bytes)
                );
            }
        }
        (false, false) => {
            bail!(
                "at least one of <src> or <dst> must be a remote Atlas path (e.g. s3://bucket/key)"
            );
        }
    }
    Ok(())
}

async fn cmd_sync(
    client: &AtlasClient,
    src: &str,
    dst: &str,
    delete: bool,
    dry_run: bool,
) -> Result<()> {
    let src_remote = is_remote_arg(src);
    let dst_remote = is_remote_arg(dst);
    let threshold = DEFAULT_MULTIPART_THRESHOLD_MB * 1024 * 1024;

    match (src_remote, dst_remote) {
        // Local directory -> Remote bucket/prefix
        (false, true) => {
            let local_root = Path::new(src);
            if !local_root.is_dir() {
                bail!(
                    "sync source must be a local directory: {}",
                    local_root.display()
                );
            }
            let remote = RemotePath::parse(dst)?;
            let remote_objs = list_all_objects(client, &remote.bucket, &remote.key).await?;
            let prefix = normalize_prefix_dir(&remote.key);

            let mut remote_by_rel: HashMap<String, ObjectInfo> = HashMap::new();
            for obj in remote_objs {
                let rel = obj
                    .key
                    .strip_prefix(&prefix)
                    .unwrap_or(&obj.key)
                    .to_string();
                remote_by_rel.insert(rel, obj);
            }

            let local_files = collect_local_files(local_root)?;
            let mut seen_rel = std::collections::HashSet::new();
            let mut uploaded = 0usize;
            let mut skipped = 0usize;

            for (rel, full_path) in local_files {
                seen_rel.insert(rel.clone());
                let (local_sha, local_size) = hash_file_sha256(&full_path).await?;
                let needs_upload = match remote_by_rel.get(&rel) {
                    Some(obj) => {
                        obj.size as u64 != local_size
                            || (!obj.sha256.is_empty()
                                && !obj.sha256.eq_ignore_ascii_case(&local_sha))
                    }
                    None => true,
                };
                if !needs_upload {
                    skipped += 1;
                    continue;
                }
                let dst_key = join_remote_prefix(&remote.key, &rel);
                if dry_run {
                    println!(
                        "[dry-run] upload {} -> s3://{}/{}",
                        full_path.display(),
                        sanitize_for_tty(&remote.bucket),
                        sanitize_for_tty(&dst_key)
                    );
                } else {
                    client
                        .put_file(
                            &remote.bucket,
                            &dst_key,
                            &full_path,
                            None,
                            &BTreeMap::new(),
                            threshold,
                        )
                        .await?;
                    println!(
                        "{GREEN}upload{RESET} {} -> s3://{}/{}",
                        full_path.display(),
                        sanitize_for_tty(&remote.bucket),
                        sanitize_for_tty(&dst_key)
                    );
                }
                uploaded += 1;
            }

            let mut deleted = 0usize;
            if delete {
                let mut to_delete: Vec<String> = remote_by_rel
                    .into_iter()
                    .filter(|(rel, _)| !seen_rel.contains(rel))
                    .map(|(_, obj)| obj.key)
                    .collect();
                to_delete.sort();
                if dry_run {
                    for k in &to_delete {
                        println!(
                            "[dry-run] delete s3://{}/{}",
                            sanitize_for_tty(&remote.bucket),
                            sanitize_for_tty(k)
                        );
                    }
                    deleted = to_delete.len();
                } else if !to_delete.is_empty() {
                    deleted = batch_delete_keys(client, &remote.bucket, &to_delete).await?;
                    for k in &to_delete {
                        println!(
                            "delete s3://{}/{}",
                            sanitize_for_tty(&remote.bucket),
                            sanitize_for_tty(k)
                        );
                    }
                }
            }
            println!("sync complete: {uploaded} uploaded, {skipped} unchanged, {deleted} deleted");
        }
        // Remote bucket/prefix -> Local directory
        (true, false) => {
            let remote = RemotePath::parse(src)?;
            let local_root = Path::new(dst);
            if !dry_run {
                tokio::fs::create_dir_all(local_root).await?;
            }
            let remote_objs = list_all_objects(client, &remote.bucket, &remote.key).await?;
            let prefix = normalize_prefix_dir(&remote.key);

            let mut seen_rel = std::collections::HashSet::new();
            let mut downloaded = 0usize;
            let mut skipped = 0usize;

            for obj in remote_objs {
                let rel = obj
                    .key
                    .strip_prefix(&prefix)
                    .unwrap_or(&obj.key)
                    .to_string();
                if rel.is_empty() || rel.ends_with('/') {
                    continue;
                }
                seen_rel.insert(rel.clone());
                let out_path = safe_join_local(local_root, &rel)?;

                let needs_download = if out_path.is_file() {
                    let (local_sha, local_size) = hash_file_sha256(&out_path).await?;
                    obj.size as u64 != local_size
                        || (!obj.sha256.is_empty() && !obj.sha256.eq_ignore_ascii_case(&local_sha))
                } else {
                    true
                };

                if !needs_download {
                    skipped += 1;
                    continue;
                }
                if dry_run {
                    println!(
                        "[dry-run] download s3://{}/{} -> {}",
                        sanitize_for_tty(&remote.bucket),
                        sanitize_for_tty(&obj.key),
                        out_path.display()
                    );
                } else {
                    client
                        .get_object(&remote.bucket, &obj.key, &out_path, None)
                        .await?;
                    println!(
                        "{GREEN}download{RESET} s3://{}/{} -> {}",
                        sanitize_for_tty(&remote.bucket),
                        sanitize_for_tty(&obj.key),
                        out_path.display()
                    );
                }
                downloaded += 1;
            }

            let mut deleted = 0usize;
            if delete && local_root.is_dir() {
                for (rel, full_path) in collect_local_files(local_root)? {
                    if !seen_rel.contains(&rel) {
                        if dry_run {
                            println!("[dry-run] delete {}", full_path.display());
                        } else {
                            tokio::fs::remove_file(&full_path).await?;
                            println!("delete {}", full_path.display());
                        }
                        deleted += 1;
                    }
                }
            }
            println!(
                "sync complete: {downloaded} downloaded, {skipped} unchanged, {deleted} deleted"
            );
        }
        _ => bail!("sync requires one local directory and one remote bucket/prefix"),
    }
    Ok(())
}

async fn cmd_rm(client: &AtlasClient, target: &str, recursive: bool) -> Result<()> {
    let remote = RemotePath::parse(target)?;
    if recursive {
        let objs = list_all_objects(client, &remote.bucket, &remote.key).await?;
        let keys: Vec<String> = objs.into_iter().map(|o| o.key).collect();
        if keys.is_empty() {
            println!("(no matching objects)");
            return Ok(());
        }
        let count = batch_delete_keys(client, &remote.bucket, &keys).await?;
        println!(
            "{GREEN}deleted{RESET} {count} object(s) from {}",
            sanitize_for_tty(&remote.bucket)
        );
    } else {
        let key = remote.require_key()?;
        let path = format!(
            "/v1/buckets/{}/objects/{}",
            uri_encode(&remote.bucket, true),
            uri_encode(key, false)
        );
        client.delete_empty(&path).await?;
        println!(
            "{GREEN}deleted{RESET} s3://{}/{}",
            sanitize_for_tty(&remote.bucket),
            sanitize_for_tty(key)
        );
    }
    Ok(())
}

async fn cmd_stat(client: &AtlasClient, target: &str, json_out: bool) -> Result<()> {
    let remote = RemotePath::parse(target)?;
    let key = remote.require_key()?;
    let path = format!(
        "/v1/buckets/{}/stat/{}",
        uri_encode(&remote.bucket, true),
        uri_encode(key, false)
    );
    let info: ObjectInfo = client.get_json(&path).await?;
    if json_out {
        println!("{}", serde_json::to_string_pretty(&info)?);
        return Ok(());
    }
    println!("Bucket:       {}", sanitize_for_tty(&info.bucket));
    println!("Key:          {}", sanitize_for_tty(&info.key));
    println!(
        "Size:         {} ({} bytes)",
        format_i64_bytes(info.size),
        info.size
    );
    println!("Content-Type: {}", sanitize_for_tty(&info.content_type));
    println!("ETag:         {}", sanitize_for_tty(&info.etag));
    println!("SHA-256:      {}", sanitize_for_tty(&info.sha256));
    println!("Updated:      {}", info.updated_at.to_rfc3339());
    if !info.metadata.is_empty() {
        println!("Metadata:");
        for (k, v) in &info.metadata {
            println!("  {}: {}", sanitize_for_tty(k), sanitize_for_tty(v));
        }
    }
    Ok(())
}

async fn cmd_search(
    client: &AtlasClient,
    query: &str,
    bucket: Option<&str>,
    json_out: bool,
) -> Result<()> {
    let q = uri_encode(query, true);
    if let Some(bucket) = bucket {
        let path = format!("/v1/buckets/{}/objects?q={q}", uri_encode(bucket, true));
        let res: ListObjectsResponse = client.get_json(&path).await?;
        if json_out {
            println!("{}", serde_json::to_string_pretty(&res)?);
            return Ok(());
        }
        if res.objects.is_empty() {
            println!("(no matches)");
            return Ok(());
        }
        for obj in &res.objects {
            println!(
                "{:>10}  s3://{}/{}",
                format_i64_bytes(obj.size),
                sanitize_for_tty(&obj.bucket),
                sanitize_for_tty(&obj.key)
            );
            if let Some(snippet) = &obj.snippet {
                println!("            {DIM}{}{RESET}", sanitize_for_tty(snippet));
            }
        }
    } else {
        let path = format!("/v1/drive/search?q={q}");
        let val: Value = client.get_json(&path).await?;
        if json_out {
            println!("{}", serde_json::to_string_pretty(&val)?);
            return Ok(());
        }
        let files = val
            .get("files")
            .and_then(|v| v.as_array())
            .or_else(|| val.as_array());
        if let Some(items) = files {
            if items.is_empty() {
                println!("(no matches)");
                return Ok(());
            }
            for item in items {
                let name = item
                    .get("name")
                    .or_else(|| item.get("key"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("(unnamed)");
                let size = item.get("size").and_then(|v| v.as_i64()).unwrap_or(0);
                println!("{:>10}  {}", format_i64_bytes(size), sanitize_for_tty(name));
            }
        } else {
            println!("{}", serde_json::to_string_pretty(&val)?);
        }
    }
    Ok(())
}

async fn cmd_presign(
    client: &AtlasClient,
    target: &str,
    expires: u64,
    method: &str,
    json_out: bool,
) -> Result<()> {
    let remote = RemotePath::parse(target)?;
    let key = remote.require_key()?;
    let method_upper = method.to_ascii_uppercase();
    if !matches!(method_upper.as_str(), "GET" | "PUT") {
        bail!("--method must be GET or PUT");
    }

    let req = PresignRequest {
        key: key.to_string(),
        method: method_upper.clone(),
        expires_in_secs: expires,
    };
    let path = format!("/v1/buckets/{}/presign", uri_encode(&remote.bucket, true));

    let res: PresignResponse = match client.post_json(&path, &req).await {
        Ok(r) => r,
        Err(api_err) => {
            // Offline fallback using local S3 keypair if available
            if let Some((ak, sk)) = client.config().auth.s3_keypair() {
                let now = Utc::now();
                let raw_path = format!(
                    "/s3/{}/{}",
                    uri_encode(&remote.bucket, true),
                    uri_encode(key, false)
                );
                let url = presign_url(
                    client.base_url(),
                    &raw_path,
                    &method_upper,
                    ak,
                    sk,
                    &client.config().region,
                    expires,
                    now,
                )
                .map_err(|e| anyhow!("offline presign failed: {e}"))?;
                PresignResponse {
                    url,
                    method: method_upper,
                    bucket: remote.bucket.clone(),
                    key: key.to_string(),
                    expires_in_secs: expires,
                    expires_at: now + chrono::Duration::seconds(expires as i64),
                }
            } else {
                return Err(api_err);
            }
        }
    };

    if json_out {
        println!("{}", serde_json::to_string_pretty(&res)?);
    } else {
        println!("{}", sanitize_for_tty(&res.url));
    }
    Ok(())
}

async fn list_all_objects(
    client: &AtlasClient,
    bucket: &str,
    prefix: &str,
) -> Result<Vec<ObjectInfo>> {
    let mut all = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let mut q = vec!["limit=1000".to_string()];
        if !prefix.is_empty() {
            q.push(format!("prefix={}", uri_encode(prefix, true)));
        }
        if let Some(c) = &cursor {
            q.push(format!("cursor={}", uri_encode(c, true)));
        }
        let path = format!(
            "/v1/buckets/{}/objects?{}",
            uri_encode(bucket, true),
            q.join("&")
        );
        let page: ListObjectsResponse = client.get_json(&path).await?;
        all.extend(page.objects);
        if page.is_truncated
            && let Some(next) = page.next_cursor
        {
            cursor = Some(next);
            continue;
        }
        break;
    }
    Ok(all)
}

async fn batch_delete_keys(client: &AtlasClient, bucket: &str, keys: &[String]) -> Result<usize> {
    let mut deleted = 0usize;
    let path = format!("/v1/buckets/{}/delete", uri_encode(bucket, true));
    for chunk in keys.chunks(1000) {
        let req = BatchDeleteRequest {
            keys: chunk.to_vec(),
        };
        let resp: BatchDeleteResponse = client.post_json(&path, &req).await?;
        deleted += resp.deleted.len();
    }
    Ok(deleted)
}

fn normalize_prefix_dir(prefix: &str) -> String {
    if prefix.is_empty() {
        String::new()
    } else if prefix.ends_with('/') {
        prefix.to_string()
    } else {
        format!("{prefix}/")
    }
}

fn join_remote_prefix(prefix: &str, rel: &str) -> String {
    let p = prefix.trim_end_matches('/');
    let r = rel.trim_start_matches('/');
    if p.is_empty() {
        r.to_string()
    } else if r.is_empty() {
        p.to_string()
    } else {
        format!("{p}/{r}")
    }
}

fn safe_join_local(root: &Path, rel: &str) -> Result<PathBuf> {
    let mut out = root.to_path_buf();
    for seg in rel.split('/') {
        if seg.is_empty() || seg == "." {
            continue;
        }
        if seg == ".." || seg.contains('\\') || seg.contains('\0') {
            bail!("refusing unsafe relative path '{}'", sanitize_for_tty(rel));
        }
        out.push(seg);
    }
    Ok(out)
}

fn collect_local_files(root: &Path) -> Result<Vec<(String, PathBuf)>> {
    let mut out = Vec::new();
    walk_dir(root, root, &mut out)?;
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}

fn walk_dir(root: &Path, current: &Path, out: &mut Vec<(String, PathBuf)>) -> Result<()> {
    for entry in std::fs::read_dir(current)
        .with_context(|| format!("cannot read directory {}", current.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        let meta = entry.metadata()?;
        if meta.is_dir() {
            walk_dir(root, &path, out)?;
        } else if meta.is_file() {
            let rel = path
                .strip_prefix(root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            out.push((rel, path));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_remote_paths() {
        let p = RemotePath::parse("s3://files/docs/report.pdf").unwrap();
        assert_eq!(p.bucket, "files");
        assert_eq!(p.key, "docs/report.pdf");
        assert!(!p.had_trailing_slash);

        let p2 = RemotePath::parse("media/2026/").unwrap();
        assert_eq!(p2.bucket, "media");
        assert_eq!(p2.key, "2026/");
        assert!(p2.had_trailing_slash);

        let p3 = RemotePath::parse("files").unwrap();
        assert_eq!(p3.bucket, "files");
        assert_eq!(p3.key, "");

        assert!(RemotePath::parse("s3://bad_bucket/key").is_err());
        assert!(RemotePath::parse("files/../escape").is_err());
    }

    #[test]
    fn rejects_traversal_in_safe_join_local() {
        assert!(safe_join_local(Path::new("/tmp/out"), "../etc/passwd").is_err());
        assert_eq!(
            safe_join_local(Path::new("/tmp/out"), "a/b/c.txt").unwrap(),
            PathBuf::from("/tmp/out/a/b/c.txt")
        );
    }
}
