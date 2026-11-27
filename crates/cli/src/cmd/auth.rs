//! `atlas auth` — login, status, whoami, logout.

use std::io::Read;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use serde_json::Value;

use crate::client::AtlasClient;
use crate::cmd::{argv_with_name, run_async};
use crate::credentials::{
    self, CredentialSource, CredentialsFile, DEFAULT_REGION, ResolvedAuth, ResolvedConfig,
};
use crate::sanitize::sanitize_for_tty;
use crate::{DIM, GREEN, RESET};

#[derive(Parser)]
#[command(
    name = "atlas auth",
    about = "Manage Atlas API & S3 credentials (~/.config/atlas/credentials.json)"
)]
struct AuthCli {
    #[command(subcommand)]
    cmd: AuthCmd,
}

#[derive(Subcommand)]
enum AuthCmd {
    /// Verify credentials against GET /v1/server and save them with 0600 permissions
    Login {
        /// Atlas server URL (e.g. https://atlas.example.com or http://127.0.0.1:8787)
        #[arg(long)]
        url: Option<String>,
        /// Combined API key in the form <access_key_id>:<secret_access_key>
        #[arg(long)]
        key: Option<String>,
        /// S3 / API access key ID (pair with --secret-key)
        #[arg(long = "access-key")]
        access_key: Option<String>,
        /// S3 / API secret access key (pair with --access-key)
        #[arg(long = "secret-key")]
        secret_key: Option<String>,
        /// Bearer token (legacy or standalone)
        #[arg(long)]
        token: Option<String>,
        /// Read the API key (ATLK...:atls_...) or bearer token from stdin
        #[arg(long = "key-stdin")]
        key_stdin: bool,
        /// S3 signing region (default: us-east-1)
        #[arg(long)]
        region: Option<String>,
    },
    /// Show configured server URL, auth method, and credential source
    Status {
        /// Print machine-readable JSON
        #[arg(long)]
        json: bool,
    },
    /// Query the server for the authenticated identity (GET /v1/auth/whoami or /v1/server)
    Whoami {
        /// Print machine-readable JSON
        #[arg(long)]
        json: bool,
    },
    /// Delete saved credentials from ~/.config/atlas/credentials.json
    Logout,
}

pub fn run(args: &[String]) {
    let cli = AuthCli::parse_from(argv_with_name("auth", args));
    run_async(exec(cli.cmd));
}

async fn exec(cmd: AuthCmd) -> Result<()> {
    match cmd {
        AuthCmd::Login {
            url,
            key,
            access_key,
            secret_key,
            token,
            key_stdin,
            region,
        } => login(url, key, access_key, secret_key, token, key_stdin, region).await,
        AuthCmd::Status { json } => status(json),
        AuthCmd::Whoami { json } => whoami(json).await,
        AuthCmd::Logout => logout(),
    }
}

async fn login(
    url_arg: Option<String>,
    key: Option<String>,
    access_key: Option<String>,
    secret_key: Option<String>,
    token: Option<String>,
    key_stdin: bool,
    region: Option<String>,
) -> Result<()> {
    let existing = credentials::resolve()?;

    let raw_url = match url_arg {
        Some(u) => u,
        None if !existing.url.is_empty() => existing.url.clone(),
        None => bail!("missing --url (or set ATLAS_URL / ATLAS_SERVER_URL)"),
    };
    let url = credentials::normalize_url(&raw_url)?;

    let stdin_val = if key_stdin {
        let mut buf = String::new();
        std::io::stdin()
            .read_to_string(&mut buf)
            .context("failed to read credential from stdin")?;
        let trimmed = buf.trim().to_string();
        if trimmed.is_empty() {
            bail!("--key-stdin received empty input");
        }
        Some(trimmed)
    } else {
        None
    };

    let (auth, file_creds) = if let Some(k) = key {
        let (ak, sk) = credentials::parse_api_key_pair(&k)?;
        (
            ResolvedAuth::S3Key {
                access_key_id: ak.clone(),
                secret_access_key: sk.clone(),
                source: CredentialSource::CredentialsFile,
            },
            CredentialsFile {
                url: Some(url.clone()),
                access_key_id: Some(ak),
                secret_access_key: Some(sk),
                token: None,
                region: region.clone(),
            },
        )
    } else if access_key.is_some() || secret_key.is_some() {
        let ak = access_key
            .ok_or_else(|| anyhow::anyhow!("--access-key is required with --secret-key"))?;
        let sk = secret_key
            .ok_or_else(|| anyhow::anyhow!("--secret-key is required with --access-key"))?;
        if ak.trim().is_empty() || sk.trim().is_empty() {
            bail!("--access-key and --secret-key must both be non-empty");
        }
        (
            ResolvedAuth::S3Key {
                access_key_id: ak.clone(),
                secret_access_key: sk.clone(),
                source: CredentialSource::CredentialsFile,
            },
            CredentialsFile {
                url: Some(url.clone()),
                access_key_id: Some(ak),
                secret_access_key: Some(sk),
                token: None,
                region: region.clone(),
            },
        )
    } else if let Some(tok) = token {
        let tok = tok.trim().to_string();
        if tok.is_empty() {
            bail!("--token cannot be empty");
        }
        (
            ResolvedAuth::BearerToken {
                token: tok.clone(),
                source: CredentialSource::CredentialsFile,
            },
            CredentialsFile {
                url: Some(url.clone()),
                access_key_id: None,
                secret_access_key: None,
                token: Some(tok),
                region: region.clone(),
            },
        )
    } else if let Some(sv) = stdin_val {
        if sv.contains(':') {
            let (ak, sk) = credentials::parse_api_key_pair(&sv)?;
            (
                ResolvedAuth::S3Key {
                    access_key_id: ak.clone(),
                    secret_access_key: sk.clone(),
                    source: CredentialSource::CredentialsFile,
                },
                CredentialsFile {
                    url: Some(url.clone()),
                    access_key_id: Some(ak),
                    secret_access_key: Some(sk),
                    token: None,
                    region: region.clone(),
                },
            )
        } else {
            (
                ResolvedAuth::BearerToken {
                    token: sv.clone(),
                    source: CredentialSource::CredentialsFile,
                },
                CredentialsFile {
                    url: Some(url.clone()),
                    access_key_id: None,
                    secret_access_key: None,
                    token: Some(sv),
                    region: region.clone(),
                },
            )
        }
    } else {
        bail!(
            "provide credentials via --key <AK:SK>, --access-key/--secret-key, --token, or --key-stdin"
        );
    };

    let test_cfg = ResolvedConfig {
        url: url.clone(),
        url_source: CredentialSource::CredentialsFile,
        auth,
        region: region.unwrap_or_else(|| DEFAULT_REGION.to_string()),
    };
    let client = AtlasClient::from_config(test_cfg)?;
    let server_info: Value = client
        .get_json("/v1/server")
        .await
        .context("credential verification failed against GET /v1/server")?;

    let saved_path = credentials::save_file(&file_creds)?;

    let name = server_info
        .get("name")
        .and_then(|v| v.as_str())
        .map(sanitize_for_tty)
        .unwrap_or_else(|| "atlas".into());
    let version = server_info
        .get("version")
        .and_then(|v| v.as_str())
        .map(sanitize_for_tty)
        .unwrap_or_else(|| "unknown".into());

    println!(
        "{GREEN}logged in{RESET} to {} ({name} v{version})",
        sanitize_for_tty(&url)
    );
    println!(
        "{DIM}credentials saved (0600): {}{RESET}",
        saved_path.display()
    );
    Ok(())
}

