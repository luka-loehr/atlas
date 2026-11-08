//! Reading `atlas.toml`: found by walking up from the working directory (or
//! at `--path`), a flat key list plus `[target.NAME]` sections, validated.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::exit;

use super::names::{join_dir, repo_subdir, repo_url, valid_health, valid_name, valid_rel_path};
use super::{BuildCfg, IMAGE_KEYS};
use crate::hash::repo_hash_of;
use crate::{DIM, RED, RESET};

/// Ports of atlas' own services on the box (ssh, Caddy and its admin API,
/// Postgres, llama.cpp, atlas-ml, atlas-server). A project on one of them
/// would have `atlas dev --public` or `tailscale serve` publish that service.
const RESERVED_PORTS: [u16; 7] = [22, 2019, 5432, 8080, 8785, 8786, 8787];

/// Walk up from cwd to find the config and parse it.
pub(crate) fn load_config() -> BuildCfg {
    load_config_selected(None, None)
}

/// Load the config for `atlas build`, honoring `--path` and `--target`.
pub(crate) fn load_config_at(sub: Option<&str>, target: Option<&str>) -> BuildCfg {
    load_config_selected(sub, target)
}

/// Locate the `atlas.toml` config file. Returns (file, scoped).
///
/// `atlas.toml` is the only filename the CLI looks for; a `.atlas-build.toml`
/// is never read as a fallback — `atlas migrate` converts one to `atlas.toml`.
fn resolve_config_file(sub: Option<&str>, cwd: &Path) -> (PathBuf, bool) {
    match sub {
        Some(p) => {
            let d = cwd.join(p);
            if !d.is_dir() {
                eprintln!("{RED}--path: not a directory{RESET} ({p})");
                exit(1);
            }
            let a = d.join("atlas.toml");
            if a.is_file() {
                return (a, true);
            }
            eprintln!("{RED}--path {p}: no atlas.toml there{RESET}");
            eprintln!(
                "{DIM}  --path D expects D as its own build target with its own atlas.toml{RESET}"
            );
            exit(1);
        }
        None => {
            let mut dir = cwd.to_path_buf();
            loop {
                let a = dir.join("atlas.toml");
                if a.is_file() {
                    return (a, false);
                }
                if !dir.pop() {
                    eprintln!("{RED}no atlas.toml found{RESET} (here or in a parent directory)");
                    exit(1);
                }
            }
        }
    }
}

fn load_config_selected(sub: Option<&str>, target: Option<&str>) -> BuildCfg {
    let cwd = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let (file, scoped) = resolve_config_file(sub, &cwd);
    let cfg_dir = file.parent().unwrap_or(Path::new(".")).to_path_buf();
    let text = fs::read_to_string(&file).unwrap_or_default();
    let (top, targets) = parse_sections(&text);

    // Resolve which key/value set applies: a chosen [target.T], or the flat top
    // level. A file with targets demands one be named; a --target against a flat
    // file is a mistake worth catching, not ignoring.
    let names: Vec<String> = targets.iter().map(|(n, _)| n.clone()).collect();
    let chosen: Vec<(String, String)> = if !targets.is_empty() {
        let want = match target {
            Some(t) => t,
            None => {
                eprintln!("{RED}this config has targets{RESET} — atlas build --target <name>");
                eprintln!("{DIM}  available: {}{RESET}", names.join(", "));
                exit(1);
            }
        };
        let Some((_, kvs)) = targets.iter().find(|(n, _)| n == want) else {
            eprintln!("{RED}no target '{want}'{RESET}");
            eprintln!("{DIM}  available: {}{RESET}", names.join(", "));
            exit(1);
        };
        top.iter().cloned().chain(kvs.iter().cloned()).collect()
    } else {
        if let Some(t) = target {
            eprintln!("{RED}--target {t}: this config has no targets{RESET}");
            exit(1);
        }
        top.clone()
    };

    let mut c = BuildCfg {
        root: cfg_dir.clone(),
        name: String::new(),
        repo_hash: String::new(),
        canonical_url: String::new(),
        image: String::new(),
        dir: ".".into(),
        build: String::new(),
        test: String::new(),
        dev: String::new(),
        start: String::new(),
        install: String::new(),
        repo: String::new(),
        port: 3000,
        artifacts: Vec::new(),
        health: "/".into(),
    };
    // Top level first (shared defaults), then the target's own keys win.
    let base_had_name = top.iter().any(|(k, _)| k == "name");
    for (k, v) in &chosen {
        apply_kv(&mut c, k, v);
    }
    // A target without its own name inherits "<repo>-<target>", so each gets a
    // distinct remote dir + cache instead of clobbering the shared one.
    if let Some(t) = target {
        let target_set_name = targets
            .iter()
            .find(|(n, _)| n == t)
            .map(|(_, kvs)| kvs.iter().any(|(k, _)| k == "name"))
            .unwrap_or(false);
        if !target_set_name && base_had_name {
            c.name = format!("{}-{t}", c.name);
        }
    }

    // `--path D` makes D the build root, expressed relative to the repo root.
    if scoped {
        let prefix = repo_subdir(&cfg_dir);
        c.dir = join_dir(&prefix, &c.dir);
    }

    if c.name.is_empty() || c.image.is_empty() {
        eprintln!("{RED}config incomplete{RESET} (name, image required)");
        exit(1);
    }
    if !valid_name(&c.name) {
        eprintln!("{RED}config: invalid name{RESET} (allowed: A-Za-z0-9._-)");
        exit(1);
    }
    if !IMAGE_KEYS.contains(&c.image.as_str()) {
        eprintln!(
            "{RED}config: unknown image '{}'{RESET} (allowed: {})",
            c.image,
            IMAGE_KEYS.join(" | ")
        );
        exit(1);
    }
    if c.dir != "." && !valid_rel_path(&c.dir) {
        eprintln!("{RED}config: invalid dir{RESET} (relative path without '..')");
        exit(1);
    }
    for a in &c.artifacts {
        if !valid_rel_path(a) {
            eprintln!("{RED}config: invalid artifact '{a}'{RESET} (relative path without '..')");
            exit(1);
        }
    }
    if !valid_health(&c.health) {
        eprintln!(
            "{RED}config: invalid health '{}'{RESET} (must start with '/', no whitespace)",
            c.health
        );
        exit(1);
    }

    // Resolve the canonical URL once and derive the deterministic project hash
    // from it. Every remote path is keyed on this, so it is computed here and
    // cached on the config instead of per-call.
    c.canonical_url = repo_url(&c);
    c.repo_hash = repo_hash_of(&c.canonical_url);
    c
}

