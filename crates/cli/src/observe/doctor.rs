//! `atlas doctor`.

use std::process::exit;

use crate::config::tailnet_host;
use crate::ssh::{probe, ssh_capture, ssh_ok};
use crate::web::{caddy_admin_ok, tunnel_active, wildcard_dns_ok};
use crate::{DIM, GREEN, RED, RESET};

#[derive(PartialEq)]
enum St {
    Pass,
    Warn,
    Fail,
}

pub(crate) fn doctor() {
    let mut checks: Vec<(St, String, String)> = Vec::new();
    let mut add = |s: St, name: &str, detail: String| checks.push((s, name.to_string(), detail));

    let reachable = probe();
    add(
        if reachable.is_some() {
            St::Pass
        } else {
            St::Fail
        },
        "atlas reachable",
        reachable
            .map(|r| format!("via {r}"))
            .unwrap_or_else(|| "down".into()),
    );

    let ssh = ssh_ok("true");
    add(
        if ssh { St::Pass } else { St::Fail },
        "ssh works",
        if ssh {
            "ok".into()
        } else {
            "cannot ssh".into()
        },
    );

    let docker = ssh_ok("docker version >/dev/null 2>&1");
    add(
        if docker { St::Pass } else { St::Fail },
        "docker",
        if docker {
            "ok".into()
        } else {
            "not available".into()
        },
    );

    let used = ssh_capture("df -P \"$HOME\" | awk 'NR==2{print $5}'")
        .trim()
        .trim_end_matches('%')
        .to_string();
    let usage: u32 = used.parse().unwrap_or(0);
    add(
        if usage >= 85 {
            St::Fail
        } else if usage >= 75 {
            St::Warn
        } else {
            St::Pass
        },
        "disk free",
        format!("{usage}% used (guard at 85%)"),
    );

    let builder =
        ssh_ok("docker image inspect atlas-universal-builder atlas-universal-dev >/dev/null 2>&1");
    add(
        if builder { St::Pass } else { St::Warn },
        "builder images",
        if builder {
            "present".into()
        } else {
            "missing (built lazily)".into()
        },
    );

    let mobile = ssh_ok("docker image inspect atlas-universal-mobile >/dev/null 2>&1");
    add(
        if mobile { St::Pass } else { St::Warn },
        "mobile image",
        if mobile {
            "present".into()
        } else {
            "missing (built lazily)".into()
        },
    );

    let ts = ssh_ok("tailscale status >/dev/null 2>&1") && tailnet_host().is_some();
    add(
        if ts { St::Pass } else { St::Warn },
        "tailscale",
        if ts {
            "up".into()
        } else {
            "off or no tailnet host (tailnet dev unavailable)".into()
        },
    );

    let tun = tunnel_active();
    add(
        if tun { St::Pass } else { St::Fail },
        "cloudflared tunnel",
        if tun {
            "active".into()
        } else {
            "inactive (public dev unavailable)".into()
        },
    );

    let caddy = caddy_admin_ok();
    add(
        if caddy { St::Pass } else { St::Fail },
        "Caddy admin",
        if caddy {
            "reachable".into()
        } else {
            "unreachable".into()
        },
    );

    let cfenv = ssh_ok("test -f \"$HOME/atlas-secrets/cloudflare.env\"");
    add(
        if cfenv { St::Pass } else { St::Warn },
        "cloudflare.env",
        if cfenv {
            "present".into()
        } else {
            "absent (only needed for bootstrap)".into()
        },
    );

    match crate::config::dev_domain() {
        Some(domain) => {
            let dns = wildcard_dns_ok(domain);
            add(
                if dns { St::Pass } else { St::Warn },
                "wildcard DNS",
                if dns {
                    format!("*.{domain} resolves")
                } else {
                    format!("*.{domain} unresolved")
                },
            );
        }
        None => add(
            St::Warn,
            "wildcard DNS",
            "ATLAS_DEV_DOMAIN unset (public dev not configured)".into(),
        ),
    }

    let sudo = ssh_ok("sudo -n true");
    add(
        if sudo { St::Pass } else { St::Fail },
        "passwordless sudo",
        if sudo {
            "ok".into()
        } else {
            "needed for chown/serve".into()
        },
    );

    let (mut pass, mut warn, mut fail) = (0u32, 0u32, 0u32);
    for (s, _, _) in &checks {
        match s {
            St::Pass => pass += 1,
            St::Warn => warn += 1,
            St::Fail => fail += 1,
        }
    }
    println!("atlas doctor — {pass} pass, {warn} warn, {fail} fail");
    for (s, name, detail) in &checks {
        let tag = match s {
            St::Pass => format!("{GREEN}PASS{RESET}"),
            St::Warn => format!("{DIM}WARN{RESET}"),
            St::Fail => format!("{RED}FAIL{RESET}"),
        };
        println!("  {tag}  {name:<20}  {DIM}{detail}{RESET}");
    }
    if fail > 0 {
        exit(1);
    }
}
