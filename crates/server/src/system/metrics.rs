//! Machine metrics without spawning a process per sample.
//!
//! One thread samples once a second: /proc for CPU, memory and network, NVML
//! for the GPU, the RAPL energy counter for CPU power, hwmon for the CPU
//! temperature. The last ten minutes are kept, so a chart is full the moment
//! a client connects, and every new sample is broadcast to live clients.

use std::collections::VecDeque;
use std::fs;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use axum::Json;
use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::response::Response;
use nvml_wrapper::Nvml;
use nvml_wrapper::enum_wrappers::device::TemperatureSensor;
use serde::Serialize;
use serde_json::{Value, json};
use tokio::sync::broadcast;

use crate::{AppState, Config};

const TICK: Duration = Duration::from_secs(1);
const HISTORY: usize = 600;

#[derive(Clone, Copy, Serialize, Default)]
pub struct Sample {
    /// unix milliseconds
    pub ts: u64,
    /// percent of all cores
    pub cpu: f32,
    /// percent of RAM in use
    pub mem: f32,
    pub mem_gb: f32,
    /// percent GPU utilization
    pub gpu: f32,
    pub gpu_mem_mb: f32,
    /// cumulative bytes over the physical interfaces; clients derive rates
    pub rx: u64,
    pub tx: u64,
    pub cpu_temp: Option<f32>,
    pub gpu_temp: Option<f32>,
    pub cpu_w: Option<f32>,
    pub gpu_w: Option<f32>,
    /// whole-system estimate at the wall
    pub system_w: Option<f32>,
}

pub struct Sampler {
    history: Arc<Mutex<VecDeque<Sample>>>,
    live: broadcast::Sender<Sample>,
    gpu: Option<GpuInfo>,
}

#[derive(Clone, Serialize)]
struct GpuInfo {
    name: String,
    mem_total_mb: f32,
}

impl Sampler {
    pub fn start(cfg: &Config) -> Self {
        let history = Arc::new(Mutex::new(VecDeque::with_capacity(HISTORY + 1)));
        let (live, _) = broadcast::channel(16);
        let nvml = Nvml::init().ok();
        let gpu = nvml.as_ref().and_then(|n| {
            let device = n.device_by_index(0).ok()?;
            Some(GpuInfo {
                name: device.name().ok()?,
                mem_total_mb: device.memory_info().ok()?.total as f32 / 1_048_576.0,
            })
        });
        let (baseline, efficiency) = (cfg.power_baseline_w, cfg.psu_efficiency);
        let (thread_history, thread_live) = (history.clone(), live.clone());
        std::thread::Builder::new()
            .name("metrics".into())
            .spawn(move || sample_loop(nvml, thread_history, thread_live, baseline, efficiency))
            .expect("metrics thread");
        Sampler { history, live, gpu }
    }

    pub fn latest(&self) -> Sample {
        self.history.lock().unwrap().back().copied().unwrap_or_default()
    }
}

fn sample_loop(
    nvml: Option<Nvml>,
    history: Arc<Mutex<VecDeque<Sample>>>,
    live: broadcast::Sender<Sample>,
    baseline_w: f64,
    psu_efficiency: f64,
) {
    let mut cpu_before = cpu_jiffies();
    let mut energy_before = rapl_energy().map(|e| (e, Instant::now()));
    let mut next = Instant::now() + TICK;
    loop {
        std::thread::sleep(next.saturating_duration_since(Instant::now()));
        next += TICK;
        if next < Instant::now() {
            next = Instant::now() + TICK; // fell behind (suspend): do not burst to catch up
        }

        let cpu_now = cpu_jiffies();
        let cpu = cpu_percent(cpu_before, cpu_now);
        cpu_before = cpu_now;

        let energy_now = rapl_energy().map(|e| (e, Instant::now()));
        let cpu_w = match (energy_before, energy_now) {
            (Some((e0, t0)), Some((e1, t1))) => rapl_watts(e0, e1, t1.duration_since(t0).as_secs_f64()),
            _ => None,
        };
        energy_before = energy_now;

        let device = nvml.as_ref().and_then(|n| n.device_by_index(0).ok());
        let gpu = device.as_ref().and_then(|d| d.utilization_rates().ok()).map(|u| u.gpu as f32);
        let gpu_mem = device.as_ref().and_then(|d| d.memory_info().ok()).map(|m| m.used as f32 / 1_048_576.0);
        let gpu_temp = device.as_ref().and_then(|d| d.temperature(TemperatureSensor::Gpu).ok()).map(|t| t as f32);
        let gpu_w = device.as_ref().and_then(|d| d.power_usage().ok()).map(|mw| mw as f32 / 1000.0);

        let (mem, mem_gb, _) = memory();
        let (rx, tx) = net_bytes();
        // Measured CPU (RAPL) + GPU (NVML) + a fixed baseline for RAM, board,
        // storage and fans, over PSU efficiency. Only a wall-plug meter is
        // exact; this is the software approximation.
        let system_w =
            cpu_w.map(|c| ((f64::from(c) + f64::from(gpu_w.unwrap_or(0.0)) + baseline_w) / psu_efficiency) as f32);

        let sample = Sample {
            ts: SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0),
            cpu,
            mem,
            mem_gb,
            gpu: gpu.unwrap_or(0.0),
            gpu_mem_mb: gpu_mem.unwrap_or(0.0),
            rx,
            tx,
            cpu_temp: cpu_temp(),
            gpu_temp,
            cpu_w,
            gpu_w,
            system_w,
        };
        let mut history = history.lock().unwrap();
        history.push_back(sample);
        while history.len() > HISTORY {
            history.pop_front();
        }
        drop(history);
        let _ = live.send(sample);
    }
}

