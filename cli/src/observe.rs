//! The observe surface: ls, logs, health, open, doctor, info, watch.

use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, exit};
use std::thread::sleep;
use std::time::{Duration, Instant, UNIX_EPOCH};

use crate::build::{take_branch, take_build_flags};
use crate::config::{ssh_host, tailnet_host};
use crate::git::git_toplevel;
use crate::project::{
    BuildCfg, host_label, load_config, load_config_at, slug_of, valid_host_label,
};
use crate::serve::{port_key, serve_url, start_name, tailnet_port};
use crate::ssh::{probe, ssh_capture, ssh_ok};
use crate::state::built_branches;
use crate::web::{caddy_admin_ok, caddy_route_hosts, tunnel_active, wildcard_dns_ok};
use crate::{DIM, GREEN, RED, RESET};

// The scan/exclude set shared with sync_local and used by `watch`.
const EXCLUDES: [&str; 5] = [".git", "node_modules", "target", ".next", "build"];

// ---- ls -------------------------------------------------------------------

/// Fleet overview of every project under ~/atlas-builds.
pub(crate) fn ls() {
    let emitter = r#"cd "$HOME/atlas-builds" 2>/dev/null || exit 0
for d in */; do d=${d%/}; [ "$d" = ".cache-universal" -o "$d" = ".cache-mobile" ] && continue
  [ -f "$d/meta.json" ] || [ -d "$d/state" ] || continue
  name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p' "$d/meta.json" 2>/dev/null); [ -z "$name" ] && name="$d"
  hash=$(sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' "$d/meta.json" 2>/dev/null)
  br=$(ls "$d/state" 2>/dev/null | sed 's/\.json$//' | tr '\n' ',' | sed 's/,$//')
  run=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "^atlas-(dev|start)-$name-$hash-" | sed -E "s/^atlas-(dev|start)-$name-$hash-/\1:/" | tr '\n' ',' | sed 's/,$//')
  disk=$(du -sh "$d" 2>/dev/null | cut -f1)
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$hash" "$br" "$run" "$disk"
done"#;
    let out = ssh_capture(emitter);
    let lines: Vec<&str> = out.lines().filter(|l| !l.trim().is_empty()).collect();
    if lines.is_empty() {
        println!("no projects on atlas");
        return;
    }
    let hosts = caddy_route_hosts();

    struct Row {
        name: String,
        hash: String,
        built: String,
        running: String,
        url: String,
        disk: String,
    }
    let mut rows: Vec<Row> = Vec::new();
    for line in lines {
        let f: Vec<&str> = line.split('\t').collect();
        let name = f.first().copied().unwrap_or("").to_string();
        let hash = f.get(1).copied().unwrap_or("").to_string();
        let built = slugs_to_branches(f.get(2).copied().unwrap_or(""));
        let running = f.get(3).copied().unwrap_or("").replace(',', " ");
        let disk = f.get(4).copied().unwrap_or("").to_string();
        let url = public_url_for(&name, &hosts).unwrap_or_else(|| "—".to_string());
        rows.push(Row {
            name,
            hash: if hash.is_empty() { "?".into() } else { hash },
            built: if built.is_empty() {
                "—".into()
            } else {
                built
            },
            running: if running.trim().is_empty() {
                "—".into()
            } else {
                running
            },
            url,
            disk: if disk.is_empty() { "?".into() } else { disk },
        });
    }

    let w = |sel: &dyn Fn(&Row) -> &str, head: &str| -> usize {
        rows.iter()
            .map(|r| sel(r).len())
            .chain(std::iter::once(head.len()))
            .max()
            .unwrap_or(0)
    };
    let wn = w(&|r| &r.name, "PROJECT");
    let wh = w(&|r| &r.hash, "HASH");
    let wb = w(&|r| &r.built, "BUILT");
    let wr = w(&|r| &r.running, "RUNNING");
    let wu = w(&|r| &r.url, "URL");
    println!(
        "{:<wn$}  {:<wh$}  {:<wb$}  {:<wr$}  {:<wu$}  DISK",
        "PROJECT", "HASH", "BUILT", "RUNNING", "URL"
    );
    for r in &rows {
        println!(
            "{:<wn$}  {:<wh$}  {:<wb$}  {:<wr$}  {:<wu$}  {}",
            r.name, r.hash, r.built, r.running, r.url, r.disk
        );
    }
}

