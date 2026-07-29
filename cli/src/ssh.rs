//! The ssh/rsync boundary: connection helpers, the probe/WoL primitives, and
//! `shq` shell-quoting.
//!
//! ControlMaster multiplexing lives entirely in `~/.ssh/config`
//! (ControlMaster/ControlPath ~/.ssh/cm/%r@%h:%p/ControlPersist). Nothing here
//! sets a conflicting `-o ControlMaster` or `-S`; every call is a plain
//! `ssh <host> <cmd>` so the shared master socket is reused.

use std::io::{self, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs, UdpSocket};
use std::os::unix::process::CommandExt;
use std::process::{Command, exit};
use std::thread::sleep;
use std::time::{Duration, Instant};

use crate::config::{config, ssh_host};
use crate::machine::boot;
use crate::{DIM, RESET};

/// Replace this process with ssh — a real interactive session, no wrapper.
pub(crate) fn ssh(remote_cmd: &[String]) -> ! {
    let err = Command::new("ssh")
        .arg("-t")
        .arg(ssh_host())
        .args(remote_cmd)
        .exec();
    eprintln!("ssh could not be started: {err}");
    exit(1);
}

/// One quick TCP probe of port 22. Returns the route name if reachable.
pub(crate) fn probe() -> Option<&'static str> {
    let cfg = config();
    // probed in order; WoL itself only works from inside the LAN
    for (route, host) in [
        ("LAN", cfg.lan_addr.as_str()),
        ("tailnet", cfg.tailnet_addr.as_str()),
    ] {
        if host.is_empty() {
            continue; // route disabled via config
        }
        let addrs: Vec<SocketAddr> = match host.to_socket_addrs() {
            Ok(a) => a.collect(),
            Err(_) => continue, // e.g. tailnet DNS not available right now
        };
        for addr in addrs {
            if TcpStream::connect_timeout(&addr, Duration::from_millis(700)).is_ok() {
                return Some(route);
            }
        }
    }
    None
}

pub(crate) fn wait_for(up: bool, timeout: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if (probe().is_some()) == up {
            return true;
        }
        print!(".");
        io::stdout().flush().ok();
        sleep(Duration::from_secs(2));
    }
    false
}

pub(crate) fn send_wol() -> io::Result<()> {
    let cfg = config();
    let mut packet = [0u8; 102]; // 6x 0xff + 16x MAC
    packet[..6].fill(0xff);
    for chunk in packet[6..].chunks_mut(6) {
        chunk.copy_from_slice(&cfg.wol_mac);
    }
    let sock = UdpSocket::bind("0.0.0.0:0")?;
    sock.set_broadcast(true)?;
    for _ in 0..3 {
        sock.send_to(&packet, cfg.wol_broadcast.as_str())?;
        sleep(Duration::from_millis(100));
    }
    Ok(())
}

pub(crate) fn run_inherit(cmd: &mut Command) -> bool {
    cmd.status().map(|s| s.success()).unwrap_or(false)
}

pub(crate) fn ssh_ok(remote: &str) -> bool {
    Command::new("ssh")
        .args([ssh_host(), remote])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub(crate) fn ssh_capture(remote: &str) -> String {
    Command::new("ssh")
        .args([ssh_host(), remote])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

/// Single-quote a string for a POSIX shell (protects &&, spaces, ...).
pub(crate) fn shq(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// atlas must be up — wake it if it is asleep.
pub(crate) fn ensure_up() {
    if probe().is_some() {
        return;
    }
    println!("{DIM}atlas is asleep — waking it ...{RESET}");
    boot();
}
