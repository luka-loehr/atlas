//! `atlas share`: link sharing through atlas-share, a Cloudflare Worker on
//! your own account (share/ in the repo).
//!
//!   atlas share setup     deploy atlas-share and connect the server; asks which
//!                         of your domains links live on (atlas-share.<domain>)
//!   atlas share status    is it set up, does the Worker answer
//!   atlas share ls        live links
//!   atlas share rm <id>   stop sharing a link
//!   atlas share destroy   remove everything setup made from Cloudflare
//!
//! Setup runs on the Mac, from an atlas checkout, with Node.js: wrangler logs
//! in to Cloudflare in the browser, then the bucket, its 8-day lifecycle rule,
//! the Worker (on a custom domain or workers.dev) and its two secrets are made
//! (safe to re-run), and the Worker's address and admin token go into
//! /etc/atlas/atlas.env on the server. Non-interactive: `--domain example.com`,
//! `--workers-dev`, or `--url https://…` for an address you route yourself.

use std::io::{BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio, exit};

use crate::config::ssh_host;
use crate::ssh::{ensure_up, run_inherit, shq, ssh_capture};
use crate::{DIM, GREEN, RED, RESET};

const BUCKET: &str = "atlas-share";
const ENV_FILE: &str = "/etc/atlas/atlas.env";

pub(crate) fn share(sub: &[String]) {
    match sub.first().map(String::as_str) {
        Some("setup") => setup(&sub[1..]),
        Some("status") | None => status(),
        Some("ls") | Some("list") => list(),
        Some("rm") | Some("stop") => match sub.get(1) {
            Some(id) => stop(id),
            None => fail("usage: atlas share rm <id>"),
        },
        Some("destroy") => destroy(&sub[1..]),
        Some(other) => fail(&format!("unknown: atlas share {other}  (setup | status | ls | rm <id> | destroy)")),
    }
}

fn fail(message: &str) -> ! {
    eprintln!("{RED}{message}{RESET}");
    exit(1);
}

// MARK: - setup

/// Where links live.
#[derive(Clone, PartialEq)]
enum Place {
    /// atlas-share.<zone>, a Workers custom domain
    Domain(String),
    WorkersDev,
    /// an address the owner routes to the Worker themselves
    Url(String),
}

