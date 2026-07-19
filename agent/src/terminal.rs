//! A real terminal over WebSocket: spawn a PTY bash and bridge bytes both ways.
//!
//! Protocol (after the WS handshake):
//!   client -> server  Binary  = raw keystrokes into the PTY
//!   client -> server  Text    = a control message, {"resize":{"cols":C,"rows":R}}
//!   server -> client  Binary  = raw PTY output

use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::{Arc, Mutex};
use std::thread;

use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use tungstenite::handshake::derive_accept_key;
use tungstenite::protocol::Role;
use tungstenite::{Message, WebSocket};

pub fn serve(mut stream: TcpStream, ws_key: &str) {
    // finish the WebSocket handshake on the already-parsed request
    let accept = derive_accept_key(ws_key.as_bytes());
    let resp = format!(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
    );
    if stream.write_all(resp.as_bytes()).is_err() {
        return;
    }
    let _ = stream.flush();

    // open a PTY and spawn a login shell in the user's home
    let pty = native_pty_system();
    let Ok(pair) = pty.openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
    else {
        return;
    };
    let mut cmd = CommandBuilder::new("bash");
    cmd.arg("-l");
    cmd.env("TERM", "xterm-256color");
    if let Ok(home) = std::env::var("HOME") {
        cmd.cwd(home);
    }
    let Ok(mut child) = pair.slave.spawn_command(cmd) else {
        return;
    };
    drop(pair.slave); // parent doesn't need the slave end

    let Ok(mut pty_reader) = pair.master.try_clone_reader() else { return };
    let Ok(mut pty_writer) = pair.master.take_writer() else { return };

    // two WebSocket views of the same socket: one only reads client frames,
    // one only writes server frames (opposite TCP directions, so no shared
    // state). The writer is shared (data + pong) behind a mutex.
    let Ok(sock_r) = stream.try_clone() else { return };
    let mut ws_read = WebSocket::from_raw_socket(sock_r, Role::Server, None);
    let ws_write = Arc::new(Mutex::new(WebSocket::from_raw_socket(stream, Role::Server, None)));

    // PTY output -> client
    let ws_out = ws_write.clone();
    let pump = thread::spawn(move || {
        let mut buf = [0u8; 8192];
        loop {
            match pty_reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let mut w = ws_out.lock().unwrap();
                    if w.write_message(Message::Binary(buf[..n].to_vec())).is_err() {
                        break;
                    }
                    let _ = w.flush();
                }
            }
        }
        // shell ended -> tell the client
        if let Ok(mut w) = ws_out.lock() {
            let _ = w.write_message(Message::Close(None));
            let _ = w.flush();
        }
    });

    // client -> PTY (keystrokes + resize control)
    loop {
        match ws_read.read_message() {
            Ok(Message::Binary(d)) => {
                if pty_writer.write_all(&d).is_err() {
                    break;
                }
                let _ = pty_writer.flush();
            }
            Ok(Message::Text(t)) => {
                if let Some((cols, rows)) = parse_resize(&t) {
                    let _ = pair.master.resize(PtySize {
                        rows,
                        cols,
                        pixel_width: 0,
                        pixel_height: 0,
                    });
                }
            }
            Ok(Message::Ping(p)) => {
                if let Ok(mut w) = ws_write.lock() {
                    let _ = w.write_message(Message::Pong(p));
                    let _ = w.flush();
                }
            }
            Ok(Message::Close(_)) | Err(_) => break,
            _ => {}
        }
    }

    let _ = child.kill();
    let _ = pump.join();
}

/// Pull cols/rows out of {"resize":{"cols":C,"rows":R}} without a JSON dep.
fn parse_resize(t: &str) -> Option<(u16, u16)> {
    let num = |key: &str| -> Option<u16> {
        let i = t.find(key)? + key.len();
        let after = t[i..].trim_start_matches([':', ' ', '"']);
        let digits: String = after.chars().take_while(|c| c.is_ascii_digit()).collect();
        digits.parse().ok()
    };
    Some((num("\"cols\"")?, num("\"rows\"")?))
}