fn slugs_to_branches(csv: &str) -> String {
    csv.split(',')
        .filter(|s| !s.is_empty())
        .map(crate::project::branch_of_slug)
        .collect::<Vec<_>>()
        .join(", ")
}

/// The public host for a project name, if Caddy currently routes one.
fn public_url_for(name: &str, hosts: &[String]) -> Option<String> {
    let exact = format!("{name}.lukaloehr.com");
    let prefix = format!("{name}-");
    hosts
        .iter()
        .find(|h| **h == exact || (h.starts_with(&prefix) && h.ends_with(".lukaloehr.com")))
        .map(|h| format!("https://{h}"))
}

// ---- logs -----------------------------------------------------------------

pub(crate) fn logs(argv: &[String]) {
    let (branch, rest) = take_branch(argv);
    let slug = slug_of(&branch);
    let cfg = load_config();
    let follow = rest.iter().any(|a| a == "--follow" || a == "-f");
    let want_dev = rest.iter().any(|a| a == "--dev");
    let want_start = rest.iter().any(|a| a == "--start");

    let dev = format!("atlas-dev-{}-{slug}", cfg.slug_id());
    let start = start_name(&cfg, &slug);
    let dev_up = container_running(&dev);
    let start_up = container_running(&start);

    let container = if want_dev {
        dev.clone()
    } else if want_start {
        start.clone()
    } else if dev_up {
        dev.clone()
    } else if start_up {
        start.clone()
    } else {
        dev.clone()
    };

    if !ssh_ok(&format!("docker inspect {container} >/dev/null 2>&1")) {
        eprintln!(
            "{RED}no dev/start container for {} @ {branch}{RESET} — atlas dev | atlas start",
            cfg.name
        );
        exit(1);
    }

    if follow {
        let err = Command::new("ssh")
            .args(["-t", ssh_host(), &format!("docker logs -f {container}")])
            .exec();
        eprintln!("ssh: {err}");
        exit(1);
    }
    Command::new("ssh")
        .args([ssh_host(), &format!("docker logs --tail 200 {container}")])
        .status()
        .ok();
}

fn container_running(name: &str) -> bool {
    ssh_ok(&format!("docker ps -q --filter name=^{name}$ | grep -q ."))
}

// ---- health ---------------------------------------------------------------

pub(crate) fn health(argv: &[String]) {
    let (branch, rest) = take_branch(argv);
    let slug = slug_of(&branch);
    let local = rest.iter().any(|a| a == "--local");
    let cfg = load_config();
    let path = &cfg.health;

    if local {
        let target = format!("http://127.0.0.1:{}{path}", cfg.port);
        let code = ssh_capture(&format!(
            "curl -sS -o /dev/null -m 5 -w '%{{http_code}}' {target} 2>/dev/null"
        ));
        report_health(code.trim(), &target);
    } else {
        let Some(url) = resolve_url(&cfg, &slug) else {
            eprintln!("{RED}nothing running for {} @ {branch}{RESET}", cfg.name);
            exit(1);
        };
        let target = format!("{url}{path}");
        let out = Command::new("curl")
            .args([
                "-sS",
                "-o",
                "/dev/null",
                "-m",
                "5",
                "-w",
                "%{http_code}",
                &target,
            ])
            .output();
        let code = out
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();
        report_health(&code, &target);
    }
}

fn report_health(code: &str, target: &str) {
    let n: u32 = code.parse().unwrap_or(0);
    if (200..=399).contains(&n) {
        println!("{GREEN}healthy {n}{RESET}  {target}");
    } else {
        let shown = if code.is_empty() {
            "no response".to_string()
        } else {
            code.to_string()
        };
        eprintln!("{RED}unhealthy {shown}{RESET}  {target}");
        exit(1);
    }
}

// ---- open -----------------------------------------------------------------

pub(crate) fn open(argv: &[String]) {
    let (branch, _rest) = take_branch(argv);
    let slug = slug_of(&branch);
    let cfg = load_config();
    let Some(url) = resolve_url(&cfg, &slug) else {
        eprintln!("{RED}nothing running for {} @ {branch}{RESET}", cfg.name);
        exit(1);
    };
    println!("{DIM}{url}{RESET}");
    Command::new("open").arg(&url).status().ok();
}

/// The dev URL if any, else the started-build tailnet URL.
fn resolve_url(cfg: &BuildCfg, slug: &str) -> Option<String> {
    crate::dev::dev_url(cfg, slug).or_else(|| serve_url(cfg, slug, "start"))
}

