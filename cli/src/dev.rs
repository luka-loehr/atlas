//! `atlas dev`: run a dev server on atlas. Default is tailnet-private with a
//! stable URL; `--public` publishes at https://<name>.lukaloehr.com via host
//! Caddy + the persistent named Cloudflare tunnel. There is no random
//! trycloudflare quick-tunnel any more.

use std::os::unix::process::CommandExt;
use std::process::{Command, exit};

use crate::config::{ssh_host, tailnet_host};
use crate::git::sync_worktree;
use crate::project::{BuildCfg, ensure_image, host_label, load_config, slug_of, valid_host_label};
use crate::secrets::{env_file_prologue, warn_if_secrets_unpushed};
use crate::serve::{serve_off, serve_url};
use crate::ssh::{ensure_up, shq, ssh_ok};
use crate::state::short;
use crate::web::{
    caddy_admin_ok, caddy_route_exists, caddy_route_remove, caddy_route_upsert, route_id,
    tunnel_active,
};
use crate::{DIM, GREEN, RED, RESET};

pub(crate) fn dev(argv: &[String]) {
    let (branch, sub) = crate::build::take_branch(argv);
    let slug = slug_of(&branch);
    let cfg = load_config();
    match sub.first().map(String::as_str) {
        Some("stop") => dev_stop(&cfg, &slug, &branch),
        Some("url") => {
            println!(
                "{}",
                dev_url(&cfg, &slug).unwrap_or_else(|| "(no dev server active)".into())
            )
        }
        Some("logs") => dev_logs(&cfg, &slug),
        _ => dev_start(&cfg, &branch, &slug, sub.iter().any(|a| a == "--public")),
    }
}

fn dev_name(cfg: &BuildCfg, slug: &str) -> String {
    format!("atlas-dev-{}-{slug}", cfg.slug_id())
}

/// Whichever URL currently serves this project: the tailnet one if published,
/// else the public host if a Caddy route exists.
pub(crate) fn dev_url(cfg: &BuildCfg, slug: &str) -> Option<String> {
    serve_url(cfg, slug, "dev").or_else(|| {
        if caddy_route_exists(&route_id(cfg, slug)) {
            Some(format!("https://{}.lukaloehr.com", host_label(cfg, slug)))
        } else {
            None
        }
    })
}

fn dev_stop(cfg: &BuildCfg, slug: &str, branch: &str) {
    ssh_ok(&format!(
        "docker rm -f {} >/dev/null 2>&1",
        dev_name(cfg, slug)
    ));
    serve_off(cfg, slug, "dev");
    caddy_route_remove(&route_id(cfg, slug));
    println!("{GREEN}dev stopped{RESET} ({} @ {branch})", cfg.name);
}

fn dev_logs(cfg: &BuildCfg, slug: &str) -> ! {
    let err = Command::new("ssh")
        .args([
            "-t",
            ssh_host(),
            &format!("docker logs -f {}", dev_name(cfg, slug)),
        ])
        .exec();
    eprintln!("ssh: {err}");
    exit(1);
}