/// Minimal TOML value handling: strips surrounding quotes and inline
/// `# comments` (the file is a flat key=value list, no full TOML needed).
pub(crate) fn parse_toml_value(raw: &str) -> String {
    let raw = raw.trim();
    for q in ['"', '\''] {
        if let Some(rest) = raw.strip_prefix(q)
            && let Some(end) = rest.find(q)
        {
            return rest[..end].to_string();
        }
    }
    let end = raw.find('#').unwrap_or(raw.len());
    raw[..end].trim().to_string()
}

/// A single `key = value` pair.
type Kv = (String, String);
/// The flat top-level keys and the ordered `[target.NAME]` sections of a config.
type Sections = (Vec<Kv>, Vec<(String, Vec<Kv>)>);

/// Split a config into its flat top-level keys and any `[target.NAME]` sections,
/// preserving order so later keys win.
pub(crate) fn parse_sections(text: &str) -> Sections {
    let mut top: Vec<Kv> = Vec::new();
    let mut targets: Vec<(String, Vec<Kv>)> = Vec::new();
    let mut cur: Option<usize> = None;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(inner) = line.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
            let Some(name) = inner.trim().strip_prefix("target.") else {
                eprintln!("{RED}config: only [target.NAME] is supported{RESET} ({line})");
                exit(1);
            };
            let name = name.trim().to_string();
            if !valid_name(&name) {
                eprintln!("{RED}config: invalid target name{RESET} ({name})");
                exit(1);
            }
            targets.push((name, Vec::new()));
            cur = Some(targets.len() - 1);
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let kv = (k.trim().to_string(), parse_toml_value(v));
        match cur {
            None => top.push(kv),
            Some(i) => targets[i].1.push(kv),
        }
    }
    (top, targets)
}

/// Apply one config key to the builder. Shared by the top-level pass and each
/// target section, so both understand exactly the same keys.
pub(crate) fn apply_kv(c: &mut BuildCfg, k: &str, v: &str) {
    let v = v.to_string();
    match k {
        "name" => c.name = v,
        "image" => c.image = v,
        "dir" => c.dir = v,
        "build" => c.build = v,
        "test" => c.test = v,
        "dev" => c.dev = v,
        "start" => c.start = v,
        "install" => c.install = v,
        "repo" => c.repo = v,
        "health" => c.health = v,
        "port" => {
            c.port = v.parse().unwrap_or_else(|_| {
                eprintln!("{RED}config: invalid port{RESET} ({v})");
                exit(1);
            });
            if RESERVED_PORTS.contains(&c.port) {
                eprintln!(
                    "{RED}config: port {} belongs to atlas itself{RESET} (a public or tailnet URL would expose it)",
                    c.port
                );
                exit(1);
            }
        }
        "artifacts" => c.artifacts = v.split_whitespace().map(String::from).collect(),
        _ => {}
    }
}