// ---- doctor ---------------------------------------------------------------

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

    let dns = wildcard_dns_ok();
    add(
        if dns { St::Pass } else { St::Warn },
        "wildcard DNS",
        if dns {
            "resolves".into()
        } else {
            "unresolved".into()
        },
    );

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

// ---- info -----------------------------------------------------------------

pub(crate) fn info() {
    let cfg = load_config();
    let slug = "main";
    let label = host_label(&cfg, slug);
    let public = if valid_host_label(&label) {
        format!("https://{label}.lukaloehr.com")
    } else {
        format!("(invalid host label from name '{}')", cfg.name)
    };

    println!("{:<12}{}", "name", cfg.name);
    println!("{:<12}{}", "repo", cfg.canonical_url);
    println!("{:<12}{}", "hash", cfg.repo_hash);
    println!("{:<12}~/{}", "remote dir", cfg.base_dir());
    println!("{:<12}{}", "image", cfg.image);
    println!("{:<12}{}   health {}", "port", cfg.port, cfg.health);
    println!("{:<12}{}        {DIM}(public){RESET}", "dev url", public);
    if let Some(host) = tailnet_host() {
        let port = tailnet_port(&port_key(&cfg, slug, "dev"));
        println!("{:<12}https://{host}:{port}   {DIM}(tailnet){RESET}", "");
    }

    let built = built_branches(&cfg);
    println!(
        "{:<12}{}",
        "built",
        if built.is_empty() {
            "—".into()
        } else {
            built.join(", ")
        }
    );

    let hashed = cfg.secrets_file();
    let legacy = cfg.legacy_secrets_file();
    let has_hashed = ssh_ok(&format!("test -f \"$HOME/{hashed}\""));
    let has_legacy = !has_hashed && ssh_ok(&format!("test -f \"$HOME/{legacy}\""));
    if has_hashed {
        println!("{:<12}pushed        {DIM}(~/{hashed}){RESET}", "secrets");
    } else if has_legacy {
        println!(
            "{:<12}pushed (legacy ~/{legacy} — re-push to namespace)",
            "secrets"
        );
    } else {
        println!("{:<12}not pushed", "secrets");
    }
}

// ---- watch ----------------------------------------------------------------

pub(crate) fn watch(argv: &[String]) {
    let flags = take_build_flags(argv);
    let cfg = load_config_at(flags.path.as_deref(), flags.target.as_deref());
    let top = git_toplevel(&cfg.root);

    // Build the child command once: `atlas build --local [--path D] [--target T]`.
    let exe = std::env::current_exe().unwrap_or_else(|_| "atlas".into());
    let mut child_args: Vec<String> = vec!["build".into(), "--local".into()];
    if let Some(p) = &flags.path {
        child_args.push("--path".into());
        child_args.push(p.clone());
    }
    if let Some(t) = &flags.target {
        child_args.push("--target".into());
        child_args.push(t.clone());
    }

    println!(
        "{DIM}watching {} (build --local on change) — Ctrl-C to stop{RESET}",
        top.display()
    );

    let mut last_seen = max_mtime(&top);
    let mut dirty = false;
    let mut last_change = Instant::now();
    loop {
        sleep(Duration::from_millis(400));
        let m = max_mtime(&top);
        if m > last_seen {
            last_seen = m;
            dirty = true;
            last_change = Instant::now();
        }
        if dirty && last_change.elapsed() >= Duration::from_millis(800) {
            dirty = false;
            println!("{DIM}change detected -> build --local{RESET}");
            // Spawn a child so a failing build (which exits non-zero) does not
            // kill the watcher; the normal build output streams through.
            Command::new(&exe).args(&child_args).status().ok();
        }
    }
}

/// Maximum mtime (ms since epoch) of any non-excluded file under `dir`.
fn max_mtime(dir: &Path) -> u64 {
    let mut max = 0u64;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in entries.flatten() {
            let name = e.file_name();
            let name = name.to_string_lossy();
            if EXCLUDES.contains(&name.as_ref()) {
                continue;
            }
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() {
                stack.push(e.path());
            } else if let Ok(md) = e.metadata()
                && let Ok(mt) = md.modified()
                && let Ok(dur) = mt.duration_since(UNIX_EPOCH)
            {
                let ms = dur.as_millis() as u64;
                if ms > max {
                    max = ms;
                }
            }
        }
    }
    max
}
