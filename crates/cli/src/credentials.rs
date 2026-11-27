//! Standalone API & S3 credential storage and resolution.
//!
//! Credentials live in `~/.config/atlas/credentials.json` with strict Unix
//! permissions (`0700` parent directory, `0600` file). Environment variables
//! always take precedence over the saved file:
//!
//! - URL: `ATLAS_URL` -> `http://<ATLAS_SERVER_URL>` -> `credentials.json` -> `~/.config/atlas/env`
//! - Auth: `ATLAS_API_KEY` (`ATLK...:atls_...`)
//!   -> `ATLAS_ACCESS_KEY_ID` + `ATLAS_SECRET_ACCESS_KEY`
//!   -> `ATLAS_TOKEN`
//!   -> `credentials.json`

use std::env;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use url::Url;

pub const DEFAULT_REGION: &str = "us-east-1";

/// Persisted on-disk format for `~/.config/atlas/credentials.json`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct CredentialsFile {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub access_key_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secret_access_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub region: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CredentialSource {
    Env(&'static str),
    CredentialsFile,
    AtlasEnvFile,
    None,
}

impl CredentialSource {
    pub fn label(&self) -> &'static str {
        match self {
            Self::Env(name) => name,
            Self::CredentialsFile => "credentials.json",
            Self::AtlasEnvFile => "~/.config/atlas/env",
            Self::None => "not set",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolvedAuth {
    S3Key {
        access_key_id: String,
        secret_access_key: String,
        source: CredentialSource,
    },
    BearerToken {
        token: String,
        source: CredentialSource,
    },
    None,
}

impl ResolvedAuth {
    pub fn bearer_token(&self) -> Option<String> {
        match self {
            Self::S3Key {
                access_key_id,
                secret_access_key,
                ..
            } => Some(format!("{access_key_id}:{secret_access_key}")),
            Self::BearerToken { token, .. } => Some(token.clone()),
            Self::None => None,
        }
    }

    pub fn s3_keypair(&self) -> Option<(&str, &str)> {
        match self {
            Self::S3Key {
                access_key_id,
                secret_access_key,
                ..
            } => Some((access_key_id.as_str(), secret_access_key.as_str())),
            _ => None,
        }
    }

    pub fn source(&self) -> CredentialSource {
        match self {
            Self::S3Key { source, .. } | Self::BearerToken { source, .. } => *source,
            Self::None => CredentialSource::None,
        }
    }

    pub fn kind_label(&self) -> &'static str {
        match self {
            Self::S3Key { .. } => "API / S3 keypair (SigV4 + Bearer)",
            Self::BearerToken { .. } => "Bearer token",
            Self::None => "none",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ResolvedConfig {
    pub url: String,
    pub url_source: CredentialSource,
    pub auth: ResolvedAuth,
    pub region: String,
}

/// Returns the credentials file path.
/// Honors `ATLAS_CREDENTIALS_FILE` if set (useful for testing and custom profiles),
/// otherwise `$HOME/.config/atlas/credentials.json`.
pub fn credentials_path() -> Result<PathBuf> {
    if let Ok(explicit) = env::var("ATLAS_CREDENTIALS_FILE")
        && !explicit.trim().is_empty()
    {
        return Ok(PathBuf::from(explicit));
    }
    let home = env::var("HOME").context("HOME environment variable is not set")?;
    Ok(Path::new(&home)
        .join(".config")
        .join("atlas")
        .join("credentials.json"))
}

/// Normalizes a server URL: prepends `http://` if no scheme is given, validates
/// with `url::Url`, and strips any trailing `/`.
pub fn normalize_url(raw: &str) -> Result<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        bail!("server URL cannot be empty");
    }
    let with_scheme = if trimmed.contains("://") {
        trimmed.to_string()
    } else {
        format!("http://{trimmed}")
    };
    let parsed =
        Url::parse(&with_scheme).with_context(|| format!("invalid Atlas server URL: {trimmed}"))?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        bail!("invalid Atlas server URL (must be http:// or https:// with host): {trimmed}");
    }
    Ok(with_scheme.trim_end_matches('/').to_string())
}

/// Splits an `ATLK...:atls_...` combined API key into `(access_key_id, secret_access_key)`.
pub fn parse_api_key_pair(raw: &str) -> Result<(String, String)> {
    let trimmed = raw.trim();
    let Some((ak, sk)) = trimmed.split_once(':') else {
        bail!("invalid API key format (expected '<access_key_id>:<secret_access_key>')");
    };
    let ak = ak.trim();
    let sk = sk.trim();
    if ak.is_empty() || sk.is_empty() {
        bail!("invalid API key format: access key and secret key must both be non-empty");
    }
    Ok((ak.to_string(), sk.to_string()))
}

/// Loads `credentials.json` if it exists.
pub fn load_file() -> Result<Option<CredentialsFile>> {
    let path = credentials_path()?;
    load_file_from(&path)
}

pub fn load_file_from(path: &Path) -> Result<Option<CredentialsFile>> {
    match fs::read_to_string(path) {
        Ok(raw) => {
            let parsed: CredentialsFile = serde_json::from_str(&raw)
                .with_context(|| format!("invalid JSON in {}", path.display()))?;
            Ok(Some(parsed))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e).with_context(|| format!("failed to read {}", path.display())),
    }
}

/// Saves `credentials.json` atomically with strict `0700` directory and `0600` file permissions.
pub fn save_file(creds: &CredentialsFile) -> Result<PathBuf> {
    let path = credentials_path()?;
    save_file_to(&path, creds)?;
    Ok(path)
}

pub fn save_file_to(path: &Path, creds: &CredentialsFile) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("credentials path has no parent directory"))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        if !parent.exists() {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
            .with_context(|| format!("failed to set 0700 on {}", parent.display()))?;
    }
    #[cfg(not(unix))]
    {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    let serialized = serde_json::to_string_pretty(creds)? + "\n";

    // Write to a fresh sibling temp file created with mode 0600 + O_EXCL, then rename atomically.
    let tmp_name = format!(
        ".credentials.{}.{}.tmp",
        std::process::id(),
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    );
    let tmp_path = parent.join(tmp_name);

    let mut opts = OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }

    let mut file = opts
        .open(&tmp_path)
        .with_context(|| format!("failed to create {}", tmp_path.display()))?;

    let write_res = (|| -> Result<()> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(0o600))?;
        }
        file.write_all(serialized.as_bytes())?;
        file.sync_all()?;
        Ok(())
    })();

    if let Err(e) = write_res {
        drop(file);
        let _ = fs::remove_file(&tmp_path);
        return Err(e);
    }
    drop(file);

    fs::rename(&tmp_path, path)
        .with_context(|| format!("failed to move credentials into {}", path.display()))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to enforce 0600 on {}", path.display()))?;
    }

    Ok(())
}

