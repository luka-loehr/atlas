//! Runtime configuration (addresses, MAC, API URL) plus `atlas migrate`.

use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::exit;
use std::sync::OnceLock;

use crate::{DIM, GREEN, RED, RESET};

/// Placeholder MAC — set ATLAS_WOL_MAC to your server's real MAC for `boot`.
const DEFAULT_WOL_MAC: &str = "aa:bb:cc:dd:ee:ff";
/// Placeholder tailnet address — set ATLAS_TAILNET_ADDR to the real
/// `<host>.<tailnet>.ts.net:22`. Without it the tailnet ssh route is skipped
/// and `atlas dev` has no host to publish its URL on.
const DEFAULT_TAILNET_ADDR: &str = "atlas.your-tailnet.ts.net:22";

/// Runtime configuration. Every value resolves from, in order: a real
/// environment variable, the optional file `~/.config/atlas/env` (plain
/// KEY=VALUE lines, '#' comments), then a generic built-in default.
pub(crate) struct Config {
    pub(crate) ssh_host: String, // ATLAS_SSH_HOST — ssh/rsync host (~/.ssh/config alias)
    pub(crate) wol_mac: [u8; 6], // ATLAS_WOL_MAC — server NIC MAC for Wake-on-LAN
    pub(crate) wol_mac_is_default: bool,
    pub(crate) wol_broadcast: String, // ATLAS_WOL_BROADCAST — WoL broadcast addr:port
    pub(crate) lan_addr: String,      // ATLAS_LAN_ADDR — LAN ssh route host:port ("" = skip)
    pub(crate) tailnet_addr: String, // ATLAS_TAILNET_ADDR — tailnet ssh route host:port ("" = skip)
    pub(crate) api_url: String,      // ATLAS_API_URL — atlas-api host:port
}

pub(crate) fn config() -> &'static Config {
    static CFG: OnceLock<Config> = OnceLock::new();
    CFG.get_or_init(Config::load)
}

/// The ssh/rsync host (ATLAS_SSH_HOST, default "atlas").
pub(crate) fn ssh_host() -> &'static str {
    &config().ssh_host
}

/// The host part of ATLAS_TAILNET_ADDR ("<host>.<tailnet>.ts.net:22" → the
/// name without the ssh port), or None when the route is switched off or the
/// value is still the shipped placeholder. `atlas dev` builds its URL from
/// this, so a machine that never configured the tailnet gets the tunnel.
pub(crate) fn tailnet_host() -> Option<&'static str> {
    let host = host_of(&config().tailnet_addr);
    if host.is_empty() || host == host_of(DEFAULT_TAILNET_ADDR) {
        None
    } else {
        Some(host)
    }
}

/// "host:port" → "host" (a bare "host" is returned unchanged).
pub(crate) fn host_of(addr: &str) -> &str {
    addr.rsplit_once(':').map_or(addr, |(h, _)| h)
}

impl Config {
    fn load() -> Config {
        let file = env_file_vars();
        // real env vars win over the config file, the file over the default
        let get = |key: &str, default: &str| -> String {
            env::var(key)
                .ok()
                .or_else(|| file.get(key).cloned())
                .unwrap_or_else(|| default.into())
        };
        let mac_str = get("ATLAS_WOL_MAC", DEFAULT_WOL_MAC);
        let Some(wol_mac) = parse_mac(&mac_str) else {
            eprintln!("{RED}ATLAS_WOL_MAC invalid:{RESET} {mac_str} (format: aa:bb:cc:dd:ee:ff)");
            exit(1);
        };
        let tailnet_addr = get("ATLAS_TAILNET_ADDR", DEFAULT_TAILNET_ADDR);
        // ATLAS_API_URL defaults to the tailnet host with the API's port 8787
        let tailnet_host = host_of(&tailnet_addr);
        let api_default = if tailnet_host.is_empty() {
            String::new()
        } else {
            format!("{tailnet_host}:8787")
        };
        Config {
            ssh_host: get("ATLAS_SSH_HOST", "atlas"),
            wol_mac,
            wol_mac_is_default: mac_str == DEFAULT_WOL_MAC,
            wol_broadcast: get("ATLAS_WOL_BROADCAST", "192.168.1.255:9"),
            lan_addr: get("ATLAS_LAN_ADDR", "192.168.1.100:22"),
            api_url: get("ATLAS_API_URL", &api_default),
            tailnet_addr,
        }
    }
}

