//! `atlas start`: run what `atlas build` produced, for one branch. Plus the
//! tailnet-port hashing and serve-mapping helpers shared with `atlas dev`.

use std::os::unix::process::CommandExt;
use std::process::{Command, exit};

use crate::config::{ssh_host, tailnet_host};
use crate::git::remote_tip;
use crate::project::{BuildCfg, ensure_image, load_config, slug_of};
use crate::secrets::{env_file_prologue, warn_if_secrets_unpushed};
use crate::ssh::{ensure_up, ssh_capture, ssh_ok};
use crate::state::{built_branches, short, state_field};
use crate::{DIM, GREEN, RED, RESET};

pub(crate) fn start(argv: &[String]) {
    let (branch, rest) = crate::build::take_branch(argv);
    let slug = slug_of(&branch);
    let cfg = load_config();
    match rest.first().map(String::as_str) {
        Some("stop") => start_stop(&cfg, &slug, &branch),
        Some("logs") => start_logs(&cfg, &slug),
        Some("status") => start_status(&cfg, &slug, &branch),
        _ => start_run(&cfg, &branch, &slug),
    }
}

pub(crate) fn start_name(cfg: &BuildCfg, slug: &str) -> String {
    format!("atlas-start-{}-{slug}", cfg.slug_id())
}

/// Hash key for a project's `tailscale serve` port. `main` in dev mode keeps the
/// bare project name so its URL never moves; everything else gets its own port.
pub(crate) fn port_key(cfg: &BuildCfg, slug: &str, mode: &str) -> String {
    if slug == "main" && mode == "dev" {
        cfg.name.clone()
    } else {
        format!("{}/{slug}#{mode}", cfg.name)
    }
}

/// The HTTPS port `tailscale serve` publishes on. FNV-1a, dependency-free, and
/// deliberately not std's hasher (whose output may move between Rust releases,
/// silently relocating every project's URL). The 20000..21000 band avoids the
/// box's own services below 20000 and Linux's ephemeral ports above 32768.
pub(crate) fn tailnet_port(name: &str) -> u16 {
    let mut h: u32 = 0x811c_9dc5;
    for b in name.as_bytes() {
        h = (h ^ u32::from(*b)).wrapping_mul(0x0100_0193);
    }
    20000 + (h % 1000) as u16
}

/// Whichever tailnet URL currently serves this project/mode, but only when
/// `tailscale serve` is really publishing it — callers must not print an
/// address that answers nothing.
pub(crate) fn serve_url(cfg: &BuildCfg, slug: &str, mode: &str) -> Option<String> {
    let host = tailnet_host()?;
    let port = tailnet_port(&port_key(cfg, slug, mode));
    let up = ssh_capture(&format!(
        "tailscale serve status 2>/dev/null | grep -qE '^https://[^ ]+:{port}([ /]|$)' && echo up"
    ));
    (up.trim() == "up").then(|| format!("https://{host}:{port}"))
}

/// Drop this project's serve config. Host state (tailscaled persists it), so
/// leaving it behind would advertise a dead port forever.
pub(crate) fn serve_off(cfg: &BuildCfg, slug: &str, mode: &str) {
    if tailnet_host().is_none() {
        return;
    }
    let port = tailnet_port(&port_key(cfg, slug, mode));
    ssh_ok(&format!(
        "sudo tailscale serve --https={port} off >/dev/null 2>&1"
    ));
}

