//! A real terminal over WebSocket: a login shell on a PTY, bytes bridged
//! both ways.
//!
//!   client -> server  binary   keystrokes
//!   client -> server  text     {"resize":{"cols":C,"rows":R}}
//!   server -> client  binary   terminal output

use std::io::{Read, Write};

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::response::Response;
use futures_util::{SinkExt, StreamExt};
use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use serde::Deserialize;
use tokio::sync::mpsc;

pub async fn terminal(ws: WebSocketUpgrade) -> Response {
    ws.on_upgrade(|socket| async move {
        if let Err(e) = session(socket).await {
            tracing::warn!("terminal session ended: {e:#}");
        }
    })
}

#[derive(Deserialize)]
struct Control {
    resize: Size,
}

#[derive(Deserialize)]
struct Size {
    cols: u16,
    rows: u16,
}

async fn session(socket: WebSocket) -> anyhow::Result<()> {
    let pair = native_pty_system().openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })?;
    let mut command = CommandBuilder::new("bash");
    command.arg("-l");
    command.env("TERM", "xterm-256color");
    command.cwd(atlas_core::home());
    let mut child = pair.slave.spawn_command(command)?;
    drop(pair.slave);

    let mut reader = pair.master.try_clone_reader()?;
    let mut writer = pair.master.take_writer()?;

    // PTY reads block, so they get their own thread; the channel closes when
    // the shell exits
    let (output_tx, mut output) = mpsc::channel::<Vec<u8>>(64);
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        while let Ok(n) = reader.read(&mut buf) {
            if n == 0 || output_tx.blocking_send(buf[..n].to_vec()).is_err() {
                break;
            }
        }
    });

    let (mut sink, mut stream) = socket.split();
    loop {
        tokio::select! {
            bytes = output.recv() => match bytes {
                Some(bytes) => {
                    if sink.send(Message::Binary(bytes.into())).await.is_err() {
                        break;
                    }
                }
                None => {
                    let _ = sink.send(Message::Close(None)).await;
                    break;
                }
            },
            message = stream.next() => match message {
                Some(Ok(Message::Binary(keys))) => {
                    if writer.write_all(&keys).and_then(|_| writer.flush()).is_err() {
                        break;
                    }
                }
                Some(Ok(Message::Text(text))) => {
                    if let Ok(Control { resize }) = serde_json::from_str(text.as_str()) {
                        let _ = pair.master.resize(PtySize {
                            rows: resize.rows.clamp(2, 500),
                            cols: resize.cols.clamp(2, 1000),
                            pixel_width: 0,
                            pixel_height: 0,
                        });
                    }
                }
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            },
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    Ok(())
}
