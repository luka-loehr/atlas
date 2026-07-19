//! Docker inspection + lightshow / fog control (shelling out to docker,
//! play.py, the fog Arduino trigger).

use std::fs;
use std::process::Command;

use crate::metrics::json_str;

fn home() -> String {
    std::env::var("HOME").unwrap_or_else(|_| "/home/atlas".into())
}

fn lightshow_dir() -> String {
    format!("{}/projects/lightshow", home())
}

/// Names we let reach docker / the filesystem — no shell metachars, no traversal.
fn safe(name: &str) -> bool {
    !name.is_empty()
        && name.len() < 128
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        && !name.contains("..")
}

fn run(cmd: &str, args: &[&str]) -> String {
    Command::new(cmd)
        .args(args)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

/// Running containers as a JSON array (also used by /api/metrics).
pub fn containers() -> String {
    let text = run("docker", &["ps", "--format", "{{.Names}}\t{{.Status}}\t{{.Image}}"]);
    let items: Vec<String> = text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            let mut p = l.splitn(3, '\t');
            let name = p.next().unwrap_or("");
            let status = p.next().unwrap_or("");
            let image = p.next().unwrap_or("");
            format!(
                "{{\"name\":\"{}\",\"status\":\"{}\",\"image\":\"{}\"}}",
                json_str(name),
                json_str(status),
                json_str(image)
            )
        })
        .collect();
    format!("[{}]", items.join(","))
}

/// Inspect one container: state, image, created, ports, recent logs.
pub fn inspect(name: &str) -> String {
    if !safe(name) {
        return r#"{"error":"bad name"}"#.into();
    }
    let fmt = "{{.State.Status}}\t{{.Config.Image}}\t{{.State.StartedAt}}\t{{.RestartCount}}\t{{range $p,$_ := .NetworkSettings.Ports}}{{$p}} {{end}}";
    let meta = run("docker", &["inspect", "-f", fmt, name]);
    let mut f = meta.trim().splitn(5, '\t');
    let state = f.next().unwrap_or("");
    let image = f.next().unwrap_or("");
    let started = f.next().unwrap_or("");
    let restarts = f.next().unwrap_or("0");
    let ports = f.next().unwrap_or("").trim();

    let logs = run("docker", &["logs", "--tail", "200", "--timestamps", name]);
    // docker logs writes to stderr too; grab a combined tail via a second call
    let err = Command::new("docker")
        .args(["logs", "--tail", "200", name])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stderr).into_owned())
        .unwrap_or_default();
    let combined = if logs.trim().is_empty() { err } else { logs };
    let tail: String = combined.lines().rev().take(200).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join("\n");

    format!(
        "{{\"name\":\"{}\",\"state\":\"{}\",\"image\":\"{}\",\"started\":\"{}\",\"restarts\":{},\"ports\":\"{}\",\"logs\":\"{}\"}}",
        json_str(name),
        json_str(state),
        json_str(image),
        json_str(started),
        restarts.trim().parse::<u64>().unwrap_or(0),
        json_str(ports),
        json_str(&tail),
    )
}

// ---- lightshow ------------------------------------------------------------

/// Lightshows on disk (name + a bit of meta parsed from the .show.json).
pub fn shows() -> String {
    let dir = format!("{}/shows", lightshow_dir());
    let Ok(entries) = fs::read_dir(&dir) else {
        return "[]".into();
    };
    let mut names: Vec<String> = entries
        .filter_map(|e| e.ok())
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| n.ends_with(".show.json"))
        .collect();
    names.sort();

    let running = current_show();
    let items: Vec<String> = names
        .iter()
        .map(|file| {
            let name = file.trim_end_matches(".show.json");
            let text = fs::read_to_string(format!("{dir}/{file}")).unwrap_or_default();
            let title = extract_str(&text, "title").unwrap_or_else(|| name.to_string());
            let bpm = extract_num(&text, "bpm").unwrap_or(0.0);
            let dur = extract_num(&text, "duration_ms").unwrap_or(0.0) / 1000.0;
            let is_running = running.as_deref() == Some(file) || running.as_deref() == Some(name);
            format!(
                "{{\"name\":\"{}\",\"file\":\"{}\",\"title\":\"{}\",\"bpm\":{:.0},\"duration_s\":{:.0},\"running\":{}}}",
                json_str(name),
                json_str(file),
                json_str(&title),
                bpm,
                dur,
                is_running
            )
        })
        .collect();
    format!(
        "{{\"bridge\":{},\"shows\":[{}]}}",
        bridge_running(),
        items.join(",")
    )
}

