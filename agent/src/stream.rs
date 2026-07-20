//! Live metrics over WebSocket, backed by a global 10-minute history.
//!
//! A single background sampler thread (start_sampler, spawned at boot) takes
//! one sample every 500ms into a ring buffer of 1200 entries (= 10 min).
//! Each /ws/metrics connection first receives the full buffer as one
//! bootstrap frame {"history":[...]} — so charts never start empty — and is
//! then pushed every new sample as a single live frame:
//!   {"ts_ms":u64,"cpu":pct,"mem":pct,"mem_gb":used,"gpu":pct,
//!    "gpu_mem_mb":f,"rx":u64,"tx":u64}
//!
//! rx/tx are CUMULATIVE byte counters (same interface filter as
//! metrics::net_bytes); the client derives rates. cpu is the /proc/stat
//! total/idle delta between sampler ticks. gpu via nvidia-smi; zeros when
//! unavailable.

use std::collections::VecDeque;
use std::fs;
use std::io::Write;
use std::net::TcpStream;
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tungstenite::handshake::derive_accept_key;
use tungstenite::protocol::Role;
use tungstenite::{Message, WebSocket};

const TICK: Duration = Duration::from_millis(500);
const HISTORY_LEN: usize = 1200; // 10 min at 2 Hz

#[derive(Clone, Copy)]
struct Sample {
    ts_ms: u64,
    cpu: f64,
    mem: f64,
    mem_gb: f64,
    gpu: f64,
    gpu_mem_mb: f64,
    rx: u64,
    tx: u64,
}

fn fmt_sample(s: &Sample) -> String {
    format!(
        "{{\"ts_ms\":{},\"cpu\":{:.1},\"mem\":{:.1},\"mem_gb\":{:.2},\"gpu\":{:.0},\"gpu_mem_mb\":{:.0},\"rx\":{},\"tx\":{}}}",
        s.ts_ms, s.cpu, s.mem, s.mem_gb, s.gpu, s.gpu_mem_mb, s.rx, s.tx
    )
}

fn history() -> &'static Mutex<VecDeque<Sample>> {
    static H: OnceLock<Mutex<VecDeque<Sample>>> = OnceLock::new();
    H.get_or_init(|| Mutex::new(VecDeque::with_capacity(HISTORY_LEN + 1)))
}

/// Spawns the global sampler thread. Call once at agent startup.
pub fn start_sampler() {
    thread::spawn(|| {
        let mut prev = cpu_snap();
        let mut next_tick = Instant::now() + TICK;
        loop {
            let now = Instant::now();
            if next_tick > now {
                thread::sleep(next_tick - now);
                next_tick += TICK;
            } else {
                // a slow tick (e.g. nvidia-smi stall) — don't rapid-fire to catch up
                next_tick = Instant::now() + TICK;
            }

            let cur = cpu_snap();
            let cpu = cpu_pct(prev, cur);
            prev = cur;
            let (mem_pct, mem_gb) = mem();
            let (gpu, gpu_mem_mb) = gpu();
            let (rx, tx) = crate::metrics::net_bytes();
            let ts_ms = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);

            let s = Sample { ts_ms, cpu, mem: mem_pct, mem_gb, gpu, gpu_mem_mb, rx, tx };
            let mut h = history().lock().unwrap();
            h.push_back(s);
            while h.len() > HISTORY_LEN {
                h.pop_front();
            }
        }
    });
}

pub fn handle_ws(mut stream: TcpStream, ws_key: &str) {
    // finish the WebSocket handshake on the already-parsed request
    let accept = derive_accept_key(ws_key.as_bytes());
    let resp = format!(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
    );
    if stream.write_all(resp.as_bytes()).is_err() {
        return;
    }
    let _ = stream.flush();

    let mut ws = WebSocket::from_raw_socket(stream, Role::Server, None);

    // bootstrap: the whole ring buffer in one frame — charts start filled
    let mut last_ts = 0u64;
    {
        let h = history().lock().unwrap();
        let joined: Vec<String> = h.iter().map(fmt_sample).collect();
        if let Some(last) = h.back() {
            last_ts = last.ts_ms;
        }
        drop(h);
        let boot = format!("{{\"history\":[{}]}}", joined.join(","));
        if ws.write_message(Message::Text(boot)).is_err() {
            return;
        }
        let _ = ws.flush();
    }

    // live: push each new sample as the sampler produces it
    loop {
        thread::sleep(Duration::from_millis(150));
        let latest = { history().lock().unwrap().back().copied() };
        let Some(s) = latest else { continue };
        if s.ts_ms == last_ts {
            continue;
        }
        last_ts = s.ts_ms;
        // send error == client gone (close or dead TCP) -> exit cleanly
        if ws.write_message(Message::Text(fmt_sample(&s))).is_err() {
            break;
        }
        let _ = ws.flush();
    }
}

/// One aggregate /proc/stat sample: (total, idle) jiffies.
fn cpu_snap() -> (u64, u64) {
    let s = fs::read_to_string("/proc/stat").unwrap_or_default();
    let line = s.lines().next().unwrap_or("");
    let v: Vec<u64> = line
        .split_whitespace()
        .skip(1)
        .filter_map(|x| x.parse().ok())
        .collect();
    let total: u64 = v.iter().sum();
    let idle = v.get(3).copied().unwrap_or(0) + v.get(4).copied().unwrap_or(0);
    (total, idle)
}

fn cpu_pct(prev: (u64, u64), cur: (u64, u64)) -> f64 {
    let dt = cur.0.saturating_sub(prev.0);
    let di = cur.1.saturating_sub(prev.1);
    if dt == 0 {
        return 0.0;
    }
    ((1.0 - di as f64 / dt as f64) * 100.0).clamp(0.0, 100.0)
}

/// (used %, used GiB) from /proc/meminfo.
fn mem() -> (f64, f64) {
    let s = fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let get = |key: &str| -> f64 {
        s.lines()
            .find(|l| l.starts_with(key))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|x| x.parse::<f64>().ok())
            .unwrap_or(0.0)
            / 1_048_576.0
    };
    let total = get("MemTotal:");
    let avail = get("MemAvailable:");
    let used = (total - avail).max(0.0);
    let pct = if total > 0.0 { used / total * 100.0 } else { 0.0 };
    (pct, used)
}

/// (utilization %, memory used MB) via nvidia-smi; (0, 0) on any failure.
fn gpu() -> (f64, f64) {
    let out = Command::new("nvidia-smi")
        .args(["--query-gpu=utilization.gpu,memory.used", "--format=csv,noheader,nounits"])
        .output();
    let Ok(out) = out else { return (0.0, 0.0) };
    if !out.status.success() {
        return (0.0, 0.0);
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let first = text.lines().next().unwrap_or("");
    let mut it = first.split(',').map(str::trim);
    let mut num = || it.next().and_then(|x| x.parse::<f64>().ok()).unwrap_or(0.0);
    let util = num();
    let mem_mb = num();
    (util, mem_mb)
}