/// Optional config file `~/.config/atlas/env`: plain KEY=VALUE lines, lines
/// starting with '#' are comments, surrounding quotes around values are
/// stripped. Keeps personal addresses out of shell profiles and the repo.
fn env_file_vars() -> HashMap<String, String> {
    let mut vars = HashMap::new();
    let Ok(home) = env::var("HOME") else {
        return vars;
    };
    let Ok(text) = fs::read_to_string(Path::new(&home).join(".config/atlas/env")) else {
        return vars;
    };
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let v = v.trim();
        let v = v
            .strip_prefix('"')
            .and_then(|s| s.strip_suffix('"'))
            .or_else(|| v.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')))
            .unwrap_or(v);
        vars.insert(k.trim().to_string(), v.to_string());
    }
    vars
}

/// Parse a colon-separated MAC like "aa:bb:cc:dd:ee:ff".
pub(crate) fn parse_mac(s: &str) -> Option<[u8; 6]> {
    let mut mac = [0u8; 6];
    let mut n = 0;
    for part in s.split(':') {
        if n == 6 {
            return None;
        }
        mac[n] = u8::from_str_radix(part, 16).ok()?;
        n += 1;
    }
    (n == 6).then_some(mac)
}

/// `atlas migrate [--force]` — convert a `.atlas-build.toml` config file to
/// `atlas.toml` for the current project (walk-up), then remove the source
/// file. The conversion preserves every key and value and prepends one
/// provenance comment. The CLI only ever reads
/// `atlas.toml`, so this is the only way a stray `.atlas-build.toml` becomes
/// usable.
pub(crate) fn migrate(argv: &[String]) {
    let force = argv.iter().any(|a| a == "--force");
    let cwd = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));

    // Walk up: the first dir that has either config file wins.
    let mut dir = cwd.clone();
    let found = loop {
        if dir.join("atlas.toml").is_file() || dir.join(".atlas-build.toml").is_file() {
            break dir.clone();
        }
        if !dir.pop() {
            eprintln!(
                "{RED}no atlas.toml or .atlas-build.toml found{RESET} (here or in a parent directory)"
            );
            exit(1);
        }
    };

    let atlas = found.join("atlas.toml");
    let legacy = found.join(".atlas-build.toml");

    if atlas.is_file() && !force {
        println!("atlas.toml already present");
        return;
    }
    if !legacy.is_file() {
        eprintln!(
            "{RED}no .atlas-build.toml to migrate{RESET} (in {})",
            found.display()
        );
        exit(1);
    }
    let content = match fs::read_to_string(&legacy) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{RED}cannot read {}{RESET}: {e}", legacy.display());
            exit(1);
        }
    };
    let out = format!("# migrated from .atlas-build.toml by 'atlas migrate'\n{content}");

    if atlas.is_file() && force {
        let existing = fs::read_to_string(&atlas).unwrap_or_default();
        if existing != out {
            eprintln!(
                "{DIM}note: overwriting existing atlas.toml from .atlas-build.toml (--force){RESET}"
            );
        }
    }
    if let Err(e) = fs::write(&atlas, &out) {
        eprintln!("{RED}cannot write {}{RESET}: {e}", atlas.display());
        exit(1);
    }
    // The CLI never reads .atlas-build.toml — remove it so it cannot go
    // silently stale next to the atlas.toml.
    let removed = fs::remove_file(&legacy).is_ok();
    if removed {
        println!("{GREEN}✓{RESET} wrote atlas.toml, removed .atlas-build.toml");
    } else {
        println!("{GREEN}✓{RESET} wrote atlas.toml (could not remove .atlas-build.toml — delete it manually)");
    }
}
