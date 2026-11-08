//! `atlas share setup`: the bucket, the Worker and its secrets, and the
//! server connected to it.

use std::io::{BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio, exit};

use super::cloudflare::{Cf, curl_with_token};
use super::{BUCKET, ENV_FILE, fail, server_env, step};
use crate::config::ssh_host;
use crate::ssh::{ensure_up, run_inherit, ssh_capture};
use crate::{DIM, GREEN, RED, RESET};

/// Where links live.
#[derive(Clone, PartialEq)]
pub(super) enum Place {
    /// atlas-share.<zone>, a Workers custom domain
    Domain(String),
    WorkersDev,
    /// an address the owner routes to the Worker themselves
    Url(String),
}

pub(super) fn setup(args: &[String]) {
    let asked = match args {
        [flag, zone] if flag == "--domain" => Some(Place::Domain(
            zone.trim().trim_end_matches('.').to_lowercase(),
        )),
        [flag] if flag == "--workers-dev" => Some(Place::WorkersDev),
        [flag, url] if flag == "--url" => Some(Place::Url(url.trim_end_matches('/').to_string())),
        [] => None,
        _ => fail(
            "usage: atlas share setup [--domain example.com | --workers-dev | --url https://…]",
        ),
    };
    let dir = prepare();
    let wrangler = |args: &[&str]| wrangler(&dir, args);

    let cf = Cf::new(&dir);
    let current = server_env("ATLAS_SHARE_URL");
    let place = asked.unwrap_or_else(|| choose(&cf, &current));
    if let Place::Domain(zone) = &place
        && !cf.zones().iter().any(|z| &z.name == zone)
    {
        fail(&format!(
            "{zone} is not a domain on this Cloudflare account"
        ));
    }

    step("R2 bucket");
    let made = wrangler(&["r2", "bucket", "create", BUCKET]).output();
    match made {
        Ok(o) if o.status.success() => println!("  created {BUCKET}"),
        Ok(o)
            if String::from_utf8_lossy(&[o.stdout.as_slice(), o.stderr.as_slice()].concat())
                .contains("already exists") =>
        {
            println!("  {BUCKET} exists")
        }
        _ => fail(
            "could not create the R2 bucket (is R2 enabled on the account? dash.cloudflare.com → R2)",
        ),
    }
    // the backstop for the 7-day rule: whatever is left in s/ goes after 8 days
    let rules = wrangler(&["r2", "bucket", "lifecycle", "list", BUCKET]).output();
    if rules.is_ok_and(|o| String::from_utf8_lossy(&o.stdout).contains("expire-shares")) {
        println!("  lifecycle rule exists");
    } else if wrangler(&[
        "r2",
        "bucket",
        "lifecycle",
        "add",
        BUCKET,
        "expire-shares",
        "s/",
        "--expire-days",
        "8",
        "--force",
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
    let record =
        std::env::temp_dir().join(format!("atlas-share-deploy-{}.ndjson", std::process::id()));
    let ok = run_inherit(wrangler(&deploy).env("WRANGLER_OUTPUT_FILE_PATH", &record));
    let printed = std::fs::read_to_string(&record).unwrap_or_default();
    let _ = std::fs::remove_file(&record);
    if !ok {
        fail(match &host {
            Some(_) => {
                "wrangler deploy failed (is there already a DNS record with that name? remove it, or pick another domain)"
            }
            None => {
                "wrangler deploy failed (a first deploy may ask you to pick a workers.dev subdomain in the dashboard)"
            }
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
            cf.call(
                "DELETE",
                &format!("/accounts/{account}/workers/domains/{id}"),
            );
            println!("  removed {hostname}");
        }
    }

    step("secrets");
    // keep the server's token when there is one, so re-running changes nothing
    let existing = ssh_capture(&format!(
        "sudo sed -n 's/^ATLAS_SHARE_TOKEN=//p' {ENV_FILE}"
    ));
    let token = Some(existing.trim().to_string())
        .filter(|t| t.len() >= 32)
        .unwrap_or_else(random_hex);
    let secrets = wrangler(&["secret", "list"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned());
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
        println!(
            "{DIM}links expire after 7 days at the latest; share from an album or a selection in the app{RESET}"
        );
    } else {
        fail(&format!(
            "deployed to {url}, but it does not answer yet; try `atlas share status` in a minute"
        ));
    }
}

pub(super) const SUBDOMAIN: &str = "atlas-share";

/// share/, Node.js, the server awake, wrangler installed and logged in.
pub(super) fn prepare() -> PathBuf {
    let dir = share_dir().unwrap_or_else(|| {
        fail("run this inside an atlas checkout (it needs share/), or set ATLAS_SHARE_DIR")
    });
    if Command::new("npx")
        .arg("--version")
        .stdout(Stdio::null())
        .status()
        .map(|s| !s.success())
        .unwrap_or(true)
    {
        fail(
            "Node.js is needed for wrangler, Cloudflare's CLI: https://nodejs.org (or brew install node)",
        );
    }
    ensure_up();

    step("installing wrangler");
    if !run_inherit(
        Command::new("npm")
            .args(["install", "--no-audit", "--no-fund", "--silent"])
            .current_dir(&dir),
    ) {
        fail("npm install failed in share/");
    }
    step("Cloudflare account");
    let logged_in = wrangler(&dir, &["whoami"]).output().map(|o| {
        o.status.success()
            && !String::from_utf8_lossy(&o.stdout).contains("You are not authenticated")
    });
    if !logged_in.unwrap_or(false) && !run_inherit(&mut wrangler(&dir, &["login"])) {
        fail("wrangler login did not finish");
    }
    dir
}

pub(super) fn wrangler(dir: &Path, args: &[&str]) -> Command {
    let mut c = Command::new("npx");
    c.arg("wrangler").args(args).current_dir(dir);
    c
}

/// Asks which domain links live on: the account's domains, workers.dev, or
/// (Enter) what is set up now.
pub(super) fn choose(cf: &Cf, current: &Option<String>) -> Place {
    let zones = cf.zones();
    let keep = current
        .as_ref()
        .map(|u| match u.strip_prefix(&format!("https://{SUBDOMAIN}.")) {
            Some(zone) if zones.iter().any(|z| z.name == zone) => Place::Domain(zone.to_string()),
            _ if u.ends_with(".workers.dev") => Place::WorkersDev,
            _ => Place::Url(u.clone()),
        });
    if !std::io::stdin().is_terminal() {
        return keep.unwrap_or(Place::WorkersDev);
    }
    println!("\nWhere should share links live?");
    for (i, z) in zones.iter().enumerate() {
        let mark = if keep == Some(Place::Domain(z.name.clone())) {
            "  (current)"
        } else {
            ""
        };
        println!("  {:>2}  {SUBDOMAIN}.{}{mark}", i + 1, z.name);
    }
    let mark = if keep == Some(Place::WorkersDev) {
        "  (current)"
    } else {
        ""
    };
    println!("  {:>2}  the free workers.dev address{mark}", 0);
    loop {
        print!(
            "{}",
            if keep.is_some() {
                "Choose [Enter keeps the current one]: "
            } else {
                "Choose: "
            }
        );
        let _ = std::io::stdout().flush();
        let mut line = String::new();
        if std::io::stdin().lock().read_line(&mut line).unwrap_or(0) == 0 {
            exit(1);
        }
        match line.trim() {
            "" if keep.is_some() => return keep.unwrap(),
            "0" => return Place::WorkersDev,
            n => match n
                .parse::<usize>()
                .ok()
                .and_then(|n| zones.get(n.wrapping_sub(1)))
            {
                Some(z) => return Place::Domain(z.name.clone()),
                None => println!("{RED}a number from the list{RESET}"),
            },
        }
    }
}

/// The repo's share/ directory: ATLAS_SHARE_DIR, or found from here upwards.
pub(super) fn share_dir() -> Option<PathBuf> {
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

pub(super) fn put_secret(dir: &PathBuf, name: &str, value: &str) {
    let mut child = Command::new("npx")
        .args(["wrangler", "secret", "put", name])
        .current_dir(dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()
        .unwrap_or_else(|_| fail("wrangler failed"));
    let _ = child
        .stdin
        .take()
        .expect("stdin")
        .write_all(value.as_bytes());
    if !child.wait().map(|s| s.success()).unwrap_or(false) {
        fail(&format!("could not set the {name} secret"));
    }
    println!("  {name} set");
}

pub(super) fn random_hex() -> String {
    let mut bytes = [0u8; 32];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| std::io::Read::read_exact(&mut f, &mut bytes))
        .unwrap_or_else(|_| fail("no random source"));
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// `https://atlas-share.<subdomain>.workers.dev` from wrangler's output
/// record (one JSON object per line; the deploy entry lists its targets).
pub(super) fn workers_dev_url(printed: &str) -> Option<String> {
    printed
        .split(|c: char| c.is_whitespace() || c == '"' || c == ',' || c == '[' || c == ']')
        .find_map(|word| {
            let word = word.trim_matches(|c: char| !c.is_ascii_graphic() || c == '(' || c == ')');
            (word.starts_with("https://") && word.ends_with(".workers.dev"))
                .then(|| word.to_string())
        })
}

pub(super) fn health(url: &str, token: &str) -> bool {
    curl_with_token("GET", &format!("{url}/api/health"), token).contains("\"ok\":true")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_workers_dev_address() {
        let record = r#"{"type":"deploy","version":1,"worker_name":"atlas-share","targets":["https://atlas-share.someone.workers.dev"]}"#;
        assert_eq!(
            workers_dev_url(record).as_deref(),
            Some("https://atlas-share.someone.workers.dev")
        );
        let out = "Uploaded atlas-share (3.1 sec)\nDeployed atlas-share triggers (0.4 sec)\n  https://atlas-share.someone.workers.dev\n  schedule: 0 4 * * *";
        assert_eq!(
            workers_dev_url(out).as_deref(),
            Some("https://atlas-share.someone.workers.dev")
        );
        assert_eq!(workers_dev_url("nothing here"), None);
    }
}