/// Removes `credentials.json` if present, returning `true` if a file was deleted.
pub fn remove_file() -> Result<bool> {
    let path = credentials_path()?;
    match fs::remove_file(&path) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e).with_context(|| format!("failed to remove {}", path.display())),
    }
}

fn non_empty_env(name: &str) -> Option<String> {
    env::var(name)
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

/// Resolves the effective server URL and credentials from env vars and `credentials.json`.
pub fn resolve() -> Result<ResolvedConfig> {
    let file = load_file()?.unwrap_or_default();

    // 1. Resolve base URL
    let (url, url_source) = if let Some(u) = non_empty_env("ATLAS_URL") {
        (normalize_url(&u)?, CredentialSource::Env("ATLAS_URL"))
    } else if let Some(s) = non_empty_env("ATLAS_SERVER_URL") {
        (
            normalize_url(&s)?,
            CredentialSource::Env("ATLAS_SERVER_URL"),
        )
    } else if let Some(u) = file.url.as_deref().filter(|s| !s.trim().is_empty()) {
        (normalize_url(u)?, CredentialSource::CredentialsFile)
    } else {
        // Fallback to ~/.config/atlas/env ATLAS_SERVER_URL if configured (and not placeholder)
        let server_url = &crate::config::config().server_url;
        if !server_url.is_empty() && !server_url.contains("your-tailnet.ts.net") {
            (normalize_url(server_url)?, CredentialSource::AtlasEnvFile)
        } else {
            (String::new(), CredentialSource::None)
        }
    };

    // 2. Resolve auth
    let auth = if let Some(api_key) = non_empty_env("ATLAS_API_KEY") {
        let (access_key_id, secret_access_key) = parse_api_key_pair(&api_key)?;
        ResolvedAuth::S3Key {
            access_key_id,
            secret_access_key,
            source: CredentialSource::Env("ATLAS_API_KEY"),
        }
    } else if let (Some(ak), Some(sk)) = (
        non_empty_env("ATLAS_ACCESS_KEY_ID"),
        non_empty_env("ATLAS_SECRET_ACCESS_KEY"),
    ) {
        ResolvedAuth::S3Key {
            access_key_id: ak,
            secret_access_key: sk,
            source: CredentialSource::Env("ATLAS_ACCESS_KEY_ID/ATLAS_SECRET_ACCESS_KEY"),
        }
    } else if let Some(token) = non_empty_env("ATLAS_TOKEN") {
        if token.contains(':') {
            if let Ok((access_key_id, secret_access_key)) = parse_api_key_pair(&token) {
                ResolvedAuth::S3Key {
                    access_key_id,
                    secret_access_key,
                    source: CredentialSource::Env("ATLAS_TOKEN"),
                }
            } else {
                ResolvedAuth::BearerToken {
                    token,
                    source: CredentialSource::Env("ATLAS_TOKEN"),
                }
            }
        } else {
            ResolvedAuth::BearerToken {
                token,
                source: CredentialSource::Env("ATLAS_TOKEN"),
            }
        }
    } else if let (Some(ak), Some(sk)) = (
        file.access_key_id.filter(|s| !s.is_empty()),
        file.secret_access_key.filter(|s| !s.is_empty()),
    ) {
        ResolvedAuth::S3Key {
            access_key_id: ak,
            secret_access_key: sk,
            source: CredentialSource::CredentialsFile,
        }
    } else if let Some(token) = file.token.filter(|s| !s.is_empty()) {
        ResolvedAuth::BearerToken {
            token,
            source: CredentialSource::CredentialsFile,
        }
    } else {
        ResolvedAuth::None
    };

    let region = non_empty_env("ATLAS_REGION")
        .or(file.region)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| DEFAULT_REGION.to_string());

    Ok(ResolvedConfig {
        url,
        url_source,
        auth,
        region,
    })
}

