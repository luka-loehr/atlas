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

mod readers;

pub use readers::hostname;
use readers::{cpu_jiffies, cpu_percent, cpu_temp, disks, memory, net_bytes, rapl_energy, rapl_watts, read_trimmed};

const TICK: Duration = Duration::from_millis(500);
const HISTORY: usize = 1200; // 10 minutes at 2 Hz

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