// ----------------------------------------------------------------- readers ---

fn read_trimmed(path: &str) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

pub fn hostname() -> String {
    read_trimmed("/etc/hostname")
        .or_else(|| read_trimmed("/proc/sys/kernel/hostname"))
        .unwrap_or_else(|| "atlas".into())
}

/// (total, idle) jiffies summed over all cores.
fn cpu_jiffies() -> (u64, u64) {
    let stat = fs::read_to_string("/proc/stat").unwrap_or_default();
    let fields: Vec<u64> = stat
        .lines()
        .next()
        .unwrap_or("")
        .split_whitespace()
        .skip(1)
        .filter_map(|x| x.parse().ok())
        .collect();
    let idle = fields.get(3).copied().unwrap_or(0) + fields.get(4).copied().unwrap_or(0);
    (fields.iter().sum(), idle)
}

fn cpu_percent(before: (u64, u64), now: (u64, u64)) -> f32 {
    let total = now.0.saturating_sub(before.0);
    let idle = now.1.saturating_sub(before.1);
    if total == 0 {
        return 0.0;
    }
    ((1.0 - idle as f64 / total as f64) * 100.0).clamp(0.0, 100.0) as f32
}

/// (percent used, GiB used, GiB total)
fn memory() -> (f32, f32, f32) {
    let info = fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let gib = |key: &str| {
        info.lines()
            .find(|l| l.starts_with(key))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|x| x.parse::<f64>().ok())
            .unwrap_or(0.0)
            / 1_048_576.0
    };
    let total = gib("MemTotal:");
    let used = (total - gib("MemAvailable:")).max(0.0);
    let percent = if total > 0.0 { used / total * 100.0 } else { 0.0 };
    (percent as f32, used as f32, total as f32)
}

/// Cumulative rx/tx over physical interfaces. Loopback, container bridges
/// and the tailscale device are skipped: their traffic either never leaves
/// the box or is already counted on the NIC it leaves through.
fn net_bytes() -> (u64, u64) {
    let dev = fs::read_to_string("/proc/net/dev").unwrap_or_default();
    let (mut rx, mut tx) = (0u64, 0u64);
    for line in dev.lines().skip(2) {
        let Some((name, rest)) = line.split_once(':') else { continue };
        let name = name.trim();
        if name == "lo" || ["docker", "veth", "br-", "tailscale"].iter().any(|p| name.starts_with(p)) {
            continue;
        }
        let fields: Vec<&str> = rest.split_whitespace().collect();
        if fields.len() >= 9 {
            rx += fields[0].parse::<u64>().unwrap_or(0);
            tx += fields[8].parse::<u64>().unwrap_or(0);
        }
    }
    (rx, tx)
}

/// The CPU package sensor (coretemp on Intel, k10temp/zenpower on AMD).
fn cpu_temp() -> Option<f32> {
    for entry in fs::read_dir("/sys/class/hwmon").ok()?.flatten() {
        let dir = entry.path();
        let name = read_trimmed(&dir.join("name").to_string_lossy())?;
        if matches!(name.as_str(), "coretemp" | "k10temp" | "zenpower") {
            let millis: f32 = read_trimmed(&dir.join("temp1_input").to_string_lossy())?.parse().ok()?;
            return Some(millis / 1000.0);
        }
    }
    None
}

const RAPL_ENERGY: &str = "/sys/class/powercap/intel-rapl:0/energy_uj";
const RAPL_RANGE: &str = "/sys/class/powercap/intel-rapl:0/max_energy_range_uj";

/// Microjoules since boot. Root-only by default; scripts/power makes it
/// readable.
fn rapl_energy() -> Option<u64> {
    read_trimmed(RAPL_ENERGY)?.parse().ok()
}

