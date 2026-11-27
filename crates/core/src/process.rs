//! External tools (ffmpeg, ffprobe, pdftotext, ...) with a deadline and bounded
//! pipe buffers. A tool that hangs on a broken file is killed, and noisy tools
//! cannot exhaust server memory before the deadline expires.

use std::io::{Error, ErrorKind, Read, Result};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

/// Default cap per pipe (`stdout` / `stderr`): 64 MiB.
pub const DEFAULT_MAX_PIPE_BYTES: usize = 64 * 1024 * 1024;

/// Runs `cmd` like [`Command::output`], killing it after `limit` and capping
/// captured `stdout`/`stderr` at [`DEFAULT_MAX_PIPE_BYTES`].
pub fn output(cmd: &mut Command, limit: Duration) -> Result<Output> {
    output_bounded(cmd, limit, DEFAULT_MAX_PIPE_BYTES)
}

/// Runs `cmd` with both a wall-clock `limit` and a per-pipe byte cap `max_bytes`.
/// Any excess output beyond `max_bytes` is discarded into `io::sink()` so the
/// child never deadlocks on a full OS pipe while memory stays strictly bounded.
pub fn output_bounded(cmd: &mut Command, limit: Duration, max_bytes: usize) -> Result<Output> {
    let program = cmd.get_program().to_string_lossy().into_owned();
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| Error::new(e.kind(), format!("cannot run {program}: {e}")))?;

    let drain = move |pipe: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            if let Some(mut pipe) = pipe {
                let _ = pipe.by_ref().take(max_bytes as u64).read_to_end(&mut bytes);
                let _ = std::io::copy(&mut pipe, &mut std::io::sink());
            }
            bytes
        })
    };
    let stdout = drain(
        child
            .stdout
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );
    let stderr = drain(
        child
            .stderr
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );
    let deadline = Instant::now() + limit;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            let _ = (stdout.join(), stderr.join());
            return Err(Error::new(
                ErrorKind::TimedOut,
                format!("{program} ran longer than {limit:?} and was stopped"),
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    Ok(Output {
        status,
        stdout: stdout.join().unwrap_or_default(),
        stderr: stderr.join().unwrap_or_default(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn returns_what_the_tool_printed() {
        let out = output(
            Command::new("sh").args(["-c", "echo out; echo err >&2"]),
            Duration::from_secs(5),
        )
        .unwrap();
        assert!(out.status.success());
        assert_eq!(out.stdout, b"out\n");
        assert_eq!(out.stderr, b"err\n");
    }

    #[test]
    fn caps_excess_pipe_output_without_stalling_the_child() {
        let out = output_bounded(
            Command::new("sh").args(["-c", "dd if=/dev/zero bs=1024 count=64 2>/dev/null"]),
            Duration::from_secs(5),
            4096,
        )
        .unwrap();
        assert!(out.status.success());
        assert_eq!(out.stdout.len(), 4096);
    }

    #[test]
    fn stops_a_tool_that_hangs() {
        let started = Instant::now();
        let err = output(Command::new("sleep").arg("30"), Duration::from_millis(200)).unwrap_err();
        assert_eq!(err.kind(), ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn a_missing_tool_is_an_error() {
        assert!(
            output(
                &mut Command::new("no-such-tool-anywhere"),
                Duration::from_secs(1)
            )
            .is_err()
        );
    }
}
