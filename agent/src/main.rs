//! atlas-agent — metrics + a real terminal + docker/lightshow/fog control for
//! the Atlas Command Center iOS app. Binds the tailnet (0.0.0.0:8787).
//!
//!   GET  /health                 -> {"ok":true}
//!   GET  /api/metrics            -> machine snapshot
//!   GET  /term                   -> WebSocket, a real PTY bash
//!   GET  /ws/metrics             -> WebSocket, live metrics frame every 500ms
//!   GET  /api/docker             -> running containers (same as metrics.containers)
//!   GET  /api/docker/<name>      -> inspect one container (state/image/ports/logs)
//!   GET  /api/shows              -> lightshows on disk
//!   POST /api/shows/start        -> start the bridge + play a show  (body: name)
//!   POST /api/shows/stop         -> stop player + bridge
//!   POST /api/fog                -> fog burst                        (body: ms)
//!   GET  /api/lights             -> manual-control state (bridge + 21ch frame)
//!   POST /api/lights/set         -> hold a manual DMX frame          (body: 21 values)
//!   POST /api/lights/off         -> manual frame off / blackout
//!   GET  /api/vpn                -> exit-node stats (tailscale, AdGuard, accumulators)
//!   GET  /api/activity           -> per-day online minutes/boots/commits (heatmap)
//!   POST /api/power/{shutdown,restart}  (require token)
//!
//! Auth: if ATLAS_AGENT_TOKEN is set, every request needs
//! `Authorization: Bearer <token>` (WS may pass ?token=…). Power/actions that
//! change state always need the token when one is configured.

mod actions;
mod activity;
mod metrics;
mod stream;
mod terminal;
mod vpn;

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::Command;
use std::thread;

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
    vpn::start_sampler();
    stream::start_sampler();   // 10-min Metrics-History ab Boot
    println!(
        "atlas-agent {} on :{port} (auth: {})",
        env!("CARGO_PKG_VERSION"),
        if token.is_some() { "token" } else { "open/tailnet" }
    );

    for stream in listener.incoming().flatten() {
        let token = token.clone();
        thread::spawn(move || handle(stream, token.as_deref()));
    }
}

struct Req {
    method: String,
    path: String,
    query: String,
    auth: Option<String>,
    ws_key: Option<String>,
    body: String,
}

