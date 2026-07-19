//! atlas — control the atlas homelab server from the Mac.
//!
//!   atlas              interactive SSH session (execs `ssh atlas`)
//!   atlas boot         Wake-on-LAN, waits until SSH is reachable
//!   atlas shutdown     powers the box off, waits until it is down
//!   atlas restart      reboot, waits for the box to come back
//!   atlas status       is it up? which route (LAN / tailnet)?
//!   atlas <cmd ...>    run any command on atlas (forwarded to ssh)

use std::env;
use std::fs;
use std::io::{self, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs, UdpSocket};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, exit};
use std::thread::sleep;
use std::time::{Duration, Instant};

const SSH_HOST: &str = "atlas";
const MAC: [u8; 6] = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff];
const WOL_BROADCAST: &str = "192.168.1.255:9";
// probed in order; WoL itself only works from inside the LAN
const ROUTES: [(&str, &str); 2] = [
    ("LAN", "192.168.1.100:22"),
    ("tailnet", "atlas.your-tailnet.ts.net:22"),
];

const GREEN: &str = "\x1b[32m";
const RED: &str = "\x1b[31m";
const DIM: &str = "\x1b[2m";
const RESET: &str = "\x1b[0m";

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => ssh(&[]),
        Some("boot") | Some("up") | Some("wake") => boot(),
        Some("shutdown") | Some("off") | Some("poweroff") => shutdown(),
        Some("restart") | Some("reboot") => restart(),
        Some("status") => status(),
        Some("build") => build(&args[1..]),
        Some("help") | Some("-h") | Some("--help") => help(),
        // anything else: run it on atlas (`atlas htop`, `atlas nvidia-smi`, ...)
        Some(_) => ssh(&args),
    }
}

fn help() {
    println!(
        "atlas — Luka's homelab server\n\n\
         USAGE:\n  \
         atlas              SSH into atlas\n  \
         atlas boot         wake via WoL, wait until reachable\n  \
         atlas shutdown     power off, wait until down\n  \
         atlas restart      reboot, wait until back\n  \
         atlas status       up/down + route (LAN/tailnet)\n  \
         atlas build        cross-compile this project on atlas (needs .atlas-build.toml)\n  \
         atlas <cmd ...>    run a command on atlas (e.g. atlas nvidia-smi)"
    );
}

/// Replace this process with ssh — a real interactive session, no wrapper.
fn ssh(remote_cmd: &[String]) -> ! {
    let err = Command::new("ssh")
        .arg("-t")
        .arg(SSH_HOST)
        .args(remote_cmd)
        .exec();
    eprintln!("ssh konnte nicht gestartet werden: {err}");
    exit(1);
}

