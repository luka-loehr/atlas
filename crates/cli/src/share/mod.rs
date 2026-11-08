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

use std::process::{Command, exit};

use crate::config::ssh_host;
use crate::ssh::ssh_capture;
use crate::{DIM, RED, RESET};

mod cloudflare;
mod destroy;
mod links;
mod setup;

use destroy::destroy;
use links::{list, status, stop};
use setup::setup;

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

fn step(name: &str) {
    println!("{DIM}→ {name}{RESET}");
}

fn ssh_ok_quiet(remote: &str) -> bool {
    Command::new("ssh").args([ssh_host(), remote]).status().map(|s| s.success()).unwrap_or(false)
}

/// A value of /etc/atlas/atlas.env on the server.
fn server_env(key: &str) -> Option<String> {
    Some(ssh_capture(&format!("sudo sed -n 's/^{key}=//p' {ENV_FILE}")).trim().to_string()).filter(|v| !v.is_empty())
}
