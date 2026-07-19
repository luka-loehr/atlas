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
    // stop anything already playing, make sure the bridge is up, then play.
    let _ = Command::new("pkill").args(["-f", "play.py"]).status();
    if !bridge_running() {
        let _ = Command::new("sh")
            .arg("-c")
            .arg(format!(
                "cd {dir} && setsid nohup python3 -u bridge/hue_stream.py >/tmp/atlas-bridge.log 2>&1 &"
            ))
            .status();
        std::thread::sleep(std::time::Duration::from_millis(1500));
    }
    // --no-audio: the iOS app plays the song; atlas only drives the lights
    let _ = Command::new("sh")
        .arg("-c")
        .arg(format!(
            "cd {dir} && setsid nohup python3 -u play.py shows/{file} --no-audio --no-preroll >/tmp/atlas-play.log 2>&1 &"
        ))
        .status();
    format!(
        "{{\"ok\":true,\"started\":\"{}\",\"bridge\":{}}}",
        json_str(&file),
        bridge_running()
    )
}

pub fn show_stop() -> String {
    // SIGINT, not SIGTERM: play.py's finally sends blackout frames and powers
    // the laser/strobe plugs off — killing it hard could leave them ON.
    let _ = Command::new("pkill").args(["-INT", "-f", "play.py"]).status();
    std::thread::sleep(std::time::Duration::from_millis(1500));
    let _ = Command::new("pkill").args(["-f", "play.py"]).status();
    let _ = Command::new("pkill").args(["-f", "hue_stream.py"]).status();
    r#"{"ok":true,"stopped":true}"#.into()
}

// ---- fog ------------------------------------------------------------------

/// Start a fog burst of `ms` (heartbeat protocol to the Arduino). For
/// hold-to-fog the app sends a long burst on press and calls /api/fog/stop on
/// release; the Arduino watchdog also auto-stops when the heartbeat ends.
pub fn fog(ms: u64) -> String {
    if bridge_running() {
        return r#"{"error":"bridge is running — it owns the serial port; stop the show first"}"#.into();
    }
    let ms = ms.clamp(100, 30_000);
    let dir = lightshow_dir();
    let _ = Command::new("sh")
        .arg("-c")
        .arg(format!(
            "setsid nohup python3 {dir}/tools/fog_trigger.py {ms} >/tmp/atlas-fog.log 2>&1 &"
        ))
        .status();
    format!("{{\"ok\":true,\"fog_ms\":{ms}}}")
}

pub fn fog_stop() -> String {
    // killing the heartbeat lets the Arduino watchdog cut the fog
    let _ = Command::new("pkill").args(["-f", "fog_trigger.py"]).status();
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
    // makeshow prints "wrote shows/<name>.show.json" on success
    let done_name = log
        .lines()
        .find_map(|l| l.trim().strip_prefix("wrote shows/"))
        .and_then(|s| s.strip_suffix(".show.json"))
        .map(str::to_string);
    let failed = !running && done_name.is_none() && log.contains("FAILED");
    format!(
        "{{\"running\":{},\"done\":{},\"failed\":{},\"name\":{},\"log\":\"{}\"}}",
        running,
        done_name.is_some(),
        failed,
        done_name.map(|n| format!("\"{}\"", json_str(&n))).unwrap_or("null".into()),
        json_str(&tail),
    )
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