/// One quick TCP probe of port 22. Returns the route name if reachable.
fn probe() -> Option<&'static str> {
    for (route, host) in ROUTES {
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

fn wait_for(up: bool, timeout: Duration) -> bool {
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

fn send_wol() -> io::Result<()> {
    let mut packet = [0u8; 102]; // 6x 0xff + 16x MAC
    packet[..6].fill(0xff);
    for chunk in packet[6..].chunks_mut(6) {
        chunk.copy_from_slice(&MAC);
    }
    let sock = UdpSocket::bind("0.0.0.0:0")?;
    sock.set_broadcast(true)?;
    for _ in 0..3 {
        sock.send_to(&packet, WOL_BROADCAST)?;
        sleep(Duration::from_millis(100));
    }
    Ok(())
}

fn boot() {
    if let Some(route) = probe() {
        println!("{GREEN}atlas läuft schon{RESET} ({route})");
        return;
    }
    if let Err(e) = send_wol() {
        eprintln!("{RED}WoL-Paket fehlgeschlagen:{RESET} {e}");
        exit(1);
    }
    print!("magic packet gesendet, warte auf boot {DIM}(nur im Heim-LAN möglich){RESET} ");
    io::stdout().flush().ok();
    if wait_for(true, Duration::from_secs(120)) {
        println!(" {GREEN}atlas ist wach{RESET}");
    } else {
        println!(" {RED}timeout{RESET} — nicht im LAN? Sonst: MyFRITZ → Wake");
        exit(1);
    }
}

fn shutdown() {
    if probe().is_none() {
        println!("atlas ist schon aus");
        return;
    }
    // ssh often reports 255 when poweroff drops the connection — ignore the
    // exit code and trust the port-22-down probe instead
    Command::new("ssh")
        .args([SSH_HOST, "sudo poweroff"])
        .output()
        .ok();
    print!("poweroff gesendet, warte ");
    io::stdout().flush().ok();
    if wait_for(false, Duration::from_secs(60)) {
        println!(" {GREEN}atlas ist aus{RESET}");
    } else {
        println!(" {RED}atlas antwortet immer noch{RESET} — bitte manuell prüfen");
        exit(1);
    }
}

fn restart() {
    if probe().is_none() {
        println!("atlas ist aus — nutze `atlas boot`");
        exit(1);
    }
    Command::new("ssh")
        .args([SSH_HOST, "sudo reboot"])
        .output()
        .ok();
    print!("reboot gesendet, warte auf shutdown ");
    io::stdout().flush().ok();
    if !wait_for(false, Duration::from_secs(60)) {
        println!(" {RED}atlas fährt nicht runter{RESET}");
        exit(1);
    }
    print!(" ist unten, warte auf boot ");
    io::stdout().flush().ok();
    if wait_for(true, Duration::from_secs(120)) {
        println!(" {GREEN}atlas ist wieder da{RESET}");
    } else {
        println!(" {RED}timeout beim Hochfahren{RESET}");
        exit(1);
    }
}

fn status() {
    match probe() {
        Some(route) => println!("{GREEN}●{RESET} atlas ist an  {DIM}via {route}{RESET}"),
        None => println!("{RED}●{RESET} atlas ist aus"),
    }
}

// ---- remote build ---------------------------------------------------------

const REMOTE_BASE: &str = "atlas-builds"; // relative to atlas' $HOME
const IMAGE: &str = "atlas-lambda-builder";

struct BuildCfg {
    root: PathBuf,        // dir holding .atlas-build.toml == rsync root
    name: String,         // remote build dir name
    dir: String,          // subdir (relative to root) the build runs in
    build: String,        // build command
    artifacts: Vec<String>, // paths (relative to root) to copy back
}

/// Walk up from cwd to find .atlas-build.toml and parse it.
fn load_config() -> BuildCfg {
    let mut dir = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let file = loop {
        let cand = dir.join(".atlas-build.toml");
        if cand.is_file() {
            break cand;
        }
        if !dir.pop() {
            eprintln!(
                "{RED}kein .atlas-build.toml gefunden{RESET} (hier oder in einem Elternordner)"
            );
            exit(1);
        }
    };
    let text = fs::read_to_string(&file).unwrap_or_default();
    let (mut name, mut build, mut dir_opt, mut artifacts) =
        (String::new(), String::new(), String::from("."), Vec::new());
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let (k, v) = (k.trim(), v.trim());
        match k {
            "name" => name = v.to_string(),
            "build" => build = v.to_string(),
            "dir" => dir_opt = v.to_string(),
            "artifacts" => artifacts = v.split_whitespace().map(String::from).collect(),
            _ => {}
        }
    }
    if name.is_empty() || build.is_empty() || artifacts.is_empty() {
        eprintln!("{RED}.atlas-build.toml unvollständig{RESET} (name, build, artifacts nötig)");
        exit(1);
    }
    BuildCfg {
        root: file.parent().unwrap_or(Path::new(".")).to_path_buf(),
        name,
        dir: dir_opt,
        build,
        artifacts,
    }
}

fn run_inherit(cmd: &mut Command) -> bool {
    cmd.status().map(|s| s.success()).unwrap_or(false)
}

/// atlas must be up for a build — wake it if it is asleep.
fn ensure_up() {
    if probe().is_some() {
        return;
    }
    println!("atlas schläft — wecke ihn ...");
    boot();
}

/// Build the cross-compile image on atlas if it is not there yet.
fn ensure_image() {
    let present = Command::new("ssh")
        .args([SSH_HOST, &format!("docker image inspect {IMAGE} >/dev/null 2>&1")])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if present {
        return;
    }
    println!("{DIM}Build-Image fehlt — baue {IMAGE} auf atlas (einmalig, ein paar Minuten){RESET}");
    let ok = run_inherit(Command::new("ssh").args([
        SSH_HOST,
        "cd ~/atlas && git pull --quiet --ff-only && docker build -t atlas-lambda-builder builder/",
    ]));
    if !ok {
        eprintln!("{RED}Image-Build fehlgeschlagen{RESET}");
        exit(1);
    }
}

fn build(extra: &[String]) {
    let cfg = load_config();
    ensure_up();
    ensure_image();

    // remote working dirs (source tree + persistent cargo registry)
    run_inherit(Command::new("ssh").args([
        SSH_HOST,
        &format!("mkdir -p {REMOTE_BASE}/{0} {REMOTE_BASE}/.cargo-home", cfg.name),
    ]));

    // 1. ship the source (target/.git/node_modules stay on their own sides)
    let src = format!("{}/", cfg.root.display());
    println!("{DIM}sync -> atlas{RESET}");
    let ok = run_inherit(Command::new("rsync").args([
        "-az",
        "--delete",
        "--exclude",
        ".git",
        "--exclude",
        "target",
        "--exclude",
        "node_modules",
        &src,
        &format!("{SSH_HOST}:{REMOTE_BASE}/{}/", cfg.name),
    ]));
    if !ok {
        eprintln!("{RED}rsync -> atlas fehlgeschlagen{RESET}");
        exit(1);
    }

    // 2. cross-compile inside the pinned container (as the caller's uid so the
    //    artifacts come back owned by luka, cargo registry persists)
    let workdir = if cfg.dir == "." {
        "/build".to_string()
    } else {
        format!("/build/{}", cfg.dir)
    };
    let mut buildcmd = cfg.build.clone();
    for a in extra {
        buildcmd.push(' ');
        buildcmd.push_str(a);
    }
    let remote = format!(
        "docker run --rm --user $(id -u):$(id -g) \
         -e CARGO_HOME=/cargo-home -e HOME=/cargo-home \
         -v \"$HOME/{base}/{name}\":/build \
         -v \"$HOME/{base}/.cargo-home\":/cargo-home \
         -w {workdir} {IMAGE} {buildcmd}",
        base = REMOTE_BASE,
        name = cfg.name,
    );
    println!("{DIM}build on atlas:{RESET} {buildcmd}");
    let t0 = Instant::now();
    let ok = run_inherit(Command::new("ssh").args([SSH_HOST, &remote]));
    let secs = t0.elapsed().as_secs();
    if !ok {
        eprintln!("{RED}Build fehlgeschlagen{RESET} (nach {secs}s)");
        exit(1);
    }

    // 3. pull artifacts back into the same relative paths
    println!("{DIM}sync artifacts <- atlas{RESET}");
    for art in &cfg.artifacts {
        let local = cfg.root.join(art);
        fs::create_dir_all(&local).ok();
        run_inherit(Command::new("rsync").args([
            "-az",
            "--delete",
            &format!("{SSH_HOST}:{REMOTE_BASE}/{}/{art}/", cfg.name),
            &format!("{}/", local.display()),
        ]));
    }
    println!(
        "{GREEN}✓ build fertig{RESET} in {}m {}s  {DIM}(atlas, {IMAGE}){RESET}",
        secs / 60,
        secs % 60
    );
    for art in &cfg.artifacts {
        println!("  {} {}", "->", cfg.root.join(art).display());
    }
}
