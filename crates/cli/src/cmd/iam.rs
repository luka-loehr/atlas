//! `atlas keys` and `atlas accounts` — IAM management.

use anyhow::{Result, bail};
use atlas_common::models::{
    AccountInfo, AccountRole, ApiKeyInfo, CreateAccountRequest, CreateKeyRequest,
    CreateKeyResponse, VALID_SCOPES,
};
use atlas_common::validate::uri_encode;
use clap::{Parser, Subcommand};
use serde_json::Value;

use crate::client::AtlasClient;
use crate::cmd::{argv_with_name, run_async};
use crate::sanitize::{format_i64_bytes, sanitize_for_tty};
use crate::{DIM, GREEN, RESET};

// ── atlas keys ───────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "atlas keys", about = "Manage Atlas API & S3 keys")]
struct KeysCli {
    #[command(subcommand)]
    cmd: KeysCmd,
}

#[derive(Subcommand)]
enum KeysCmd {
    /// List API / S3 keys
    Ls {
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// Create a new API / S3 key (prints secret ONCE)
    Create {
        /// Human-readable key name
        name: String,
        /// Optional account ID to bind this key to
        #[arg(long)]
        account: Option<String>,
        /// Comma-separated scopes (read,write,delete,media:search,admin)
        #[arg(long, value_delimiter = ',')]
        scopes: Option<Vec<String>>,
        /// Comma-separated bucket names (omit for all buckets)
        #[arg(long, value_delimiter = ',')]
        buckets: Option<Vec<String>>,
        /// Per-key rate limit (requests per second)
        #[arg(long)]
        rps: Option<i32>,
        /// Per-key rate limit burst
        #[arg(long)]
        burst: Option<i32>,
        /// Key lifetime in days
        #[arg(long = "expires-days")]
        expires_days: Option<i64>,
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// Revoke an API key without deleting its audit record
    Revoke {
        /// Key ID
        id: String,
    },
    /// Permanently remove an API key
    Rm {
        /// Key ID
        id: String,
    },
}

pub fn run_keys(args: &[String]) {
    let cli = KeysCli::parse_from(argv_with_name("keys", args));
    run_async(exec_keys(cli.cmd));
}

async fn exec_keys(cmd: KeysCmd) -> Result<()> {
    let client = AtlasClient::from_env()?;
    match cmd {
        KeysCmd::Ls { json } => {
            let val: Value = client.get_json("/v1/keys").await?;
            let keys: Vec<ApiKeyInfo> = if val.is_array() {
                serde_json::from_value(val)?
            } else if let Some(arr) = val.get("keys") {
                serde_json::from_value(arr.clone())?
            } else {
                bail!("unexpected response shape from GET /v1/keys");
            };
            if json {
                println!("{}", serde_json::to_string_pretty(&keys)?);
                return Ok(());
            }
            if keys.is_empty() {
                println!("(no keys)");
                return Ok(());
            }
            println!(
                "{:<18} {:<26} {:<18} {:<24} STATUS",
                "ID", "ACCESS KEY", "NAME", "SCOPES"
            );
            for k in keys {
                let status = if k.revoked_at.is_some() {
                    "revoked"
                } else if k.expires_at.is_some_and(|exp| exp < chrono::Utc::now()) {
                    "expired"
                } else {
                    "active"
                };
                println!(
                    "{:<18} {:<26} {:<18} {:<24} {}",
                    sanitize_for_tty(&k.id),
                    sanitize_for_tty(&k.access_key_id),
                    sanitize_for_tty(&k.name),
                    sanitize_for_tty(&k.scopes.join(",")),
                    status
                );
            }
            Ok(())
        }
        KeysCmd::Create {
            name,
            account,
            scopes,
            buckets,
            rps,
            burst,
            expires_days,
            json,
        } => {
            let scopes = match scopes {
                Some(list) if !list.is_empty() => {
                    for s in &list {
                        if !VALID_SCOPES.contains(&s.as_str()) {
                            bail!(
                                "invalid scope '{}' (valid: {})",
                                sanitize_for_tty(s),
                                VALID_SCOPES.join(", ")
                            );
                        }
                    }
                    list
                }
                _ => vec![
                    "read".into(),
                    "write".into(),
                    "delete".into(),
                    "media:search".into(),
                ],
            };
            let expires_in_secs = match expires_days {
                Some(d) if d <= 0 => bail!("--expires-days must be positive"),
                Some(d) => Some(d.saturating_mul(86_400)),
                None => None,
            };
            let req = CreateKeyRequest {
                name,
                account_id: account,
                scopes,
                buckets: buckets.unwrap_or_default(),
                rate_limit_rps: rps,
                rate_limit_burst: burst,
                expires_in_secs,
            };
            let resp: CreateKeyResponse = client.post_json("/v1/keys", &req).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&resp)?);
            } else {
                println!(
                    "{GREEN}created{RESET} key {} ({})",
                    sanitize_for_tty(&resp.key.name),
                    sanitize_for_tty(&resp.key.id)
                );
                println!(
                    "Access Key ID:     {}",
                    sanitize_for_tty(&resp.key.access_key_id)
                );
                println!(
                    "Secret Access Key: {}",
                    sanitize_for_tty(&resp.secret_access_key)
                );
                println!(
                    "Bearer Token:      {}",
                    sanitize_for_tty(&resp.bearer_token)
                );
                println!("{DIM}Save the secret now — it will not be shown again.{RESET}");
            }
            Ok(())
        }
        KeysCmd::Revoke { id } => {
            client
                .post_empty(&format!("/v1/keys/{}/revoke", uri_encode(&id, true)))
                .await?;
            println!("{GREEN}revoked{RESET} key {}", sanitize_for_tty(&id));
            Ok(())
        }
        KeysCmd::Rm { id } => {
            client
                .delete_empty(&format!("/v1/keys/{}", uri_encode(&id, true)))
                .await?;
            println!("{GREEN}deleted{RESET} key {}", sanitize_for_tty(&id));
            Ok(())
        }
    }
}

