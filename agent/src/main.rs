//! atlas-agent — a tiny, zero-dependency metrics server for the Atlas Command
//! Center iOS app. Binds the tailnet (0.0.0.0:8787 by default) and serves a
//! JSON snapshot of the machine: CPU / GPU / RAM / disk / temps / load /
//! uptime / docker containers. Read from /proc directly; shell out to
//! nvidia-smi, sensors, df, docker for the rest.
//!
//!   GET  /health                 -> {"ok":true}
//!   GET  /api/metrics            -> full snapshot (below)
//!   POST /api/power/shutdown     -> sudo poweroff   (requires token)
//!   POST /api/power/restart      -> sudo reboot     (requires token)
//!
//! Auth: if ATLAS_AGENT_TOKEN is set, every request needs
//! `Authorization: Bearer <token>`. Power actions ALWAYS need the token.

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::Command;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn main() {
    let port: u16 = std::env::var("ATLAS_AGENT_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8787);
    let token = std::env::var("ATLAS_AGENT_TOKEN").ok().filter(|t| !t.is_empty());

    let listener = TcpListener::bind(("0.0.0.0", port)).unwrap_or_else(|e| {
        eprintln!("atlas-agent: cannot bind :{port}: {e}");
        std::process::exit(1);
    });
    println!(
        "atlas-agent on :{port} (auth: {})",
        if token.is_some() { "token" } else { "open/tailnet" }
    );

    for stream in listener.incoming() {
        if let Ok(s) = stream {
            let token = token.clone();
            thread::spawn(move || handle(s, token.as_deref()));
        }
    }
}

fn handle(mut stream: TcpStream, token: Option<&str>) {
    let mut reader = BufReader::new(match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    });

    // request line
    let mut line = String::new();
    if reader.read_line(&mut line).is_err() {
        return;
    }
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("");

    // headers — keep the Authorization value case-intact (token is sensitive)
    let mut auth = String::new();
    let mut content_len = 0usize;
    loop {
        let mut h = String::new();
        if reader.read_line(&mut h).is_err() || h == "\r\n" || h == "\n" || h.is_empty() {
            break;
        }
        let Some((name, val)) = h.split_once(':') else { continue };
        match name.trim().to_ascii_lowercase().as_str() {
            "authorization" => auth = val.trim().to_string(),
            "content-length" => content_len = val.trim().parse().unwrap_or(0),
            _ => {}
        }
    }
    if content_len > 0 {
        let mut body = vec![0u8; content_len.min(4096)];
        let _ = reader.read_exact(&mut body);
    }

    let provided = auth
        .strip_prefix("Bearer ")
        .or_else(|| auth.strip_prefix("bearer "))
        .map(str::trim);
    let has_token = matches!((token, provided), (Some(t), Some(p)) if t == p);

    // if a token is configured, gate everything
    if token.is_some() && !has_token {
        return respond(&mut stream, 401, r#"{"error":"unauthorized"}"#);
    }

    match (method, path) {
        ("GET", "/health") => respond(&mut stream, 200, r#"{"ok":true}"#),
        ("GET", "/api/metrics") | ("GET", "/") => {
            respond(&mut stream, 200, &collect_metrics())
        }
        ("POST", "/api/power/shutdown") => power(&mut stream, token.is_some() && has_token, "poweroff"),
        ("POST", "/api/power/restart") => power(&mut stream, token.is_some() && has_token, "reboot"),
        _ => respond(&mut stream, 404, r#"{"error":"not found"}"#),
    }
}

fn power(stream: &mut TcpStream, authorized: bool, what: &str) {
    if !authorized {
        return respond(stream, 403, r#"{"error":"power actions require a token"}"#);
    }
    respond(stream, 200, &format!(r#"{{"ok":true,"action":"{what}"}}"#));
    // flush the response, then act (poweroff/reboot drop the connection)
    let _ = Command::new("sh")
        .arg("-c")
        .arg(format!("sleep 1; sudo {what}"))
        .spawn();
}

fn respond(stream: &mut TcpStream, code: u16, body: &str) {
    let reason = match code {
        200 => "OK",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        _ => "OK",
    };
    let msg = format!(
        "HTTP/1.1 {code} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(msg.as_bytes());
    let _ = stream.flush();
}

// ---- metrics --------------------------------------------------------------

fn collect_metrics() -> String {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let hostname = read_trim("/etc/hostname").unwrap_or_else(|| "atlas".into());
    let uptime_s = fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|s| s.split('.').next().map(|x| x.to_string()))
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    let load = read_load();
    let (cpu_usage, cores) = cpu_usage();
    let cpu_temp = cpu_temp();
    let (mem_used, mem_total) = mem_gb();
    let mem_usage = if mem_total > 0.0 { mem_used / mem_total * 100.0 } else { 0.0 };
    let gpu = gpu_json();
    let (disk_used, disk_total, disk_pct) = disk();
    let containers = containers_json();

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

/// Sample /proc/stat twice 200ms apart for an instantaneous CPU busy %.
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
    let usage = if dt > 0 {
        (1.0 - di as f64 / dt as f64) * 100.0
    } else {
        0.0
    };
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
            / 1_048_576.0 // kB -> GB
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
            // e.g. "Package id 0:  +31.0°C  (high = ...)"
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
    if f.len() >= 3 {
        (g(f[0]), g(f[1]), g(f[2]))
    } else {
        (0, 0, 0)
    }
}

fn containers_json() -> String {
    let out = Command::new("docker")
        .args(["ps", "--format", "{{.Names}}\t{{.Status}}"])
        .output();
    let Ok(out) = out else { return "[]".into() };
    let text = String::from_utf8_lossy(&out.stdout);
    let items: Vec<String> = text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            let mut p = l.splitn(2, '\t');
            let name = p.next().unwrap_or("");
            let status = p.next().unwrap_or("");
            format!(
                "{{\"name\":\"{}\",\"status\":\"{}\"}}",
                json_str(name),
                json_str(status)
            )
        })
        .collect();
    format!("[{}]", items.join(","))
}

fn opt_f(v: Option<f64>) -> String {
    match v {
        Some(x) => format!("{x:.1}"),
        None => "null".into(),
    }
}

fn json_str(s: &str) -> String {
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