fn start_run(cfg: &BuildCfg, branch: &str, slug: &str) {
    ensure_up();

    // Branch-native, and this is the whole point: start never builds.
    let commit = state_field(cfg, slug, "commit");
    if commit.is_empty() {
        eprintln!("{RED}no target for '{branch}' on atlas{RESET}");
        let have = built_branches(cfg);
        if have.is_empty() {
            eprintln!("{DIM}  nothing has been built for this project yet{RESET}");
        } else {
            eprintln!("{DIM}  built: {}{RESET}", have.join(", "));
        }
        eprintln!(
            "{DIM}  build with:  atlas build{}{RESET}",
            if branch == "main" {
                String::new()
            } else {
                format!(" -b {branch}")
            }
        );
        exit(1);
    }

    // Stale is a warning, never a refusal.
    if let Some(tip) = remote_tip(cfg, branch)
        && tip != commit
    {
        println!(
            "{DIM}note: target is {} , origin/{branch} is at {} — atlas build to refresh{RESET}",
            short(&commit),
            short(&tip)
        );
    }

    let spec = cfg.spec(true);
    ensure_image(&spec);
    warn_if_secrets_unpushed(cfg);
    let name = start_name(cfg, slug);

    // Fresh container and a fresh serve mapping.
    ssh_ok(&format!("docker rm -f {name} >/dev/null 2>&1"));
    serve_off(cfg, slug, "start");

    let run = format!(
        "{prologue}docker run -d --name {name} --network host --restart unless-stopped $envf \
         -e npm_config_cache=/cache/npm -e HOST=0.0.0.0 -e PORT={port} \
         -v \"$HOME/{wt}\":/build -v \"$HOME/{cache}\":/cache \
         -v \"$HOME/{repo}\":\"$HOME/{repo}\" \
         -w {wd} {tag} sh -c {cmd} >/dev/null",
        prologue = env_file_prologue(cfg),
        port = cfg.port,
        wt = cfg.wt_dir(slug),
        cache = cfg.cache_dir(),
        repo = cfg.repo_dir(),
        wd = cfg.workdir(),
        tag = spec.tag,
        cmd = crate::ssh::shq(&cfg.start_cmd()),
    );
    if !ssh_ok(&run) {
        eprintln!("{RED}start failed{RESET}");
        exit(1);
    }
    println!(
        "{GREEN}✓ {} is running{RESET}  {DIM}({branch} @ {}){RESET}",
        cfg.name,
        short(&commit)
    );
    match tailnet_host() {
        Some(host) => {
            let port = tailnet_port(&port_key(cfg, slug, "start"));
            if ssh_ok(&format!(
                "sudo tailscale serve --bg --https={port} http://127.0.0.1:{app} >/dev/null",
                app = cfg.port
            )) {
                println!("  {GREEN}https://{host}:{port}{RESET}");
            }
        }
        None => println!("{DIM}  no tailnet host set — reachable only on atlas itself{RESET}"),
    }
    println!("{DIM}  logs:  atlas start logs   ·   stop:  atlas start stop{RESET}");
}

fn start_stop(cfg: &BuildCfg, slug: &str, branch: &str) {
    ssh_ok(&format!(
        "docker rm -f {} >/dev/null 2>&1",
        start_name(cfg, slug)
    ));
    serve_off(cfg, slug, "start");
    println!("{GREEN}stopped{RESET} ({} @ {branch})", cfg.name);
}

fn start_logs(cfg: &BuildCfg, slug: &str) -> ! {
    let err = Command::new("ssh")
        .args([
            "-t",
            ssh_host(),
            &format!("docker logs -f {}", start_name(cfg, slug)),
        ])
        .exec();
    eprintln!("ssh: {err}");
    exit(1);
}

fn start_status(cfg: &BuildCfg, slug: &str, branch: &str) {
    let commit = state_field(cfg, slug, "commit");
    if commit.is_empty() {
        println!("{DIM}no target for '{branch}'{RESET}");
        let have = built_branches(cfg);
        if !have.is_empty() {
            println!("{DIM}  built: {}{RESET}", have.join(", "));
        }
        return;
    }
    let built = state_field(cfg, slug, "built_at");
    let running = ssh_capture(&format!(
        "docker inspect -f '{{{{.State.Running}}}}' {} 2>/dev/null",
        start_name(cfg, slug)
    ));
    println!("{}  {branch} @ {}", cfg.name, short(&commit));
    println!(
        "  built:    {}",
        if built.is_empty() { "?".into() } else { built }
    );
    println!(
        "  running:  {}",
        if running.trim() == "true" {
            "yes"
        } else {
            "no"
        }
    );
    if let Some(tip) = remote_tip(cfg, branch)
        && tip != commit
    {
        println!(
            "  {DIM}stale — origin/{branch} is at {}{RESET}",
            short(&tip)
        );
    }
}