fn bridge_running() -> bool {
    !run("pgrep", &["-f", "hue_stream.py"]).trim().is_empty()
}

/// Best-effort: which show file the current play.py is running.
fn current_show() -> Option<String> {
    let ps = run("pgrep", &["-af", "play.py"]);
    let line = ps.lines().next()?;
    line.split_whitespace()
        .find(|t| t.ends_with(".show.json"))
        .map(|p| p.rsplit('/').next().unwrap_or(p).to_string())
}

/// Stop play.py gently (SIGINT -> its finally sends blackout frames that also
/// power the plugs off through the bridge) and wait until it is really gone.
fn stop_player_gently() {
    if run("pgrep", &["-f", "play.py"]).trim().is_empty() {
        return;
    }
    let _ = Command::new("pkill").args(["-INT", "-f", "play.py"]).status();
    for _ in 0..20 {
        std::thread::sleep(std::time::Duration::from_millis(150));
        if run("pgrep", &["-f", "play.py"]).trim().is_empty() {
            return;
        }
    }
    let _ = Command::new("pkill").args(["-f", "play.py"]).status();
}

/// Make sure the bridge is up (it owns Hue DTLS, the fog Arduino and the
/// plugs). Started once, it stays alive between shows — restarts are instant
/// and hold-to-fog works anytime.
fn ensure_bridge() -> bool {
    if bridge_running() {
        return true;
    }
    let dir = lightshow_dir();
    let _ = Command::new("sh")
        .arg("-c")
        .arg(format!(
            "cd {dir} && setsid nohup python3 -u bridge/hue_stream.py >/tmp/atlas-bridge.log 2>&1 &"
        ))
        .status();
    // wait for "listening for Art-Net" (DTLS handshake takes ~3s)
    for _ in 0..40 {
        std::thread::sleep(std::time::Duration::from_millis(250));
        let log = fs::read_to_string("/tmp/atlas-bridge.log").unwrap_or_default();
        if log.contains("listening for Art-Net") {
            return true;
        }
        if !bridge_running() {
            return false;
        }
    }
    bridge_running()
}

pub fn show_start(name: &str) -> String {
    if !safe(name) {
        return r#"{"error":"bad name"}"#.into();
    }
    let dir = lightshow_dir();
    let file = if name.ends_with(".show.json") {
        name.to_string()
    } else {
        format!("{name}.show.json")
    };
    if !std::path::Path::new(&format!("{dir}/shows/{file}")).exists() {
        return r#"{"error":"unknown show"}"#.into();
    }
    stop_player_gently();
    if !ensure_bridge() {
        return r#"{"error":"bridge failed to start (see /tmp/atlas-bridge.log)"}"#.into();
    }
    // --no-audio: the iOS app plays the song; atlas only drives the lights
    let _ = Command::new("sh")
        .arg("-c")
        .arg(format!(
            "cd {dir} && setsid nohup python3 -u play.py shows/{file} --no-audio --no-preroll >/tmp/atlas-play.log 2>&1 &"
        ))
        .status();
    format!("{{\"ok\":true,\"started\":\"{}\",\"bridge\":true}}", json_str(&file))
}

/// Stop the show. The bridge STAYS alive (instant restarts, fog anytime);
/// plugs are additionally forced off via the Hue REST API as a belt-and-
/// suspenders fallback. `atlas` / the app can stop the bridge explicitly
/// with /api/bridge/stop.
pub fn show_stop() -> String {
    fog_stop();
    stop_player_gently();
    plugs_off_rest();
    r#"{"ok":true,"stopped":true,"bridge":true}"#.into()
}

/// Stop EVERYTHING: fog, player, bridge (graceful, it powers plugs off and
/// ends the Hue stream), then the REST plug fallback.
pub fn bridge_stop() -> String {
    fog_stop();
    stop_player_gently();
    if bridge_running() {
        let _ = Command::new("pkill").args(["-INT", "-f", "hue_stream.py"]).status();
        for _ in 0..40 {
            std::thread::sleep(std::time::Duration::from_millis(250));
            if !bridge_running() {
                break;
            }
        }
        let _ = Command::new("pkill").args(["-f", "hue_stream.py"]).status();
    }
    plugs_off_rest();
    r#"{"ok":true,"stopped":true,"bridge":false}"#.into()
}

