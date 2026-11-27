//! `atlas buckets` — list, create, inspect, and remove Atlas storage buckets.

use anyhow::{Result, bail};
use atlas_common::models::{BucketInfo, BucketKind, CreateBucketRequest};
use atlas_common::validate::{is_valid_bucket_name, uri_encode};
use clap::{Parser, Subcommand};
use serde_json::Value;

use crate::client::AtlasClient;
use crate::cmd::{argv_with_name, run_async};
use crate::sanitize::{format_i64_bytes, sanitize_for_tty};
use crate::{GREEN, RESET};

#[derive(Parser)]
#[command(name = "atlas buckets", about = "Manage Atlas storage buckets")]
struct BucketsCli {
    #[command(subcommand)]
    cmd: BucketsCmd,
}

#[derive(Subcommand)]
enum BucketsCmd {
    /// List all accessible buckets
    Ls {
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// Create a new bucket
    Create {
        /// Bucket name (3-63 lowercase letters, digits, hyphens)
        name: String,
        /// Bucket kind: general, files, or media
        #[arg(long, default_value = "general")]
        kind: String,
        /// Optional quota in GiB
        #[arg(long = "quota-gb")]
        quota_gb: Option<u64>,
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// Show detailed information about a bucket
    Info {
        /// Bucket name
        name: String,
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// Delete an empty bucket
    Rm {
        /// Bucket name
        name: String,
    },
}

pub fn run(args: &[String]) {
    let cli = BucketsCli::parse_from(argv_with_name("buckets", args));
    run_async(exec(cli.cmd));
}

async fn exec(cmd: BucketsCmd) -> Result<()> {
    let client = AtlasClient::from_env()?;
    match cmd {
        BucketsCmd::Ls { json } => list_buckets(&client, json).await,
        BucketsCmd::Create {
            name,
            kind,
            quota_gb,
            json,
        } => {
            if !is_valid_bucket_name(&name) {
                bail!(
                    "invalid bucket name '{}': must be 3-63 lowercase letters, digits, hyphens, or dots",
                    sanitize_for_tty(&name)
                );
            }
            let Some(kind) = BucketKind::parse(&kind) else {
                bail!(
                    "invalid bucket kind '{}' (expected general, files, or media)",
                    sanitize_for_tty(&kind)
                );
            };
            let quota_bytes = quota_gb.map(|gb| (gb as i64).saturating_mul(1024 * 1024 * 1024));
            let req = CreateBucketRequest {
                name,
                kind,
                quota_bytes,
            };
            let info: BucketInfo = client.post_json("/v1/buckets", &req).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&info)?);
            } else {
                println!(
                    "{GREEN}created{RESET} bucket {} ({})",
                    sanitize_for_tty(&info.name),
                    info.kind.as_str()
                );
            }
            Ok(())
        }
        BucketsCmd::Info { name, json } => {
            let encoded = uri_encode(&name, true);
            let info: BucketInfo = client.get_json(&format!("/v1/buckets/{encoded}")).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&info)?);
            } else {
                println!("Name:     {}", sanitize_for_tty(&info.name));
                println!("Kind:     {}", info.kind.as_str());
                println!("Owner:    {}", sanitize_for_tty(&info.owner_account_id));
                println!("Objects:  {}", info.object_count);
                println!("Size:     {}", format_i64_bytes(info.total_bytes));
                if let Some(q) = info.quota_bytes {
                    println!("Quota:    {}", format_i64_bytes(q));
                }
                println!("Public:   {}", info.public_read);
                println!("Created:  {}", info.created_at.to_rfc3339());
            }
            Ok(())
        }
        BucketsCmd::Rm { name } => {
            let encoded = uri_encode(&name, true);
            client
                .delete_empty(&format!("/v1/buckets/{encoded}"))
                .await?;
            println!("{GREEN}deleted{RESET} bucket {}", sanitize_for_tty(&name));
            Ok(())
        }
    }
}

/// Fetches buckets from `GET /v1/buckets`, tolerating either a bare JSON array
/// or `{"buckets": [...]}` wrapper.
pub async fn fetch_buckets(client: &AtlasClient) -> Result<Vec<BucketInfo>> {
    let val: Value = client.get_json("/v1/buckets").await?;
    if val.is_array() {
        Ok(serde_json::from_value(val)?)
    } else if let Some(arr) = val.get("buckets") {
        Ok(serde_json::from_value(arr.clone())?)
    } else {
        bail!("unexpected response shape from GET /v1/buckets");
    }
}

pub async fn list_buckets(client: &AtlasClient, json_out: bool) -> Result<()> {
    let buckets = fetch_buckets(client).await?;
    if json_out {
        println!("{}", serde_json::to_string_pretty(&buckets)?);
        return Ok(());
    }
    if buckets.is_empty() {
        println!("(no buckets)");
        return Ok(());
    }
    println!(
        "{:<24} {:<10} {:>10} {:>12}",
        "NAME", "KIND", "OBJECTS", "SIZE"
    );
    for b in buckets {
        println!(
            "{:<24} {:<10} {:>10} {:>12}",
            sanitize_for_tty(&b.name),
            b.kind.as_str(),
            b.object_count,
            format_i64_bytes(b.total_bytes)
        );
    }
    Ok(())
}
