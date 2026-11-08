//! `atlas share destroy`: everything setup made, removed again.

use std::io::{BufRead, IsTerminal, Write};

use super::cloudflare::{Cf, curl_with_token};
use super::links::api;
use super::setup::{SUBDOMAIN, prepare, wrangler};
use super::{BUCKET, ENV_FILE, fail, server_env, ssh_ok_quiet, step};
use crate::{DIM, GREEN, RED, RESET};

/// Undoes setup: every link stops, the bucket is emptied and deleted, the
/// Worker (with its cron, secrets and custom domains) is deleted, and the
/// server forgets atlas-share.
pub(super) fn destroy(args: &[String]) {
    let yes = matches!(args, [flag] if flag == "--yes" || flag == "-y");
    let dir = prepare();
    let url = server_env("ATLAS_SHARE_URL");
    let token = server_env("ATLAS_SHARE_TOKEN");

    println!(
        "\nThis removes from Cloudflare: the Worker {SUBDOMAIN} (its cron, secrets and custom domains),"
    );
    println!(
        "the R2 bucket {BUCKET} with every shared file, and the server's link to it. Every link stops working."
    );
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
    let ids = api(
        "GET",
        "/shares",
        "import json,sys; print(' '.join(s['id'] for s in json.load(sys.stdin)['shares']))",
    );
    for id in ids
        .split_whitespace()
        .filter(|id| id.chars().all(|c| c.is_ascii_alphanumeric()))
    {
        api(
            "DELETE",
            &format!("/shares/{id}"),
            "import sys; sys.stdin.read()",
        );
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
        cf.call(
            "DELETE",
            &format!("/accounts/{account}/workers/domains/{id}"),
        );
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
        Ok(o)
            if String::from_utf8_lossy(&[o.stdout.as_slice(), o.stderr.as_slice()].concat())
                .contains("does not exist") =>
        {
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
    println!(
        "\n{GREEN}✓ atlas-share is gone{RESET}  {DIM}(atlas share setup brings it back){RESET}"
    );
}