fn status(json_out: bool) -> Result<()> {
    let cfg = credentials::resolve()?;
    let path = credentials::credentials_path()?;
    let file_exists = path.exists();

    let access_key_id = cfg.auth.s3_keypair().map(|(ak, _)| ak.to_string());

    if json_out {
        let obj = serde_json::json!({
            "url": if cfg.url.is_empty() { Value::Null } else { Value::String(cfg.url) },
            "url_source": cfg.url_source.label(),
            "auth_kind": cfg.auth.kind_label(),
            "auth_source": cfg.auth.source().label(),
            "access_key_id": access_key_id,
            "region": cfg.region,
            "credentials_file": path.display().to_string(),
            "credentials_file_exists": file_exists,
        });
        println!("{}", serde_json::to_string_pretty(&obj)?);
        return Ok(());
    }

    println!(
        "URL:          {} ({})",
        if cfg.url.is_empty() {
            "(not configured)".to_string()
        } else {
            sanitize_for_tty(&cfg.url)
        },
        cfg.url_source.label()
    );
    println!(
        "Auth:         {} ({})",
        cfg.auth.kind_label(),
        cfg.auth.source().label()
    );
    if let Some(ak) = access_key_id {
        println!("Access Key:   {}", sanitize_for_tty(&ak));
    }
    println!("Region:       {}", sanitize_for_tty(&cfg.region));
    println!(
        "Config file:  {} ({})",
        path.display(),
        if file_exists { "present" } else { "not found" }
    );
    Ok(())
}

async fn whoami(json_out: bool) -> Result<()> {
    let client = AtlasClient::from_env()?;
    let (endpoint, val): (&str, Value) =
        match client.get_json_opt::<Value>("/v1/auth/whoami").await? {
            Some(v) => ("/v1/auth/whoami", v),
            None => ("/v1/server", client.get_json("/v1/server").await?),
        };

    if json_out {
        println!("{}", serde_json::to_string_pretty(&val)?);
        return Ok(());
    }

    println!("Server:   {}", sanitize_for_tty(client.base_url()));
    println!("Endpoint: {endpoint}");
    if let Some(obj) = val.as_object() {
        for (k, v) in obj {
            let rendered = match v {
                Value::String(s) => sanitize_for_tty(s),
                Value::Array(arr) => arr
                    .iter()
                    .map(|x| sanitize_for_tty(x.to_string().trim_matches('"')))
                    .collect::<Vec<_>>()
                    .join(", "),
                other => sanitize_for_tty(&other.to_string()),
            };
            println!("{:<12} {rendered}", format!("{}:", sanitize_for_tty(k)));
        }
    } else {
        println!("{}", sanitize_for_tty(&val.to_string()));
    }
    Ok(())
}

fn logout() -> Result<()> {
    let path = credentials::credentials_path()?;
    if credentials::remove_file()? {
        println!("{GREEN}logged out{RESET} (removed {})", path.display());
    } else {
        println!("no saved credentials at {}", path.display());
    }
    Ok(())
}