fn setup(args: &[String]) {
    let asked = match args {
        [flag, zone] if flag == "--domain" => Some(Place::Domain(zone.trim().trim_end_matches('.').to_lowercase())),
        [flag] if flag == "--workers-dev" => Some(Place::WorkersDev),
        [flag, url] if flag == "--url" => Some(Place::Url(url.trim_end_matches('/').to_string())),
        [] => None,
        _ => fail("usage: atlas share setup [--domain example.com | --workers-dev | --url https://…]"),
    };
    let dir = prepare();
    let wrangler = |args: &[&str]| wrangler(&dir, args);

    let cf = Cf::new(&dir);
    let current = server_env("ATLAS_SHARE_URL");
    let place = asked.unwrap_or_else(|| choose(&cf, &current));
    if let Place::Domain(zone) = &place
        && !cf.zones().iter().any(|z| &z.name == zone)
    {
        fail(&format!("{zone} is not a domain on this Cloudflare account"));
    }

    step("R2 bucket");
    let made = wrangler(&["r2", "bucket", "create", BUCKET]).output();
    match made {
        Ok(o) if o.status.success() => println!("  created {BUCKET}"),
        Ok(o) if String::from_utf8_lossy(&[o.stdout.as_slice(), o.stderr.as_slice()].concat()).contains("already exists") => {
            println!("  {BUCKET} exists")
        }
        _ => fail("could not create the R2 bucket (is R2 enabled on the account? dash.cloudflare.com → R2)"),
    }
    // the backstop for the 7-day rule: whatever is left in s/ goes after 8 days
    let rules = wrangler(&["r2", "bucket", "lifecycle", "list", BUCKET]).output();
    if rules.is_ok_and(|o| String::from_utf8_lossy(&o.stdout).contains("expire-shares")) {
        println!("  lifecycle rule exists");
    } else if wrangler(&[
        "r2", "bucket", "lifecycle", "add", BUCKET, "expire-shares", "s/", "--expire-days", "8", "--force",
    ])
    .output()
    .is_ok_and(|o| o.status.success())
    {
        println!("  lifecycle: files expire after 8 days");
    } else {
        fail("could not add the R2 lifecycle rule");
    }

    // deploy before the secrets: `secret put` on a Worker that does not exist
    // yet stops to ask whether to make it
    step("deploying the Worker");
    let host = match &place {
        Place::Domain(zone) => Some(format!("{SUBDOMAIN}.{zone}")),
        _ => None,
    };
    let mut deploy = vec!["deploy"];
    if let Some(host) = &host {
        deploy.extend(["--domain", host.as_str()]);
    }
    let record = std::env::temp_dir().join(format!("atlas-share-deploy-{}.ndjson", std::process::id()));
    let ok = run_inherit(wrangler(&deploy).env("WRANGLER_OUTPUT_FILE_PATH", &record));
    let printed = std::fs::read_to_string(&record).unwrap_or_default();
    let _ = std::fs::remove_file(&record);
    if !ok {
        fail(match &host {
            Some(_) => "wrangler deploy failed (is there already a DNS record with that name? remove it, or pick another domain)",
            None => "wrangler deploy failed (a first deploy may ask you to pick a workers.dev subdomain in the dashboard)",
        });
    }
    let url = match &place {
        Place::Domain(_) => format!("https://{}", host.as_deref().unwrap_or_default()),
        Place::Url(u) => u.clone(),
        Place::WorkersDev => workers_dev_url(&printed).unwrap_or_else(|| {
            fail("deployed, but no workers.dev address was found; run again with --url https://…")
        }),
    };
    // a domain chosen before stays attached until it is replaced
    for (account, id, hostname) in cf.worker_domains() {
        if Some(&hostname) != host.as_ref() {
            cf.call("DELETE", &format!("/accounts/{account}/workers/domains/{id}"));
            println!("  removed {hostname}");
        }
    }

    step("secrets");
    // keep the server's token when there is one, so re-running changes nothing
    let existing = ssh_capture(&format!("sudo sed -n 's/^ATLAS_SHARE_TOKEN=//p' {ENV_FILE}"));
    let token = Some(existing.trim().to_string()).filter(|t| t.len() >= 32).unwrap_or_else(random_hex);
    let secrets = wrangler(&["secret", "list"]).output().map(|o| String::from_utf8_lossy(&o.stdout).into_owned());
    put_secret(&dir, "SHARE_TOKEN", &token);
    // a new session secret would sign every recipient out: only once
    if !secrets.unwrap_or_default().contains("SESSION_SECRET") {
        put_secret(&dir, "SESSION_SECRET", &random_hex());
    }

    step("connecting atlas");
    let script = format!(
        "read -r url; read -r token; \
         sudo sed -i '/^ATLAS_SHARE_URL=/d; /^ATLAS_SHARE_TOKEN=/d' {ENV_FILE} && \
         printf 'ATLAS_SHARE_URL=%s\\nATLAS_SHARE_TOKEN=%s\\n' \"$url\" \"$token\" | sudo tee -a {ENV_FILE} >/dev/null && \
         sudo systemctl restart atlas-server"
    );
    // the token goes over stdin, never onto a command line
    let mut child = Command::new("ssh")
        .args([ssh_host(), &script])
        .stdin(Stdio::piped())
        .spawn()
        .unwrap_or_else(|_| fail("ssh failed"));
    let _ = writeln!(child.stdin.take().expect("stdin"), "{url}\n{token}");
    if !child.wait().map(|s| s.success()).unwrap_or(false) {
        fail(&format!("could not write {ENV_FILE} on the server"));
    }

    // a new custom domain needs a moment for its DNS record and certificate
    let tries = if host.is_some() { 24 } else { 3 };
    if (0..tries).any(|i| {
        if i > 0 {
            std::thread::sleep(std::time::Duration::from_secs(5));
        }
        health(&url, &token)
    }) {
        println!("\n{GREEN}✓ atlas-share is live{RESET}  {url}");
        if current.as_deref().is_some_and(|c| c != url) {
            println!("{DIM}every link now uses this address{RESET}");
        }
        println!("{DIM}links expire after 7 days at the latest; share from an album or a selection in the app{RESET}");
    } else {
        fail(&format!("deployed to {url}, but it does not answer yet; try `atlas share status` in a minute"));
    }
}

const SUBDOMAIN: &str = "atlas-share";