/// Force laser (22) + strobe (25) plugs off directly on the Hue bridge.
fn plugs_off_rest() {
    let creds = fs::read_to_string(format!("{}/bridge/credentials.json", lightshow_dir()))
        .unwrap_or_default();
    let (Some(host), Some(user)) = (extract_str(&creds, "host"), extract_str(&creds, "username"))
    else {
        return;
    };
    for id in ["22", "25"] {
        let _ = Command::new("curl")
            .args([
                "-s", "-m", "5", "-X", "PUT", "-d", r#"{"on":false}"#,
                &format!("http://{host}/api/{user}/lights/{id}/state"),
            ])
            .output();
    }
}

// ---- fog ------------------------------------------------------------------
//
// Fog always goes THROUGH the bridge: the agent sends Art-Net packets with
// channel 19 high to 127.0.0.1:6454 (30 Hz heartbeat). The packets are 19
// channels long, so the laser/strobe logic (channels 20/21) never sees them,
// and the lamp channels are all zero, so the bridge's peak-hold ignores them.
// Works standalone AND while a show is running.

use std::sync::atomic::{AtomicU64, Ordering};

static FOG_GEN: AtomicU64 = AtomicU64::new(0);

fn artnet_fog_packet(on: bool) -> [u8; 18 + 19] {
    let mut p = [0u8; 37];
    p[..8].copy_from_slice(b"Art-Net\0");
    p[8] = 0x00; // OpDmx low
    p[9] = 0x50; // OpDmx high
    p[10] = 0;   // proto hi
    p[11] = 14;  // proto lo
    // seq, phys, subuni, net = 0
    p[16] = 0;   // length hi
    p[17] = 19;  // length lo
    p[18 + 18] = if on { 255 } else { 0 }; // channel 19 (0-based 18)
    p
}

fn send_fog_packet(on: bool) {
    if let Ok(sock) = std::net::UdpSocket::bind("127.0.0.1:0") {
        let _ = sock.send_to(&artnet_fog_packet(on), "127.0.0.1:6454");
    }
}

