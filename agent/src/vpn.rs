//! Exit-node / VPN stats for the app's tunnel page.
//!
//! `tailscale status --json` gives the live picture (exit-node offer, peers,
//! per-peer transfer counters). A background sampler accumulates the durable
//! numbers — seconds with real tunnel traffic and total bytes moved — into
//! ~/.local/share/atlas-agent/vpn.json so they survive agent restarts.
//! Ads-blocked counts come from a local AdGuard Home, if one is running.

use std::fs;
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::actions::{extract_num, extract_str};
use crate::metrics::json_str;

const SAMPLE_S: u64 = 30;
/// bytes per sample interval that count as "someone is using the tunnel"
const ACTIVE_BYTES: u64 = 100_000;
const ADGUARD_URL: &str = "http://127.0.0.1:3053";

#[derive(Clone, Copy, Default)]
struct State {
    since: u64,      // unix ts the accumulation started
    tunnel_s: u64,   // seconds with real tunnel traffic
    bytes: u64,      // total bytes moved through the tailnet (rx+tx)
    last_total: u64, // last raw counter sum (tailscaled resets on restart)
}

static STATE: Mutex<State> = Mutex::new(State {
    since: 0,
    tunnel_s: 0,
    bytes: 0,
    last_total: 0,
});

fn state_path() -> String {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/atlas".into());
    format!("{home}/.local/share/atlas-agent/vpn.json")
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn load_state() -> State {
    let text = fs::read_to_string(state_path()).unwrap_or_default();
    State {
        since: extract_num(&text, "since").unwrap_or(now() as f64) as u64,
        tunnel_s: extract_num(&text, "tunnel_s").unwrap_or(0.0) as u64,
        bytes: extract_num(&text, "bytes").unwrap_or(0.0) as u64,
        last_total: extract_num(&text, "last_total").unwrap_or(0.0) as u64,
    }
}

fn save_state(s: &State) {
    let path = state_path();
    if let Some(dir) = std::path::Path::new(&path).parent() {
        let _ = fs::create_dir_all(dir);
    }
    let _ = fs::write(
        &path,
        format!(
            "{{\"since\":{},\"tunnel_s\":{},\"bytes\":{},\"last_total\":{}}}\n",
            s.since, s.tunnel_s, s.bytes, s.last_total
        ),
    );
}

fn tailscale_json() -> String {
    Command::new("tailscale")
        .args(["status", "--json"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

fn extract_bool(text: &str, key: &str) -> Option<bool> {
    let pat = format!("\"{key}\"");
    let i = text.find(&pat)? + pat.len();
    let rest = text[i..].trim_start_matches(|c: char| c == ':' || c.is_whitespace());
    if rest.starts_with("true") {
        Some(true)
    } else if rest.starts_with("false") {
        Some(false)
    } else {
        None
    }
}

/// The `"Peer"` map, split into one text chunk per peer. Splitting on the
/// map keys also cuts at each object's inner `"PublicKey":"nodekey:…"` —
/// keep only the chunks that carry the actual fields.
fn peer_chunks(status: &str) -> Vec<&str> {
    let Some(i) = status.find("\"Peer\"") else {
        return Vec::new();
    };
    let peers = &status[i..];
    peers
        .split("\"nodekey:")
        .skip(1)
        .filter(|c| c.contains("\"HostName\""))
        .collect()
}

fn peer_traffic_total(status: &str) -> u64 {
    peer_chunks(status)
        .iter()
        .map(|c| {
            extract_num(c, "RxBytes").unwrap_or(0.0) as u64
                + extract_num(c, "TxBytes").unwrap_or(0.0) as u64
        })
        .sum()
}

/// Background accumulator: every 30 s, credit traffic deltas to the counters.
pub fn start_sampler() {
    std::thread::spawn(|| {
        let mut prime = false;
        {
            let mut st = STATE.lock().unwrap();
            *st = load_state();
            if st.since == 0 {
                st.since = now();
                prime = true; // fresh state: baseline the counters, don't
                              // credit tailscaled's whole history at once
            }
        }
        loop {
            let status = tailscale_json();
            if !status.is_empty() {
                let total = peer_traffic_total(&status);
                let mut st = STATE.lock().unwrap();
                if prime {
                    prime = false;
                    st.last_total = total;
                    save_state(&st);
                    drop(st);
                    std::thread::sleep(Duration::from_secs(SAMPLE_S));
                    continue;
                }
                // counters reset when tailscaled restarts
                let delta = if total >= st.last_total {
                    total - st.last_total
                } else {
                    total
                };
                st.last_total = total;
                if delta > 0 {
                    st.bytes += delta;
                }
                if delta > ACTIVE_BYTES {
                    st.tunnel_s += SAMPLE_S;
                }
                save_state(&st);
            }
            std::thread::sleep(Duration::from_secs(SAMPLE_S));
        }
    });
}

/// AdGuard Home stats (`{"ok":false}` if none is running). AdGuard insists
/// on an admin user — the agent reads `ATLAS_ADGUARD_AUTH=user:pass` from
/// its env file for basic auth.
fn adguard() -> String {
    let mut args: Vec<String> = vec!["-s".into(), "-m".into(), "3".into()];
    if let Ok(auth) = std::env::var("ATLAS_ADGUARD_AUTH") {
        if !auth.is_empty() {
            args.push("-u".into());
            args.push(auth);
        }
    }
    args.push(format!("{ADGUARD_URL}/control/stats"));
    let out = Command::new("curl")
        .args(&args)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    if !out.contains("num_dns_queries") {
        return r#"{"ok":false}"#.into();
    }
    let queries = extract_num(&out, "num_dns_queries").unwrap_or(0.0);
    let blocked = extract_num(&out, "num_blocked_filtering").unwrap_or(0.0);
    let avg_ms = extract_num(&out, "avg_processing_time").unwrap_or(0.0) * 1000.0;
    format!(
        "{{\"ok\":true,\"queries\":{:.0},\"blocked\":{:.0},\"avg_ms\":{:.1}}}",
        queries, blocked, avg_ms
    )
}

/// GET /api/vpn — everything the exit-node page needs in one call.
pub fn vpn() -> String {
    let status = tailscale_json();
    if status.is_empty() {
        return r#"{"error":"tailscale not available"}"#.into();
    }
    let self_end = status.find("\"Peer\"").unwrap_or(status.len());
    let self_part = &status[..self_end];

    let backend = extract_str(self_part, "BackendState").unwrap_or_default();
    let version = extract_str(self_part, "Version")
        .unwrap_or_default()
        .split('-')
        .next()
        .unwrap_or("")
        .to_string();
    let exit_node = extract_bool(self_part, "ExitNodeOption").unwrap_or(false);
    let self_dns = extract_str(self_part, "DNSName")
        .unwrap_or_default()
        .trim_end_matches('.')
        .to_string();

    let peers: Vec<String> = peer_chunks(&status)
        .iter()
        .map(|c| {
            format!(
                "{{\"host\":\"{}\",\"os\":\"{}\",\"online\":{},\"active\":{},\"rx\":{:.0},\"tx\":{:.0},\"last_seen\":\"{}\"}}",
                json_str(&extract_str(c, "HostName").unwrap_or_default()),
                json_str(&extract_str(c, "OS").unwrap_or_default()),
                extract_bool(c, "Online").unwrap_or(false),
                extract_bool(c, "Active").unwrap_or(false),
                extract_num(c, "RxBytes").unwrap_or(0.0),
                extract_num(c, "TxBytes").unwrap_or(0.0),
                json_str(&extract_str(c, "LastSeen").unwrap_or_default()),
            )
        })
        .collect();

    let st = *STATE.lock().unwrap();
    format!(
        "{{\"backend\":\"{}\",\"version\":\"{}\",\"exit_node\":{},\"self_dns\":\"{}\",\"since\":{},\"tunnel_s\":{},\"bytes\":{},\"adguard\":{},\"peers\":[{}]}}",
        json_str(&backend),
        json_str(&version),
        exit_node,
        json_str(&self_dns),
        st.since,
        st.tunnel_s,
        st.bytes,
        adguard(),
        peers.join(",")
    )
}