fn handle(mut stream: TcpStream, token: Option<&str>) {
    let Some(req) = parse_request(&mut stream) else { return };

    // token gate (header bearer, or ?token= for the WebSocket)
    let provided = req
        .auth
        .as_deref()
        .and_then(|a| a.strip_prefix("Bearer ").or_else(|| a.strip_prefix("bearer ")))
        .map(str::trim)
        .map(str::to_string)
        .or_else(|| query_param(&req.query, "token"));
    let authed = matches!((token, provided.as_deref()), (Some(t), Some(p)) if t == p);
    if token.is_some() && !authed {
        return respond(&mut stream, 401, r#"{"error":"unauthorized"}"#);
    }
    // when no token is configured, tailnet isolation is the boundary; still
    // require an explicit token for anything that changes machine state.
    let can_act = token.is_none() || authed;

    match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/health") => respond(&mut stream, 200, r#"{"ok":true}"#),
        ("GET", "/api/metrics") | ("GET", "/") => {
            respond(&mut stream, 200, &metrics::collect())
        }
        ("GET", "/term") if req.ws_key.is_some() => {
            terminal::serve(stream, &req.ws_key.unwrap());
        }
        ("GET", "/ws/metrics") if req.ws_key.is_some() => {
            crate::stream::handle_ws(stream, &req.ws_key.unwrap());
        }
        ("GET", "/api/docker") => respond(&mut stream, 200, &actions::containers()),
        ("GET", p) if p.starts_with("/api/docker/") => {
            let name = &p["/api/docker/".len()..];
            respond(&mut stream, 200, &actions::inspect(name));
        }
        ("GET", "/api/shows") => respond(&mut stream, 200, &actions::shows()),
        ("GET", "/api/shows/create/status") => {
            respond(&mut stream, 200, &actions::create_status());
        }
        ("GET", "/api/shows/create/thumb") => match actions::create_thumb() {
            Some(p) => serve_file(&mut stream, &p),
            None => respond(&mut stream, 404, r#"{"error":"no thumb"}"#),
        },
        ("GET", p) if p.starts_with("/api/shows/thumb/") => {
            let name = &p["/api/shows/thumb/".len()..];
            match actions::show_thumb(name) {
                Some(path) => serve_file(&mut stream, &path),
                None => respond(&mut stream, 404, r#"{"error":"no thumb"}"#),
            }
        }
        ("POST", "/api/shows/create") if can_act => {
            respond(&mut stream, 200, &actions::show_create(req.body.trim()));
        }
        ("POST", "/api/shows/start") if can_act => {
            respond(&mut stream, 200, &actions::show_start(req.body.trim()));
        }
        ("POST", "/api/shows/stop") if can_act => {
            respond(&mut stream, 200, &actions::show_stop());
        }
        ("POST", "/api/bridge/stop") if can_act => {
            respond(&mut stream, 200, &actions::bridge_stop());
        }
        ("GET", "/api/calibrate") => respond(&mut stream, 200, &actions::calibrate_get()),
        ("POST", "/api/calibrate/save") if can_act => {
            respond(&mut stream, 200, &actions::calibrate_save(&req.body));
        }
        ("GET", p) if p.starts_with("/api/shows/audio/") => {
            let name = &p["/api/shows/audio/".len()..];
            match actions::audio_file(name) {
                Some(path) => serve_file(&mut stream, &path),
                None => respond(&mut stream, 404, r#"{"error":"no audio"}"#),
            }
        }
        ("POST", "/api/fog") if can_act => {
            let ms: u64 = req.body.trim().parse().unwrap_or(1200);
            respond(&mut stream, 200, &actions::fog(ms));
        }
        ("POST", "/api/fog/stop") if can_act => {
            respond(&mut stream, 200, &actions::fog_stop());
        }
        ("GET", "/api/lights") => respond(&mut stream, 200, &actions::lights_get()),
        ("POST", "/api/lights/set") if can_act => {
            respond(&mut stream, 200, &actions::lights_set(&req.body));
        }
        ("POST", "/api/lights/off") if can_act => {
            respond(&mut stream, 200, &actions::lights_off());
        }
        ("GET", "/api/vpn") => respond(&mut stream, 200, &vpn::vpn()),
        ("GET", "/api/activity") => respond(&mut stream, 200, &activity::activity()),
        ("POST", "/api/power/shutdown") if can_act => power(&mut stream, "poweroff"),
        ("POST", "/api/power/restart") if can_act => power(&mut stream, "reboot"),
        ("POST", _) => respond(&mut stream, 403, r#"{"error":"a token is required for this action"}"#),
        _ => respond(&mut stream, 404, r#"{"error":"not found"}"#),
    }
}

fn parse_request(stream: &mut TcpStream) -> Option<Req> {
    let mut reader = BufReader::new(stream.try_clone().ok()?);
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let mut parts = line.split_whitespace();
    let method = parts.next()?.to_string();
    let target = parts.next().unwrap_or("/");
    let (path, query) = target.split_once('?').unwrap_or((target, ""));

    let mut auth = None;
    let mut ws_key = None;
    let mut content_len = 0usize;
    loop {
        let mut h = String::new();
        if reader.read_line(&mut h).ok()? == 0 || h == "\r\n" || h == "\n" {
            break;
        }
        let Some((name, val)) = h.split_once(':') else { continue };
        match name.trim().to_ascii_lowercase().as_str() {
            "authorization" => auth = Some(val.trim().to_string()),
            "sec-websocket-key" => ws_key = Some(val.trim().to_string()),
            "content-length" => content_len = val.trim().parse().unwrap_or(0),
            _ => {}
        }
    }
    let mut body = String::new();
    if content_len > 0 {
        let mut buf = vec![0u8; content_len.min(16_384)];
        reader.read_exact(&mut buf).ok()?;
        body = String::from_utf8_lossy(&buf).into_owned();
    }
    Some(Req {
        method,
        path: path.to_string(),
        query: query.to_string(),
        auth,
        ws_key,
        body,
    })
}

fn query_param(query: &str, key: &str) -> Option<String> {
    query.split('&').find_map(|kv| {
        let (k, v) = kv.split_once('=')?;
        (k == key).then(|| v.to_string())
    })
}

fn power(stream: &mut TcpStream, what: &str) {
    respond(stream, 200, &format!(r#"{{"ok":true,"action":"{what}"}}"#));
    let _ = Command::new("sh")
        .arg("-c")
        .arg(format!("sleep 1; sudo {what}"))
        .spawn();
}

fn serve_file(stream: &mut TcpStream, path: &std::path::Path) {
    let Ok(bytes) = std::fs::read(path) else {
        return respond(stream, 404, r#"{"error":"read failed"}"#);
    };
    let ctype = match path.extension().and_then(|e| e.to_str()) {
        Some("mp3") => "audio/mpeg",
        Some("m4a") | Some("aac") => "audio/mp4",
        Some("opus") | Some("webm") => "audio/webm",
        Some("wav") => "audio/wav",
        Some("flac") => "audio/flac",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("png") => "image/png",
        _ => "application/octet-stream",
    };
    let header = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nAccept-Ranges: none\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        bytes.len()
    );
    let _ = stream.write_all(header.as_bytes());
    let _ = stream.write_all(&bytes);
    let _ = stream.flush();
}

pub fn respond(stream: &mut TcpStream, code: u16, body: &str) {
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