/// Resolves config and requires a configured server URL.
pub fn resolve_required() -> Result<ResolvedConfig> {
    let cfg = resolve()?;
    if cfg.url.is_empty() {
        bail!(
            "no Atlas server URL configured. Run `atlas auth login --url <URL>` or set ATLAS_URL."
        );
    }
    Ok(cfg)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_urls() {
        assert_eq!(
            normalize_url("https://atlas.example.com/").unwrap(),
            "https://atlas.example.com"
        );
        assert_eq!(
            normalize_url("127.0.0.1:8787").unwrap(),
            "http://127.0.0.1:8787"
        );
        assert!(normalize_url("").is_err());
        assert!(normalize_url("ftp://example.com").is_err());
    }

    #[test]
    fn parses_api_key_pairs() {
        let (ak, sk) = parse_api_key_pair("ATLK1234:atls_secret_val").unwrap();
        assert_eq!(ak, "ATLK1234");
        assert_eq!(sk, "atls_secret_val");
        assert!(parse_api_key_pair("no-colon").is_err());
        assert!(parse_api_key_pair(":onlysecret").is_err());
        assert!(parse_api_key_pair("onlyak:").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn saves_credentials_with_0700_dir_and_0600_file() {
        use std::os::unix::fs::PermissionsExt;

        let base = env::temp_dir().join(format!(
            "atlas-cli-cred-test-{}-{}",
            std::process::id(),
            chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
        ));
        let dir = base.join("atlas");
        let file = dir.join("credentials.json");

        let creds = CredentialsFile {
            url: Some("http://127.0.0.1:8787".into()),
            access_key_id: Some("ATLKTEST1234567890123456".into()),
            secret_access_key: Some("atls_super_secret".into()),
            token: None,
            region: Some("us-east-1".into()),
        };

        save_file_to(&file, &creds).unwrap();

        let dir_mode = fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
        let file_mode = fs::metadata(&file).unwrap().permissions().mode() & 0o777;
        assert_eq!(dir_mode, 0o700);
        assert_eq!(file_mode, 0o600);

        let loaded = load_file_from(&file).unwrap().unwrap();
        assert_eq!(loaded, creds);

        let _ = fs::remove_dir_all(&base);
    }
}