/// share/, Node.js, the server awake, wrangler installed and logged in.
fn prepare() -> PathBuf {
    let dir = share_dir().unwrap_or_else(|| {
        fail("run this inside an atlas checkout (it needs share/), or set ATLAS_SHARE_DIR")
    });
    if Command::new("npx").arg("--version").stdout(Stdio::null()).status().map(|s| !s.success()).unwrap_or(true) {
        fail("Node.js is needed for wrangler, Cloudflare's CLI: https://nodejs.org (or brew install node)");
    }
    ensure_up();

    step("installing wrangler");
    if !run_inherit(Command::new("npm").args(["install", "--no-audit", "--no-fund", "--silent"]).current_dir(&dir)) {
        fail("npm install failed in share/");
    }
    step("Cloudflare account");
    let logged_in = wrangler(&dir, &["whoami"]).output().map(|o| {
        o.status.success() && !String::from_utf8_lossy(&o.stdout).contains("You are not authenticated")
    });
    if !logged_in.unwrap_or(false) && !run_inherit(&mut wrangler(&dir, &["login"])) {
        fail("wrangler login did not finish");
    }
    dir
}

fn wrangler(dir: &Path, args: &[&str]) -> Command {
    let mut c = Command::new("npx");
    c.arg("wrangler").args(args).current_dir(dir);
    c
}

/// Asks which domain links live on: the account's domains, workers.dev, or
/// (Enter) what is set up now.
fn choose(cf: &Cf, current: &Option<String>) -> Place {
    let zones = cf.zones();
    let keep = current.as_ref().map(|u| match u.strip_prefix(&format!("https://{SUBDOMAIN}.")) {
        Some(zone) if zones.iter().any(|z| z.name == zone) => Place::Domain(zone.to_string()),
        _ if u.ends_with(".workers.dev") => Place::WorkersDev,
        _ => Place::Url(u.clone()),
    });
    if !std::io::stdin().is_terminal() {
        return keep.unwrap_or(Place::WorkersDev);
    }
    println!("\nWhere should share links live?");
    for (i, z) in zones.iter().enumerate() {
        let mark = if keep == Some(Place::Domain(z.name.clone())) { "  (current)" } else { "" };
        println!("  {:>2}  {SUBDOMAIN}.{}{mark}", i + 1, z.name);
    }
    let mark = if keep == Some(Place::WorkersDev) { "  (current)" } else { "" };
    println!("  {:>2}  the free workers.dev address{mark}", 0);
    loop {
        print!("{}", if keep.is_some() { "Choose [Enter keeps the current one]: " } else { "Choose: " });
        let _ = std::io::stdout().flush();
        let mut line = String::new();
        if std::io::stdin().lock().read_line(&mut line).unwrap_or(0) == 0 {
            exit(1);
        }
        match line.trim() {
            "" if keep.is_some() => return keep.unwrap(),
            "0" => return Place::WorkersDev,
            n => match n.parse::<usize>().ok().and_then(|n| zones.get(n.wrapping_sub(1))) {
                Some(z) => return Place::Domain(z.name.clone()),
                None => println!("{RED}a number from the list{RESET}"),
            },
        }
    }
}

// MARK: - destroy

/// Undoes setup: every link stops, the bucket is emptied and deleted, the
/// Worker (with its cron, secrets and custom domains) is deleted, and the
/// server forgets atlas-share.
fn destroy(args: &[String]) {
    let yes = matches!(args, [flag] if flag == "--yes" || flag == "-y");
    let dir = prepare();
    let url = server_env("ATLAS_SHARE_URL");
    let token = server_env("ATLAS_SHARE_TOKEN");

    println!("\nThis removes from Cloudflare: the Worker {SUBDOMAIN} (its cron, secrets and custom domains),");
    println!("the R2 bucket {BUCKET} with every shared file, and the server's link to it. Every link stops working.");
    if !yes {
        if !std::io::stdin().is_terminal() {
            fail("pass --yes to destroy without asking");
        }
        print!("Type destroy to go on: ");
        let _ = std::io::stdout().flush();
        let mut line = String::new();
        let _ = std::io::stdin().lock().read_line(&mut line);
        if line.trim() != "destroy" {
            fail("nothing was removed");
        }
    }

    step("stopping links");
    let ids = api("GET", "/shares", "import json,sys; print(' '.join(s['id'] for s in json.load(sys.stdin)['shares']))");
    for id in ids.split_whitespace().filter(|id| id.chars().all(|c| c.is_ascii_alphanumeric())) {
        api("DELETE", &format!("/shares/{id}"), "import sys; sys.stdin.read()");
        println!("  {id}");
    }

    step("emptying the bucket");
    if let (Some(url), Some(token)) = (&url, &token) {
        // the Worker deletes up to 20,000 files per call
        for _ in 0..1000 {
            let out = curl_with_token("DELETE", &format!("{url}/api/everything"), token);
            if !out.contains("\"more\":true") {
                break;
            }
        }
    }

    step("custom domains");
    let cf = Cf::new(&dir);
    for (account, id, hostname) in cf.worker_domains() {
        cf.call("DELETE", &format!("/accounts/{account}/workers/domains/{id}"));
        println!("  removed {hostname}");
    }

    step("Worker");
    let out = wrangler(&dir, &["delete", SUBDOMAIN, "--force"]).output();
    match out {
        Ok(o) if o.status.success() => println!("  deleted {SUBDOMAIN}"),
        _ => println!("  {DIM}no Worker {SUBDOMAIN} (already gone){RESET}"),
    }

    step("R2 bucket");
    let out = wrangler(&dir, &["r2", "bucket", "delete", BUCKET]).output();
    match out {
        Ok(o) if o.status.success() => println!("  deleted {BUCKET}"),
        Ok(o) if String::from_utf8_lossy(&[o.stdout.as_slice(), o.stderr.as_slice()].concat()).contains("does not exist") => {
            println!("  {DIM}no bucket {BUCKET} (already gone){RESET}")
        }
        _ => println!(
            "  {RED}the bucket could not be deleted (not empty?){RESET}: delete {BUCKET} in the dashboard (R2); its files expire within 8 days anyway"
        ),
    }

    step("server");
    let script = format!(
        "sudo sed -i '/^ATLAS_SHARE_URL=/d; /^ATLAS_SHARE_TOKEN=/d' {ENV_FILE} && sudo systemctl restart atlas-server"
    );
    if !ssh_ok_quiet(&script) {
        fail(&format!("could not update {ENV_FILE} on the server"));
    }
    println!("\n{GREEN}✓ atlas-share is gone{RESET}  {DIM}(atlas share setup brings it back){RESET}");
}

