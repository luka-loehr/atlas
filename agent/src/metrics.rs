//! Machine snapshot: /proc + shelling out to nvidia-smi / sensors / df / docker.

use std::fs;
use std::process::Command;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub fn collect() -> String {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let hostname = read_trim("/etc/hostname").unwrap_or_else(|| "atlas".into());
    let uptime_s = fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|s| s.split('.').next().map(str::to_string))
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    let load = read_load();
    let (cpu_usage, cores) = cpu_usage();
    let cpu_temp = cpu_temp();
    let (mem_used, mem_total) = mem_gb();
    let mem_usage = if mem_total > 0.0 { mem_used / mem_total * 100.0 } else { 0.0 };
    let gpu = gpu_json();
    let (disk_used, disk_total, disk_pct) = disk();
    let containers = super::actions::containers();

    format!(
        concat!(
            "{{\"hostname\":\"{host}\",\"ts\":{ts},\"uptime_s\":{up},",
            "\"load\":[{l1:.2},{l5:.2},{l15:.2}],",
            "\"cpu\":{{\"usage\":{cu:.1},\"cores\":{cores},\"temp_c\":{ctemp}}},",
            "\"mem\":{{\"used_gb\":{mu:.1},\"total_gb\":{mt:.1},\"usage\":{mus:.1}}},",
            "\"gpu\":{gpu},",
            "\"disk\":{{\"used_gb\":{du},\"total_gb\":{dt},\"usage\":{dp}}},",
            "\"containers\":{containers}}}"
        ),
        host = json_str(&hostname),
        ts = ts,
        up = uptime_s,
        l1 = load.0,
        l5 = load.1,
        l15 = load.2,
        cu = cpu_usage,
        cores = cores,
        ctemp = opt_f(cpu_temp),
        mu = mem_used,
        mt = mem_total,
        mus = mem_usage,
        gpu = gpu,
        du = disk_used,
        dt = disk_total,
        dp = disk_pct,
        containers = containers,
    )
}

fn read_trim(path: &str) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

fn read_load() -> (f64, f64, f64) {
    let s = fs::read_to_string("/proc/loadavg").unwrap_or_default();
    let mut it = s.split_whitespace();
    (
        it.next().and_then(|x| x.parse().ok()).unwrap_or(0.0),
        it.next().and_then(|x| x.parse().ok()).unwrap_or(0.0),
        it.next().and_then(|x| x.parse().ok()).unwrap_or(0.0),
    )
}

fn cpu_usage() -> (f64, u32) {
    let snap = || -> (u64, u64) {
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
    };
    let cores = fs::read_to_string("/proc/stat")
        .unwrap_or_default()
        .lines()
        .filter(|l| l.starts_with("cpu") && l.as_bytes().get(3).is_some_and(u8::is_ascii_digit))
        .count() as u32;
    let (t0, i0) = snap();
    thread::sleep(Duration::from_millis(200));
    let (t1, i1) = snap();
    let dt = t1.saturating_sub(t0);
    let di = i1.saturating_sub(i0);
    let usage = if dt > 0 { (1.0 - di as f64 / dt as f64) * 100.0 } else { 0.0 };
    (usage.clamp(0.0, 100.0), cores)
}

fn mem_gb() -> (f64, f64) {
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
    ((total - avail).max(0.0), total)
}

fn cpu_temp() -> Option<f64> {
    let out = Command::new("sensors").output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    for l in text.lines() {
        if l.contains("Package id") || l.contains("Tctl") || l.contains("Tdie") {
            if let Some(idx) = l.find('+') {
                let num: String = l[idx + 1..]
                    .chars()
                    .take_while(|c| c.is_ascii_digit() || *c == '.')
                    .collect();
                if let Ok(v) = num.parse::<f64>() {
                    return Some(v);
                }
            }
        }
    }
    None
}

fn gpu_json() -> String {
    let out = Command::new("nvidia-smi")
        .args([
            "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw",
            "--format=csv,noheader,nounits",
        ])
        .output();
    let Ok(out) = out else { return "null".into() };
    if !out.status.success() {
        return "null".into();
    }
    let line = String::from_utf8_lossy(&out.stdout);
    let first = line.lines().next().unwrap_or("");
    let f: Vec<String> = first.split(',').map(|x| x.trim().to_string()).collect();
    if f.len() < 6 {
        return "null".into();
    }
    let num = |i: usize| f.get(i).and_then(|x| x.parse::<f64>().ok()).unwrap_or(0.0);
    format!(
        "{{\"name\":\"{}\",\"usage\":{:.0},\"mem_used_mb\":{:.0},\"mem_total_mb\":{:.0},\"temp_c\":{:.0},\"power_w\":{:.1}}}",
        json_str(&f[0]),
        num(1),
        num(2),
        num(3),
        num(4),
        num(5),
    )
}

fn disk() -> (u64, u64, u64) {
    let out = Command::new("df")
        .args(["-BG", "--output=used,size,pcent", "/"])
        .output();
    let Ok(out) = out else { return (0, 0, 0) };
    let text = String::from_utf8_lossy(&out.stdout);
    let last = text.lines().last().unwrap_or("");
    let f: Vec<&str> = last.split_whitespace().collect();
    let g = |s: &str| s.trim_end_matches(['G', '%']).parse::<u64>().unwrap_or(0);
    if f.len() >= 3 { (g(f[0]), g(f[1]), g(f[2])) } else { (0, 0, 0) }
}

fn opt_f(v: Option<f64>) -> String {
    match v {
        Some(x) => format!("{x:.1}"),
        None => "null".into(),
    }
}

pub fn json_str(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => {}
            '\t' => o.push(' '),
            c if (c as u32) < 0x20 => {}
            c => o.push(c),
        }
    }
    o
}
