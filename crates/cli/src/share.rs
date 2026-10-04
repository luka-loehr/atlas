//! `atlas share`: link sharing through atlas-share, a Cloudflare Worker on
//! your own account (share/ in the repo).
//!
//!   atlas share setup [--url U]   deploy atlas-share and connect the server
//!   atlas share status            is it set up, does the Worker answer
//!   atlas share ls                live links
//!   atlas share rm <id>           stop sharing a link
//!
//! Setup runs on the Mac, from an atlas checkout, with Node.js: wrangler logs
//! in to Cloudflare in the browser, then the bucket, its 8-day lifecycle rule,
//! the two secrets and the Worker are made (safe to re-run), and the Worker's
//! address and admin token go into /etc/atlas/atlas.env on the server.

use std::io::Write;
use std::path::PathBuf;
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
        Some(other) => fail(&format!("unknown: atlas share {other}  (setup | status | ls | rm <id>)")),
    }
}

fn fail(message: &str) -> ! {
    eprintln!("{RED}{message}{RESET}");
    exit(1);
}

// MARK: - setup

fn setup(args: &[String]) {
    let custom_url = match args {
        [flag, url] if flag == "--url" => Some(url.trim_end_matches('/').to_string()),
        [] => None,
        _ => fail("usage: atlas share setup [--url https://share.example.com]"),
    };
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
    let wrangler = |args: &[&str]| {
        let mut c = Command::new("npx");
        c.arg("wrangler").args(args).current_dir(&dir);
        c
    };

    step("Cloudflare account");
    let logged_in = wrangler(&["whoami"]).output().map(|o| {
        o.status.success() && !String::from_utf8_lossy(&o.stdout).contains("You are not authenticated")
    });
    if !logged_in.unwrap_or(false) && !run_inherit(&mut wrangler(&["login"])) {
        fail("wrangler login did not finish");
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
    let rule = wrangler(&[
        "r2", "bucket", "lifecycle", "add", BUCKET, "expire-shares", "s/", "--expire-days", "8", "--force",
    ])
    .output();
    match rule {
        Ok(o) if o.status.success() => println!("  lifecycle: files expire after 8 days"),
        Ok(o) if String::from_utf8_lossy(&[o.stdout.as_slice(), o.stderr.as_slice()].concat()).contains("already exists") => {
            println!("  lifecycle rule exists")
        }
        _ => fail("could not add the R2 lifecycle rule"),
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

    step("deploying the Worker");
    let out = wrangler(&["deploy"]).stderr(Stdio::inherit()).output().unwrap_or_else(|_| fail("wrangler deploy failed"));
    let printed = String::from_utf8_lossy(&out.stdout).into_owned();
    print!("{DIM}{printed}{RESET}");
    if !out.status.success() {
        fail("wrangler deploy failed");
    }
    let url = custom_url.or_else(|| workers_dev_url(&printed)).unwrap_or_else(|| {
        fail("deployed, but no workers.dev address was printed; run again with --url https://…")
    });

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

    if health(&url, &token) {
        println!("\n{GREEN}✓ atlas-share is live{RESET}  {url}");
        println!("{DIM}links expire after 7 days at the latest; share from an album or a selection in the app{RESET}");
    } else {
        fail(&format!("deployed to {url}, but it does not answer yet; try `atlas share status` in a minute"));
    }
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

/// `https://atlas-share.<subdomain>.workers.dev` from wrangler's output.
fn workers_dev_url(printed: &str) -> Option<String> {
    printed.split_whitespace().find_map(|word| {
        let word = word.trim_matches(|c: char| !c.is_ascii_graphic() || c == '(' || c == ')');
        (word.starts_with("https://") && word.ends_with(".workers.dev")).then(|| word.to_string())
    })
}

fn health(url: &str, token: &str) -> bool {
    let header = format!("Authorization: Bearer {token}");
    // curl reads the header from stdin (-H @-), so the token stays off argv
    let mut child = match Command::new("curl")
        .args(["-fsS", "--max-time", "15", "-H", "@-", &format!("{url}/api/health")])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return false,
    };
    let _ = writeln!(child.stdin.take().expect("stdin"), "{header}");
    child.wait_with_output().map(|o| o.status.success() && String::from_utf8_lossy(&o.stdout).contains("\"ok\":true")).unwrap_or(false)
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
        let out = "Uploaded atlas-share (3.1 sec)\nDeployed atlas-share triggers (0.4 sec)\n  https://atlas-share.someone.workers.dev\n  schedule: 0 4 * * *";
        assert_eq!(workers_dev_url(out).as_deref(), Some("https://atlas-share.someone.workers.dev"));
        assert_eq!(workers_dev_url("nothing here"), None);
    }
}