fn ssh_ok_quiet(remote: &str) -> bool {
    Command::new("ssh").args([ssh_host(), remote]).status().map(|s| s.success()).unwrap_or(false)
}

/// A value of /etc/atlas/atlas.env on the server.
fn server_env(key: &str) -> Option<String> {
    Some(ssh_capture(&format!("sudo sed -n 's/^{key}=//p' {ENV_FILE}")).trim().to_string()).filter(|v| !v.is_empty())
}

// MARK: - Cloudflare's API, with wrangler's login

struct Cf {
    token: String,
}

struct Zone {
    name: String,
}

impl Cf {
    fn new(dir: &Path) -> Self {
        let out = wrangler(dir, &["auth", "token", "--json"]).output().ok();
        let token = out
            .and_then(|o| serde_json::from_slice::<serde_json::Value>(&o.stdout).ok())
            .and_then(|v| v["token"].as_str().map(str::to_string))
            .unwrap_or_else(|| fail("could not read wrangler's Cloudflare login (npx wrangler login)"));
        Self { token }
    }

    /// One API call; the `result` of a successful answer.
    fn call(&self, method: &str, path: &str) -> Option<serde_json::Value> {
        let out = curl_with_token(method, &format!("https://api.cloudflare.com/client/v4{path}"), &self.token);
        let v: serde_json::Value = serde_json::from_str(&out).ok()?;
        v["success"].as_bool().filter(|ok| *ok).map(|_| v["result"].clone())
    }

    fn list(&self, path: &str) -> Vec<serde_json::Value> {
        self.call("GET", path).and_then(|r| r.as_array().cloned()).unwrap_or_default()
    }

    /// The account's active domains.
    fn zones(&self) -> Vec<Zone> {
        self.list("/zones?status=active&per_page=50")
            .iter()
            .filter_map(|z| Some(Zone { name: z["name"].as_str()?.to_string() }))
            .collect()
    }

