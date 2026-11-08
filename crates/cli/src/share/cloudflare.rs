//! Cloudflare's API, with wrangler's login.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use super::fail;
use super::setup::{SUBDOMAIN, wrangler};

pub(super) struct Cf {
    token: String,
}

pub(super) struct Zone {
    pub(super) name: String,
}

impl Cf {
    pub(super) fn new(dir: &Path) -> Self {
        let out = wrangler(dir, &["auth", "token", "--json"]).output().ok();
        let token = out
            .and_then(|o| serde_json::from_slice::<serde_json::Value>(&o.stdout).ok())
            .and_then(|v| v["token"].as_str().map(str::to_string))
            .unwrap_or_else(|| fail("could not read wrangler's Cloudflare login (npx wrangler login)"));
        Self { token }
    }

    /// One API call; the `result` of a successful answer.
    pub(super) fn call(&self, method: &str, path: &str) -> Option<serde_json::Value> {
        let out = curl_with_token(method, &format!("https://api.cloudflare.com/client/v4{path}"), &self.token);
        let v: serde_json::Value = serde_json::from_str(&out).ok()?;
        v["success"].as_bool().filter(|ok| *ok).map(|_| v["result"].clone())
    }

    fn list(&self, path: &str) -> Vec<serde_json::Value> {
        self.call("GET", path).and_then(|r| r.as_array().cloned()).unwrap_or_default()
    }

    /// The account's active domains.
    pub(super) fn zones(&self) -> Vec<Zone> {
        self.list("/zones?status=active&per_page=50")
            .iter()
            .filter_map(|z| Some(Zone { name: z["name"].as_str()?.to_string() }))
            .collect()
    }

    /// Custom domains of the atlas-share Worker: (account, id, hostname).
    pub(super) fn worker_domains(&self) -> Vec<(String, String, String)> {
        let mut out = Vec::new();
        for account in self.list("/accounts?per_page=50") {
            let Some(account) = account["id"].as_str() else { continue };
            for d in self.list(&format!("/accounts/{account}/workers/domains?service={SUBDOMAIN}")) {
                if let (Some(id), Some(host)) = (d["id"].as_str(), d["hostname"].as_str()) {
                    out.push((account.to_string(), id.to_string(), host.to_string()));
                }
            }
        }
        out
    }
}

/// curl with `Authorization: Bearer <token>` read from stdin, so the token
/// never shows up in the process list.
pub(super) fn curl_with_token(method: &str, url: &str, token: &str) -> String {
    let Ok(mut child) = Command::new("curl")
        .args(["-sS", "--max-time", "60", "-X", method, "-H", "@-", url])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    else {
        return String::new();
    };
    let _ = writeln!(child.stdin.take().expect("stdin"), "Authorization: Bearer {token}");
    child.wait_with_output().map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default()
}