// ── atlas accounts ───────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "atlas accounts", about = "Manage Atlas IAM accounts")]
struct AccountsCli {
    #[command(subcommand)]
    cmd: AccountsCmd,
}

#[derive(Subcommand)]
enum AccountsCmd {
    /// List accounts
    Ls {
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// Create a new account
    Create {
        /// Account slug/name
        name: String,
        /// Optional display name
        #[arg(long = "display-name")]
        display_name: Option<String>,
        /// Role: service, member, or admin
        #[arg(long, default_value = "service")]
        role: String,
        /// Per-account rate limit (requests per second)
        #[arg(long)]
        rps: Option<i32>,
        /// Per-account rate limit burst
        #[arg(long)]
        burst: Option<i32>,
        /// Optional storage quota in GiB
        #[arg(long = "quota-gb")]
        quota_gb: Option<u64>,
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// Inspect an account
    Info {
        /// Account ID
        id: String,
        /// Print raw JSON
        #[arg(long)]
        json: bool,
    },
    /// Delete an account
    Rm {
        /// Account ID
        id: String,
    },
}

pub fn run_accounts(args: &[String]) {
    let cli = AccountsCli::parse_from(argv_with_name("accounts", args));
    run_async(exec_accounts(cli.cmd));
}

async fn exec_accounts(cmd: AccountsCmd) -> Result<()> {
    let client = AtlasClient::from_env()?;
    match cmd {
        AccountsCmd::Ls { json } => {
            let val: Value = client.get_json("/v1/accounts").await?;
            let accounts: Vec<AccountInfo> = if val.is_array() {
                serde_json::from_value(val)?
            } else if let Some(arr) = val.get("accounts") {
                serde_json::from_value(arr.clone())?
            } else {
                bail!("unexpected response shape from GET /v1/accounts");
            };
            if json {
                println!("{}", serde_json::to_string_pretty(&accounts)?);
                return Ok(());
            }
            if accounts.is_empty() {
                println!("(no accounts)");
                return Ok(());
            }
            println!(
                "{:<18} {:<20} {:<10} {:<10} QUOTA",
                "ID", "NAME", "ROLE", "STATUS"
            );
            for a in accounts {
                let quota = a
                    .quota_bytes
                    .map(format_i64_bytes)
                    .unwrap_or_else(|| "unlimited".into());
                println!(
                    "{:<18} {:<20} {:<10} {:<10} {}",
                    sanitize_for_tty(&a.id),
                    sanitize_for_tty(&a.name),
                    a.role.as_str(),
                    a.status.as_str(),
                    quota
                );
            }
            Ok(())
        }
        AccountsCmd::Create {
            name,
            display_name,
            role,
            rps,
            burst,
            quota_gb,
            json,
        } => {
            let Some(role) = AccountRole::parse(&role) else {
                bail!(
                    "invalid role '{}' (expected service, member, or admin)",
                    sanitize_for_tty(&role)
                );
            };
            let quota_bytes = quota_gb.map(|gb| (gb as i64).saturating_mul(1024 * 1024 * 1024));
            let req = CreateAccountRequest {
                name,
                display_name,
                role,
                rate_limit_rps: rps,
                rate_limit_burst: burst,
                quota_bytes,
            };
            let info: AccountInfo = client.post_json("/v1/accounts", &req).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&info)?);
            } else {
                println!(
                    "{GREEN}created{RESET} account {} ({}, role={})",
                    sanitize_for_tty(&info.name),
                    sanitize_for_tty(&info.id),
                    info.role.as_str()
                );
            }
            Ok(())
        }
        AccountsCmd::Info { id, json } => {
            let info: AccountInfo = client
                .get_json(&format!("/v1/accounts/{}", uri_encode(&id, true)))
                .await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&info)?);
            } else {
                println!("ID:       {}", sanitize_for_tty(&info.id));
                println!("Name:     {}", sanitize_for_tty(&info.name));
                if let Some(dn) = &info.display_name {
                    println!("Display:  {}", sanitize_for_tty(dn));
                }
                println!("Role:     {}", info.role.as_str());
                println!("Status:   {}", info.status.as_str());
                if let Some(q) = info.quota_bytes {
                    println!("Quota:    {}", format_i64_bytes(q));
                }
                if let Some(rps) = info.rate_limit_rps {
                    println!(
                        "Rate:     {} rps (burst {})",
                        rps,
                        info.rate_limit_burst.unwrap_or(rps)
                    );
                }
                println!("Created:  {}", info.created_at.to_rfc3339());
            }
            Ok(())
        }
        AccountsCmd::Rm { id } => {
            client
                .delete_empty(&format!("/v1/accounts/{}", uri_encode(&id, true)))
                .await?;
            println!("{GREEN}deleted{RESET} account {}", sanitize_for_tty(&id));
            Ok(())
        }
    }
}