fn dev_start(cfg: &BuildCfg, branch: &str, slug: &str, public: bool) {
    if cfg.dev.is_empty() {
        eprintln!("{RED}config has no dev = ...{RESET}");
        exit(1);
    }
    // Without --public we need a tailnet host to publish on; there is no public
    // fallback tunnel any more, so say so and point at --public.
    if !public && tailnet_host().is_none() {
        eprintln!(
            "{RED}no tailnet host configured{RESET} (ATLAS_TAILNET_ADDR in ~/.config/atlas/env)"
        );
        eprintln!("{DIM}  publish publicly instead:  atlas dev --public{RESET}");
        exit(1);
    }

    ensure_up();
    let spec = cfg.spec(true);
    ensure_image(&spec);
    warn_if_secrets_unpushed(cfg);
    let commit = sync_worktree(cfg, branch, slug);
    let dev = dev_name(cfg, slug);

    // For --public, verify the shared infra is up before improvising anything.
    if public && (!caddy_admin_ok() || !tunnel_active()) {
        eprintln!("{RED}public dev infra is not ready on atlas{RESET}");
        eprintln!("{DIM}  Caddy admin and cloudflared must be running{RESET}");
        eprintln!("{DIM}  run scripts/atlas-web/install.sh on atlas{RESET}");
        exit(1);
    }

    // Fresh start — the serve config too, because it outlives the containers.
    ssh_ok(&format!("docker rm -f {dev} >/dev/null 2>&1"));
    serve_off(cfg, slug, "dev");

    // The host(s) this dev server is reachable at, injected as ATLAS_DEV_ORIGINS
    // so a framework config can allow this origin without hardcoding a URL — e.g.
    // Next's `allowedDevOrigins: process.env.ATLAS_DEV_ORIGINS?.split(",") ?? []`.
    // A production build never sets this env, so it stays dev-only by
    // construction. The tailnet host covers the private path; --public adds the
    // stable lukaloehr host. Both are validated hostnames (charset [a-z0-9.-]).
    let mut origins: Vec<String> = Vec::new();
    if let Some(h) = tailnet_host() {
        origins.push(h.to_string());
    }
    if public {
        origins.push(format!("{}.lukaloehr.com", host_label(cfg, slug)));
    }
    let dev_origins = origins.join(",");

    // dev server: --network host so it binds atlas' real port; node_modules
    // persist in the worktree (git clean keeps ignored files). The install step
    // is picked from the lockfile rather than hardcoded to npm.
    let devcmd = format!("{} && {}", cfg.install_cmd(), cfg.dev);
    let run_dev = format!(
        "{prologue}docker run -d --name {dev} --network host --restart unless-stopped $envf \
         -e npm_config_cache=/cache/npm -e HOST=0.0.0.0 -e PORT={port} \
         -e ATLAS_DEV_ORIGINS={origins} \
         -v \"$HOME/{wt}\":/build -v \"$HOME/{cache}\":/cache \
         -v \"$HOME/{repo}\":\"$HOME/{repo}\" \
         -w {wd} {tag} sh -c {cmd} >/dev/null",
        prologue = env_file_prologue(cfg),
        port = cfg.port,
        origins = dev_origins,
        wt = cfg.wt_dir(slug),
        cache = cfg.cache_dir(),
        repo = cfg.repo_dir(),
        wd = cfg.workdir(),
        tag = spec.tag,
        cmd = shq(&devcmd),
    );
    if !ssh_ok(&run_dev) {
        eprintln!("{RED}dev container start failed{RESET}");
        exit(1);
    }

    if public {
        dev_expose_public(cfg, slug);
    } else {
        dev_expose_tailnet(cfg, slug);
    }
    println!(
        "{DIM}  dev server runs on atlas ({} @ {branch}, {}), the Mac stays cool.{RESET}",
        cfg.name,
        short(&commit)
    );
    println!("{DIM}  changes:  push → atlas dev{RESET}");
    println!("{DIM}  logs:  atlas dev logs   ·   stop:  atlas dev stop{RESET}");
}

/// Publish the dev server on the tailnet. tailscaled runs on the host, so the
/// serve config is set over ssh (sudo, the same passwordless sudo build's chown
/// uses). No wait loop: the URL is computed, not discovered; it answers 502
/// until install + dev finish, which `atlas dev logs` shows.
fn dev_expose_tailnet(cfg: &BuildCfg, slug: &str) {
    let host = match tailnet_host() {
        Some(h) => h,
        None => return,
    };
    let port = crate::serve::tailnet_port(&crate::serve::port_key(cfg, slug, "dev"));
    let ok = ssh_ok(&format!(
        "sudo tailscale serve --bg --https={port} http://127.0.0.1:{dev} >/dev/null",
        dev = cfg.port
    ));
    if !ok {
        eprintln!("{RED}tailscale serve failed{RESET} (port {port})");
        eprintln!(
            "{DIM}  is tailscaled running on atlas, and is HTTPS enabled on the tailnet?\n  \
             alternative: atlas dev --public{RESET}"
        );
        exit(1);
    }
    println!("\n  {GREEN}https://{host}:{port}{RESET}\n");
    println!("{DIM}  reachable only on the tailnet, directly over WireGuard — and the URL{RESET}");
    println!("{DIM}  stays the same, so it works for OAuth redirects and webhooks.{RESET}");
    println!("{DIM}  public instead:  atlas dev --public{RESET}");
}

/// Publish the dev server on the stable public subdomain via host Caddy + the
/// persistent tunnel. No random URL, no token needed — just a validated Caddy
/// route to the app's loopback port.
fn dev_expose_public(cfg: &BuildCfg, slug: &str) {
    let label = host_label(cfg, slug);
    let host = format!("{label}.lukaloehr.com");
    if !valid_host_label(&label) || host.len() > 253 {
        eprintln!(
            "{RED}cannot build a valid public host from '{}'{RESET}",
            cfg.name
        );
        eprintln!("{DIM}  the host label must match ^[a-z0-9-]{{1,63}}$ (lowercase name){RESET}");
        exit(1);
    }
    let id = route_id(cfg, slug);
    if !caddy_route_upsert(&host, cfg.port, &id) {
        eprintln!("{RED}Caddy route upsert failed{RESET} ({host})");
        exit(1);
    }
    println!("\n  {GREEN}https://{host}{RESET}\n");
    println!("{DIM}  stable public URL — good for OAuth redirects and webhooks.{RESET}");
    println!("{DIM}  answers 502 until install + dev finish (atlas dev logs).{RESET}");
}
