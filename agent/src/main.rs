//! atlas-agent — metrics + a real terminal + docker/lightshow/fog control for
//! the Atlas Command Center iOS app.
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
//!   POST /api/power/{shutdown,restart}
//!
//! Auth: if ATLAS_AGENT_TOKEN is set, every request needs
//! `Authorization: Bearer <token>` (WS may pass ?token=…). Without a token,
//! read-only GETs are served, but state-changing routes — the PTY terminal
//! and everything non-GET — are refused unless ATLAS_AGENT_OPEN=1 explicitly
//! opts into trusting the network (tailnet + firewall) instead.

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
use std::time::Duration;

/// DoS guards for the hand-rolled parser: no request/header line may exceed
/// MAX_LINE bytes and a request may not carry more than MAX_HEADERS headers.
const MAX_LINE: usize = 8 * 1024;
const MAX_HEADERS: usize = 64;

fn main() {
    // ATLAS_AGENT_PORT: listen port (default 8787)
    let port: u16 = std::env::var("ATLAS_AGENT_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8787);
    // ATLAS_AGENT_TOKEN: bearer token; when set, required on every request
    let token = std::env::var("ATLAS_AGENT_TOKEN").ok().filter(|t| !t.is_empty());
    // ATLAS_AGENT_OPEN=1: explicitly allow state-changing routes without a
    // token, for deployments where the tailnet/firewall is the only boundary
    let open = std::env::var("ATLAS_AGENT_OPEN").is_ok_and(|v| v == "1");
    // ATLAS_AGENT_BIND: full listen address (e.g. "127.0.0.1:8787" or a
    // tailscale IP), overrides ATLAS_AGENT_PORT. Rely on the tailnet and a
    // firewall for reachability — never port-forward this service.
    let bind = std::env::var("ATLAS_AGENT_BIND")
        .ok()
        .filter(|b| !b.is_empty())
        .unwrap_or_else(|| format!("0.0.0.0:{port}"));

    let listener = TcpListener::bind(bind.as_str()).unwrap_or_else(|e| {
        eprintln!("atlas-agent: cannot bind {bind}: {e}");
        std::process::exit(1);
    });
    vpn::start_sampler();
    stream::start_sampler(); // 10-min metrics history from boot
    println!(
        "atlas-agent {} on {bind} (auth: {})",
        env!("CARGO_PKG_VERSION"),
        if token.is_some() {
            "token"
        } else if open {
            "OPEN — no token, state changes allowed (ATLAS_AGENT_OPEN=1)"
        } else {
            "no token — read-only, state-changing routes refused"
        }
    );

    for stream in listener.incoming().flatten() {
        let token = token.clone();
        thread::spawn(move || handle(stream, token.as_deref(), open));
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

fn handle(mut stream: TcpStream, token: Option<&str>, open: bool) {
    // slow or stalled clients get dropped instead of holding a thread forever
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(30)));
    let Some(req) = parse_request(&mut stream) else { return };

    // token gate (header bearer, or ?token= for the WebSocket)
    let provided = req
        .auth
        .as_deref()
        .and_then(|a| a.strip_prefix("Bearer ").or_else(|| a.strip_prefix("bearer ")))
        .map(str::trim)
        .map(str::to_string)
        .or_else(|| query_param(&req.query, "token"));
    let authed = matches!((token, provided.as_deref()), (Some(t), Some(p)) if ct_eq(t, p));
    if token.is_some() && !authed {
        return respond(&mut stream, 401, r#"{"error":"unauthorized"}"#);
    }
    // State-changing surface: the PTY terminal and everything non-GET.
    // Without a configured token these fail closed; ATLAS_AGENT_OPEN=1 is the
    // explicit opt-in for tailnet-trust open mode.
    let mutating = req.method != "GET" || req.path == "/term";
    let can_act = authed || (token.is_none() && open);
    if mutating && !can_act {
        return respond(
            &mut stream,
            403,
            r#"{"error":"this route changes state: set ATLAS_AGENT_TOKEN (or ATLAS_AGENT_OPEN=1 to explicitly trust the network instead)"}"#,
        );
    }

    match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/health") => respond(&mut stream, 200, r#"{"ok":true}"#),
        ("GET", "/api/metrics") | ("GET", "/") => {
            respond(&mut stream, 200, &metrics::collect())
        }
        ("GET", "/term") if req.ws_key.is_some() => {
            clear_timeouts(&stream); // long-lived WebSocket
            terminal::serve(stream, &req.ws_key.unwrap());
        }
        ("GET", "/ws/metrics") if req.ws_key.is_some() => {
            clear_timeouts(&stream); // long-lived WebSocket
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
        ("POST", "/api/shows/create") => {
            respond(&mut stream, 200, &actions::show_create(req.body.trim()));
        }
        ("POST", "/api/shows/start") => {
            respond(&mut stream, 200, &actions::show_start(req.body.trim()));
        }
        ("POST", "/api/shows/stop") => {
            respond(&mut stream, 200, &actions::show_stop());
        }
        ("POST", "/api/bridge/stop") => {
            respond(&mut stream, 200, &actions::bridge_stop());
        }
        ("GET", "/api/calibrate") => respond(&mut stream, 200, &actions::calibrate_get()),
        ("POST", "/api/calibrate/save") => {
            respond(&mut stream, 200, &actions::calibrate_save(&req.body));
        }
        ("GET", p) if p.starts_with("/api/shows/audio/") => {
            let name = &p["/api/shows/audio/".len()..];
            match actions::audio_file(name) {
                Some(path) => serve_file(&mut stream, &path),
                None => respond(&mut stream, 404, r#"{"error":"no audio"}"#),
            }
        }
        ("POST", "/api/fog") => {
            let ms: u64 = req.body.trim().parse().unwrap_or(1200);
            respond(&mut stream, 200, &actions::fog(ms));
        }
        ("POST", "/api/fog/stop") => {
            respond(&mut stream, 200, &actions::fog_stop());
        }
        ("GET", "/api/lights") => respond(&mut stream, 200, &actions::lights_get()),
        ("POST", "/api/lights/set") => {
            respond(&mut stream, 200, &actions::lights_set(&req.body));
        }
        ("POST", "/api/lights/off") => {
            respond(&mut stream, 200, &actions::lights_off());
        }
        ("GET", "/api/vpn") => respond(&mut stream, 200, &vpn::vpn()),
        ("GET", "/api/activity") => respond(&mut stream, 200, &activity::activity()),
        ("POST", "/api/power/shutdown") => power(&mut stream, "poweroff"),
        ("POST", "/api/power/restart") => power(&mut stream, "reboot"),
        _ => respond(&mut stream, 404, r#"{"error":"not found"}"#),
    }
}

/// Constant-time equality (XOR-fold): the comparison time does not depend on
/// where the strings first differ, so the bearer token cannot be probed
/// byte-by-byte via response timing.
fn ct_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |d, (x, y)| d | (x ^ y)) == 0
}

/// The parse-phase socket timeouts would kill a long-lived WebSocket.
fn clear_timeouts(stream: &TcpStream) {
    let _ = stream.set_read_timeout(None);
    let _ = stream.set_write_timeout(None);
}

/// One line, capped at MAX_LINE bytes — a line that never ends kills the
/// connection instead of growing a String without bound.
fn read_line_capped(reader: &mut BufReader<TcpStream>) -> Option<String> {
    let mut line = String::new();
    let n = reader.by_ref().take(MAX_LINE as u64).read_line(&mut line).ok()?;
    if n == MAX_LINE && !line.ends_with('\n') {
        return None; // over-long line
    }
    Some(line)
}

fn parse_request(stream: &mut TcpStream) -> Option<Req> {
    let mut reader = BufReader::new(stream.try_clone().ok()?);
    let line = read_line_capped(&mut reader)?;
    let mut parts = line.split_whitespace();
    let method = parts.next()?.to_string();
    let target = parts.next().unwrap_or("/");
    let (path, query) = target.split_once('?').unwrap_or((target, ""));

    let mut auth = None;
    let mut ws_key = None;
    let mut content_len = 0usize;
    let mut headers = 0usize;
    loop {
        let h = read_line_capped(&mut reader)?;
        if h.is_empty() || h == "\r\n" || h == "\n" {
            break;
        }
        headers += 1;
        if headers > MAX_HEADERS {
            return None;
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