    /// Custom domains of the atlas-share Worker: (account, id, hostname).
    fn worker_domains(&self) -> Vec<(String, String, String)> {
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
fn curl_with_token(method: &str, url: &str, token: &str) -> String {
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

fn step(name: &str) {
    println!("{DIM}→ {name}{RESET}");
}

/// The repo's share/ directory: ATLAS_SHARE_DIR, or found from here upwards.
fn share_dir() -> Option<PathBuf> {
    if let Ok(d) = std::env::var("ATLAS_SHARE_DIR") {
        return Some(PathBuf::from(d)).filter(|p| p.join("wrangler.jsonc").is_file());
    }
    let mut dir = std::env::current_dir().ok()?;
    loop {
        let candidate = dir.join("share");
        if candidate.join("wrangler.jsonc").is_file() {
            return Some(candidate);
        }
        if !dir.pop() {
            return None;
        }
    }
}

fn put_secret(dir: &PathBuf, name: &str, value: &str) {
    let mut child = Command::new("npx")
        .args(["wrangler", "secret", "put", name])
        .current_dir(dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()
        .unwrap_or_else(|_| fail("wrangler failed"));
    let _ = child.stdin.take().expect("stdin").write_all(value.as_bytes());
    if !child.wait().map(|s| s.success()).unwrap_or(false) {
        fail(&format!("could not set the {name} secret"));
    }
    println!("  {name} set");
}

fn random_hex() -> String {
    let mut bytes = [0u8; 32];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| std::io::Read::read_exact(&mut f, &mut bytes))
        .unwrap_or_else(|_| fail("no random source"));
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// `https://atlas-share.<subdomain>.workers.dev` from wrangler's output
/// record (one JSON object per line; the deploy entry lists its targets).
fn workers_dev_url(printed: &str) -> Option<String> {
    printed.split(|c: char| c.is_whitespace() || c == '"' || c == ',' || c == '[' || c == ']').find_map(|word| {
        let word = word.trim_matches(|c: char| !c.is_ascii_graphic() || c == '(' || c == ')');
        (word.starts_with("https://") && word.ends_with(".workers.dev")).then(|| word.to_string())
    })
}

fn health(url: &str, token: &str) -> bool {
    curl_with_token("GET", &format!("{url}/api/health"), token).contains("\"ok\":true")
}

// MARK: - status, ls, rm (through the server's API, on the server)

/// Runs `curl` against the local atlas-server on the box with its token, so
/// the token never leaves it. `rest` follows the URL.
fn api(method: &str, path: &str, format: &str) -> String {
    ssh_capture(&format!(
        "T=$(sudo sed -n 's/^ATLAS_TOKEN=//p' {ENV_FILE}); \
         curl -fsS -X {method} -H \"Authorization: Bearer $T\" http://127.0.0.1:8787/v1{path} | python3 -c {}",
        shq(format)
    ))
}

fn status() {
    ensure_up();
    let url = ssh_capture(&format!("sudo sed -n 's/^ATLAS_SHARE_URL=//p' {ENV_FILE}")).trim().to_string();
    if url.is_empty() {
        println!("atlas-share is not set up. Run {GREEN}atlas share setup{RESET} in an atlas checkout.");
        return;
    }
    let token = ssh_capture(&format!("sudo sed -n 's/^ATLAS_SHARE_TOKEN=//p' {ENV_FILE}")).trim().to_string();
    let live = health(&url, &token);
    println!(
        "{}  {url}",
        if live { format!("{GREEN}● live{RESET}") } else { format!("{RED}● not answering{RESET}") }
    );
    let n = api("GET", "/shares", "import json,sys; print(len(json.load(sys.stdin)['shares']))");
    println!("{DIM}{} live links · every link expires after 7 days at the latest{RESET}", n.trim());
}

fn list() {
    ensure_up();
    let out = api(
        "GET",
        "/shares",
        r#"import json,sys
from datetime import datetime, timezone
s = json.load(sys.stdin)["shares"]
if not s: print("no live links")
for x in s:
    left = datetime.fromisoformat(x["expires_at"].replace("Z", "+00:00")) - datetime.now(timezone.utc)
    state = x["state"] if x["state"] != "uploading" else "uploading %d%%" % (100 * x["done_bytes"] // max(x["total_bytes"], 1))
    print("%s  %-28.28s %4d items  %-14s %dd %dh left\n  %s" % (x["id"], x["title"], x["count"], state, left.days, left.seconds // 3600, x["url"]))"#,
    );
    if out.trim().is_empty() {
        fail("the server did not answer (is atlas-server running? `atlas deploy status`)");
    }
    print!("{out}");
}

fn stop(id: &str) {
    if !id.chars().all(|c| c.is_ascii_alphanumeric()) {
        fail("not a share id");
    }
    ensure_up();
    let out = api("DELETE", &format!("/shares/{id}"), "import json,sys; print(json.load(sys.stdin).get('deleted'))");
    if out.trim() == "True" {
        println!("{GREEN}✓ stopped sharing {id}{RESET}");
    } else {
        fail("no such link, or the server did not answer");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_workers_dev_address() {
        let record = r#"{"type":"deploy","version":1,"worker_name":"atlas-share","targets":["https://atlas-share.someone.workers.dev"]}"#;
        assert_eq!(workers_dev_url(record).as_deref(), Some("https://atlas-share.someone.workers.dev"));
        let out = "Uploaded atlas-share (3.1 sec)\nDeployed atlas-share triggers (0.4 sec)\n  https://atlas-share.someone.workers.dev\n  schedule: 0 4 * * *";
        assert_eq!(workers_dev_url(out).as_deref(), Some("https://atlas-share.someone.workers.dev"));
        assert_eq!(workers_dev_url("nothing here"), None);
    }
}