fn rapl_watts(before: u64, now: u64, seconds: f64) -> Option<f32> {
    if seconds <= 0.0 {
        return None;
    }
    let joules = if now >= before {
        now - before
    } else {
        // the counter wrapped
        let range: u64 = read_trimmed(RAPL_RANGE)?.parse().ok()?;
        (range - before).saturating_add(now)
    };
    Some((joules as f64 / 1_000_000.0 / seconds) as f32)
}

#[derive(Serialize)]
struct Disk {
    mount: String,
    used: u64,
    total: u64,
}

/// The filesystems the library lives on, each once.
fn disks(cfg: &Config) -> Vec<Disk> {
    use std::os::unix::fs::MetadataExt;
    let mounts: Vec<(String, String)> = fs::read_to_string("/proc/mounts")
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let mut fields = l.split_whitespace();
            Some((fields.next()?.to_string(), fields.next()?.to_string()))
        })
        .collect();
    // A filesystem can be mounted more than once (a bind mount into the
    // library): name it by where its device is mounted first.
    let mount_of = |path: &std::path::Path| -> String {
        let path = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        let device = mounts.iter().filter(|(_, at)| path.starts_with(at)).max_by_key(|(_, at)| at.len()).map(|(d, _)| d);
        mounts
            .iter()
            .find(|(d, _)| Some(d) == device)
            .map_or_else(|| "/".to_string(), |(_, at)| at.clone())
    };
    let mut seen = Vec::new();
    let mut out = Vec::new();
    for path in [std::path::PathBuf::from("/"), cfg.originals_dir(), cfg.blobs_dir()] {
        let Ok(meta) = fs::metadata(&path) else { continue };
        if seen.contains(&meta.dev()) {
            continue;
        }
        seen.push(meta.dev());
        let Ok(c_path) = std::ffi::CString::new(path.to_string_lossy().as_bytes()) else { continue };
        let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
        // SAFETY: c_path is a valid NUL-terminated string and stat is a
        // properly sized, writable statvfs the call fills in.
        if unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) } != 0 {
            continue;
        }
        let block = stat.f_frsize as u64;
        let total = stat.f_blocks as u64 * block;
        out.push(Disk { mount: mount_of(&path), used: total - stat.f_bfree as u64 * block, total });
    }
    out
}

// ---------------------------------------------------------------- handlers ---

pub async fn snapshot(State(app): State<AppState>) -> Json<Value> {
    let now = app.metrics.latest();
    let load: Vec<f64> = fs::read_to_string("/proc/loadavg")
        .unwrap_or_default()
        .split_whitespace()
        .take(3)
        .filter_map(|x| x.parse().ok())
        .collect();
    let uptime: f64 = fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|s| s.split_whitespace().next().and_then(|x| x.parse().ok()))
        .unwrap_or(0.0);
    let cpu_model = fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|s| s.lines().find(|l| l.starts_with("model name")).and_then(|l| l.split_once(':')).map(|(_, v)| v.trim().to_string()));
    let os = fs::read_to_string("/etc/os-release").ok().and_then(|s| {
        s.lines().find_map(|l| l.strip_prefix("PRETTY_NAME=").map(|v| v.trim_matches('"').to_string()))
    });
    Json(json!({
        "hostname": hostname(),
        "version": env!("CARGO_PKG_VERSION"),
        "os": os,
        "kernel": read_trimmed("/proc/sys/kernel/osrelease"),
        "uptime_s": uptime as u64,
        "load": load,
        "cpu": {
            "model": cpu_model,
            "cores": std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0),
        },
        "mem_total_gb": memory().2,
        "gpu": app.metrics.gpu,
        "disks": disks(&app.cfg),
        "now": now,
    }))
}

pub async fn live(State(app): State<AppState>, ws: WebSocketUpgrade) -> Response {
    ws.on_upgrade(move |socket| stream(socket, app))
}

/// First frame: {"history":[...]}. Then one sample per second.
async fn stream(mut socket: WebSocket, app: AppState) {
    // subscribe before reading the history, so no sample falls between them
    let mut updates = app.metrics.live.subscribe();
    let history: Vec<Sample> = app.metrics.history.lock().unwrap().iter().copied().collect();
    let last = history.last().map_or(0, |s| s.ts);
    let Ok(first) = serde_json::to_string(&json!({ "history": history })) else { return };
    if socket.send(Message::Text(first.into())).await.is_err() {
        return;
    }
    loop {
        tokio::select! {
            update = updates.recv() => match update {
                Ok(sample) if sample.ts > last => {
                    let Ok(frame) = serde_json::to_string(&sample) else { continue };
                    if socket.send(Message::Text(frame.into())).await.is_err() {
                        return;
                    }
                }
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => return,
            },
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => return,
                Some(Ok(_)) => {}
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cpu_percent_is_the_busy_share_of_the_interval() {
        assert_eq!(cpu_percent((1000, 800), (1100, 825)), 75.0);
        assert_eq!(cpu_percent((1000, 800), (1000, 800)), 0.0);
    }
}