/// Start fog for up to `ms` (hold-to-fog: the app calls /api/fog on press and
/// /api/fog/stop on release). Ensures the bridge is up, then heartbeats fog
/// packets at 30 Hz until stop/timeout, then sends explicit fog-low packets.
pub fn fog(ms: u64) -> String {
    if !ensure_bridge() {
        return r#"{"error":"bridge failed to start (see /tmp/atlas-bridge.log)"}"#.into();
    }
    let ms = ms.clamp(200, 30_000);
    let generation = FOG_GEN.fetch_add(1, Ordering::SeqCst) + 1;
    std::thread::spawn(move || {
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(ms);
        while std::time::Instant::now() < deadline
            && FOG_GEN.load(Ordering::SeqCst) == generation
        {
            send_fog_packet(true);
            std::thread::sleep(std::time::Duration::from_millis(33));
        }
        for _ in 0..3 {
            send_fog_packet(false);
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    });
    format!("{{\"ok\":true,\"fog_ms\":{ms}}}")
}

pub fn fog_stop() -> String {
    FOG_GEN.fetch_add(1, Ordering::SeqCst); // invalidates any running heartbeat
    for _ in 0..3 {
        send_fog_packet(false);
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    r#"{"ok":true,"stopped":true}"#.into()
}

// ---- YouTube -> show ------------------------------------------------------

const MAKESHOW_LOG: &str = "/tmp/atlas-makeshow.log";

/// Kick off `makeshow.py --local <url>` in the background (yt-dlp -> GPU
/// analysis -> compiled show). Poll /api/shows/create/status for progress.
pub fn show_create(url: &str) -> String {
    let url = url.trim();
    if !(url.starts_with("http://") || url.starts_with("https://")) || url.len() > 2048 {
        return r#"{"error":"expected an http(s) URL"}"#.into();
    }
    if !run("pgrep", &["-f", "makeshow.py"]).trim().is_empty() {
        return r#"{"error":"a show is already being created"}"#.into();
    }
    let dir = lightshow_dir();
    let Ok(log) = fs::File::create(MAKESHOW_LOG) else {
        return r#"{"error":"cannot open log"}"#.into();
    };
    let err = log.try_clone().ok();
    // no shell: the URL is a plain argv element, so nothing to escape/inject
    let spawned = Command::new("setsid")
        .current_dir(&dir)
        .args(["python3", "-u", "makeshow.py", "--local", url])
        .stdout(std::process::Stdio::from(log))
        .stderr(err.map(std::process::Stdio::from).unwrap_or(std::process::Stdio::null()))
        .spawn();
    match spawned {
        Ok(_) => r#"{"ok":true,"started":true}"#.into(),
        Err(e) => format!("{{\"error\":\"{}\"}}", json_str(&e.to_string())),
    }
}

pub fn create_status() -> String {
    let running = !run("pgrep", &["-f", "makeshow.py"]).trim().is_empty();
    let log = fs::read_to_string(MAKESHOW_LOG).unwrap_or_default();
    let tail: String = log.lines().rev().take(40).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join("\n");

    // structured markers streamed by makeshow.py
    let phase = log
        .lines()
        .rev()
        .find_map(|l| l.trim().strip_prefix("PHASE:"))
        .unwrap_or(if running { "start" } else { "idle" });
    let title = log
        .lines()
        .rev()
        .find_map(|l| l.trim().strip_prefix("TITLE:"))
        .unwrap_or("");
    let thumb = log.lines().any(|l| l.trim().starts_with("THUMB:"));
    // yt-dlp --newline: "[download]  42.3% of ..."
    let percent = log
        .lines()
        .rev()
        .filter(|l| l.contains("[download]") && l.contains('%'))
        .find_map(|l| {
            let p = l.split('%').next()?;
            p.split_whitespace().last()?.parse::<f64>().ok()
        })
        .unwrap_or(0.0);
    let done_name = log
        .lines()
        .find_map(|l| l.trim().strip_prefix("wrote shows/"))
        .and_then(|s| s.strip_suffix(".show.json"))
        .map(str::to_string);
    let failed = !running && done_name.is_none() && log.contains("FAILED");

    format!(
        "{{\"running\":{},\"done\":{},\"failed\":{},\"phase\":\"{}\",\"percent\":{:.1},\"title\":\"{}\",\"thumb\":{},\"name\":{},\"log\":\"{}\"}}",
        running,
        done_name.is_some(),
        failed,
        json_str(phase),
        percent,
        json_str(title),
        thumb,
        done_name.map(|n| format!("\"{}\"", json_str(&n))).unwrap_or("null".into()),
        json_str(&tail),
    )
}

/// Newest downloaded thumbnail (during create) — downloads/<title>.jpg.
pub fn create_thumb() -> Option<std::path::PathBuf> {
    let log = fs::read_to_string(MAKESHOW_LOG).unwrap_or_default();
    let p = log
        .lines()
        .rev()
        .find_map(|l| l.trim().strip_prefix("THUMB:"))?;
    let path = std::path::PathBuf::from(p);
    path.exists().then_some(path)
}

/// A show's cover: shows/<name>.jpg, if present.
pub fn show_thumb(name: &str) -> Option<std::path::PathBuf> {
    if !safe(name) {
        return None;
    }
    let p = std::path::PathBuf::from(format!("{}/shows/{name}.jpg", lightshow_dir()));
    p.exists().then_some(p)
}

/// Absolute path to a show's audio file (shows/<name>.<audio-ext>), if present.
pub fn audio_file(name: &str) -> Option<std::path::PathBuf> {
    if !safe(name) {
        return None;
    }
    let base = format!("{}/shows", lightshow_dir());
    for ext in ["mp3", "m4a", "opus", "webm", "wav", "aac", "flac"] {
        let p = std::path::PathBuf::from(format!("{base}/{name}.{ext}"));
        if p.exists() {
            return Some(p);
        }
    }
    None
}

// ---- tiny JSON field pickers (avoid a serde dep for a couple of fields) ----

fn extract_str(text: &str, key: &str) -> Option<String> {
    let pat = format!("\"{key}\"");
    let i = text.find(&pat)? + pat.len();
    let rest = &text[i..];
    let c = rest.find(':')? + 1;
    let after = rest[c..].trim_start();
    let after = after.strip_prefix('"')?;
    let end = after.find('"')?;
    Some(after[..end].to_string())
}

fn extract_num(text: &str, key: &str) -> Option<f64> {
    let pat = format!("\"{key}\"");
    let i = text.find(&pat)? + pat.len();
    let rest = &text[i..];
    let c = rest.find(':')? + 1;
    let after = rest[c..].trim_start();
    let num: String = after
        .chars()
        .take_while(|ch| ch.is_ascii_digit() || *ch == '.' || *ch == '-')
        .collect();
    num.parse().ok()
}
