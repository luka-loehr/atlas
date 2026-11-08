//! `atlas share status | ls | rm`: through the server's API, on the server.

use super::setup::health;
use super::{ENV_FILE, fail};
use crate::ssh::{ensure_up, shq, ssh_capture};
use crate::{DIM, GREEN, RED, RESET};

/// Runs `curl` against the local atlas-server on the box with its token, so
/// the token never leaves it. `rest` follows the URL. The header reaches curl
/// on stdin (printf is a shell builtin), so the token is in no process list.
pub(super) fn api(method: &str, path: &str, format: &str) -> String {
    ssh_capture(&format!(
        "T=$(sudo sed -n 's/^ATLAS_TOKEN=//p' {ENV_FILE}); \
         printf 'Authorization: Bearer %s\\n' \"$T\" | \
         curl -fsS -X {method} -H @- http://127.0.0.1:8787/v1{path} | python3 -c {}",
        shq(format)
    ))
}

pub(super) fn status() {
    ensure_up();
    let url = ssh_capture(&format!("sudo sed -n 's/^ATLAS_SHARE_URL=//p' {ENV_FILE}"))
        .trim()
        .to_string();
    if url.is_empty() {
        println!(
            "atlas-share is not set up. Run {GREEN}atlas share setup{RESET} in an atlas checkout."
        );
        return;
    }
    let token = ssh_capture(&format!(
        "sudo sed -n 's/^ATLAS_SHARE_TOKEN=//p' {ENV_FILE}"
    ))
    .trim()
    .to_string();
    let live = health(&url, &token);
    println!(
        "{}  {url}",
        if live {
            format!("{GREEN}● live{RESET}")
        } else {
            format!("{RED}● not answering{RESET}")
        }
    );
    let n = api(
        "GET",
        "/shares",
        "import json,sys; print(len(json.load(sys.stdin)['shares']))",
    );
    println!(
        "{DIM}{} live links · every link expires after 7 days at the latest{RESET}",
        n.trim()
    );
}

pub(super) fn list() {
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

pub(super) fn stop(id: &str) {
    if !id.chars().all(|c| c.is_ascii_alphanumeric()) {
        fail("not a share id");
    }
    ensure_up();
    let out = api(
        "DELETE",
        &format!("/shares/{id}"),
        "import json,sys; print(json.load(sys.stdin).get('deleted'))",
    );
    if out.trim() == "True" {
        println!("{GREEN}✓ stopped sharing {id}{RESET}");
    } else {
        fail("no such link, or the server did not answer");
    }
}
