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
        Some("dev") => dev(&args[1..]),
        Some("agent") => agent(&args[1..]),
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
         atlas build        build this project on atlas (needs .atlas-build.toml)\n  \
         atlas dev          run its dev server on atlas + public tunnel URL\n  \
         atlas dev stop     stop the dev server + tunnel\n  \
         atlas dev logs     follow the dev-server logs\n  \
         atlas agent        build+install the metrics agent (for the iOS app)\n  \
         atlas agent logs   follow the agent logs   ·   agent status/stop\n  \
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

// ---- remote build & dev ---------------------------------------------------

const REMOTE_BASE: &str = "atlas-builds"; // relative to atlas' $HOME

struct BuildCfg {
    root: PathBuf,          // dir holding .atlas-build.toml == rsync root
    name: String,           // remote build dir name
    image: String,          // builder key: lambda | node | flutter
    dir: String,            // subdir (relative to root) the build runs in
    build: String,          // build command (for `atlas build`)
    dev: String,            // dev-server command (for `atlas dev`)
    port: u16,              // dev-server port to tunnel
    artifacts: Vec<String>, // paths (relative to root) to copy back
}

impl BuildCfg {
    fn tag(&self) -> String {
        format!("atlas-{}-builder", self.image)
    }
    fn workdir(&self) -> String {
        if self.dir == "." {
            "/build".into()
        } else {
            format!("/build/{}", self.dir)
        }
    }
    fn remote_dir(&self) -> String {
        format!("{REMOTE_BASE}/{}", self.name)
    }
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
            eprintln!("{RED}kein .atlas-build.toml gefunden{RESET} (hier oder in einem Elternordner)");
            exit(1);
        }
    };
    let text = fs::read_to_string(&file).unwrap_or_default();
    let mut c = BuildCfg {
        root: file.parent().unwrap_or(Path::new(".")).to_path_buf(),
        name: String::new(),
        image: String::new(),
        dir: ".".into(),
        build: String::new(),
        dev: String::new(),
        port: 3000,
        artifacts: Vec::new(),
    };
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
            "name" => c.name = v.into(),
            "image" => c.image = v.into(),
            "dir" => c.dir = v.into(),
            "build" => c.build = v.into(),
            "dev" => c.dev = v.into(),
            "port" => c.port = v.parse().unwrap_or(3000),
            "artifacts" => c.artifacts = v.split_whitespace().map(String::from).collect(),
            _ => {}
        }
    }
    if c.name.is_empty() || c.image.is_empty() {
        eprintln!("{RED}.atlas-build.toml unvollständig{RESET} (name, image nötig)");
        exit(1);
    }
    c
}

fn run_inherit(cmd: &mut Command) -> bool {
    cmd.status().map(|s| s.success()).unwrap_or(false)
}

fn ssh_ok(remote: &str) -> bool {
    Command::new("ssh")
        .args([SSH_HOST, remote])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn ssh_capture(remote: &str) -> String {
    Command::new("ssh")
        .args([SSH_HOST, remote])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

/// Single-quote a string for a POSIX shell (protects &&, spaces, ...).
fn shq(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// atlas must be up — wake it if it is asleep.
fn ensure_up() {
    if probe().is_some() {
        return;
    }
    println!("atlas schläft — wecke ihn ...");
    boot();
}

/// Build the builder image for `key` on atlas if it is not there yet.
fn ensure_image(key: &str) {
    let tag = format!("atlas-{key}-builder");
    if ssh_ok(&format!("docker image inspect {tag} >/dev/null 2>&1")) {
        return;
    }
    println!("{DIM}Image {tag} fehlt — baue es auf atlas (einmalig, ein paar Minuten){RESET}");
    let ok = run_inherit(Command::new("ssh").args([
        SSH_HOST,
        &format!("cd ~/atlas && git pull --quiet --ff-only && docker build -t {tag} builder/{key}"),
    ]));
    if !ok {
        eprintln!("{RED}Image-Build fehlgeschlagen{RESET}");
        exit(1);
    }
}

/// rsync the project tree to atlas (outputs/caches stay on their own sides).
fn sync_to_atlas(cfg: &BuildCfg) {
    run_inherit(Command::new("ssh").args([
        SSH_HOST,
        &format!("mkdir -p {} {REMOTE_BASE}/.cache-{}", cfg.remote_dir(), cfg.image),
    ]));
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
        "--exclude",
        ".next",
        "--exclude",
        "build",
        &format!("{}/", cfg.root.display()),
        &format!("{SSH_HOST}:{}/", cfg.remote_dir()),
    ]));
    if !ok {
        eprintln!("{RED}rsync -> atlas fehlgeschlagen{RESET}");
        exit(1);
    }
}

fn build(extra: &[String]) {
    let cfg = load_config();
    if cfg.build.is_empty() || cfg.artifacts.is_empty() {
        eprintln!("{RED}.atlas-build.toml hat kein build/artifacts{RESET}");
        exit(1);
    }
    ensure_up();
    ensure_image(&cfg.image);
    sync_to_atlas(&cfg);

    let mut buildcmd = cfg.build.clone();
    for a in extra {
        buildcmd.push(' ');
        buildcmd.push_str(a);
    }
    // Run as root inside the container (works for every base image, incl.
    // flutter's SDK dir), then chown the tree back to luka so the next Mac
    // rsync and the artifact pull don't trip over root-owned files. `; rc=$?`
    // keeps the build's exit code even though the chown always runs.
    let remote = format!(
        "docker run --rm \
         -e CARGO_HOME=/cache/cargo -e npm_config_cache=/cache/npm \
         -e PUB_CACHE=/cache/pub -e XDG_CACHE_HOME=/cache/xdg \
         -e GRADLE_USER_HOME=/cache/gradle \
         -v \"$HOME/{dir}\":/build -v \"$HOME/{base}/.cache-{img}\":/cache \
         -w {wd} {tag} sh -c {cmd}; rc=$?; \
         sudo chown -R $(id -u):$(id -g) \"$HOME/{dir}\" >/dev/null 2>&1; exit $rc",
        dir = cfg.remote_dir(),
        base = REMOTE_BASE,
        img = cfg.image,
        wd = cfg.workdir(),
        tag = cfg.tag(),
        cmd = shq(&buildcmd),
    );
    println!("{DIM}build on atlas ({}):{RESET} {buildcmd}", cfg.tag());
    let t0 = Instant::now();
    let ok = run_inherit(Command::new("ssh").args([SSH_HOST, &remote]));
    let secs = t0.elapsed().as_secs();
    if !ok {
        eprintln!("{RED}Build fehlgeschlagen{RESET} (nach {secs}s)");
        exit(1);
    }

    println!("{DIM}sync artifacts <- atlas{RESET}");
    for art in &cfg.artifacts {
        let local = cfg.root.join(art);
        fs::create_dir_all(&local).ok();
        run_inherit(Command::new("rsync").args([
            "-az",
            "--delete",
            &format!("{SSH_HOST}:{}/{art}/", cfg.remote_dir()),
            &format!("{}/", local.display()),
        ]));
    }
    println!(
        "{GREEN}✓ build fertig{RESET} in {}m {:02}s  {DIM}(atlas, {}){RESET}",
        secs / 60,
        secs % 60,
        cfg.tag()
    );
    for art in &cfg.artifacts {
        println!("  → {}", cfg.root.join(art).display());
    }
}

// ---- atlas dev: run a dev server on atlas behind a public tunnel ----------

fn dev(sub: &[String]) {
    let cfg = load_config();
    match sub.first().map(String::as_str) {
        Some("stop") => dev_stop(&cfg),
        Some("url") => println!("{}", dev_url(&cfg).unwrap_or_else(|| "(kein Tunnel aktiv)".into())),
        Some("logs") => dev_logs(&cfg),
        _ => dev_start(&cfg),
    }
}

fn dev_names(cfg: &BuildCfg) -> (String, String) {
    (format!("atlas-dev-{}", cfg.name), format!("atlas-tunnel-{}", cfg.name))
}

/// Scrape the public URL out of the tunnel container's logs.
fn dev_url(cfg: &BuildCfg) -> Option<String> {
    let (_, tunnel) = dev_names(cfg);
    let out = ssh_capture(&format!(
        "docker logs {tunnel} 2>&1 | grep -oE 'https://[a-z0-9-]+\\.trycloudflare\\.com' | head -1"
    ));
    let url = out.trim();
    if url.is_empty() { None } else { Some(url.to_string()) }
}

fn dev_stop(cfg: &BuildCfg) {
    let (dev, tunnel) = dev_names(cfg);
    ssh_ok(&format!("docker rm -f {dev} {tunnel} >/dev/null 2>&1"));
    println!("{GREEN}dev gestoppt{RESET} ({})", cfg.name);
}

fn dev_logs(cfg: &BuildCfg) -> ! {
    let (dev, _) = dev_names(cfg);
    let err = Command::new("ssh")
        .args(["-t", SSH_HOST, &format!("docker logs -f {dev}")])
        .exec();
    eprintln!("ssh: {err}");
    exit(1);
}

fn dev_start(cfg: &BuildCfg) {
    if cfg.dev.is_empty() {
        eprintln!("{RED}.atlas-build.toml hat kein dev = ...{RESET}");
        exit(1);
    }
    ensure_up();
    ensure_image(&cfg.image);
    sync_to_atlas(cfg);
    let (dev, tunnel) = dev_names(cfg);

    // fresh start
    ssh_ok(&format!("docker rm -f {dev} {tunnel} >/dev/null 2>&1"));

    // dev server: --network host so it binds atlas' real port; node_modules
    // persist in the synced dir, so `npm install` is warm after the first run.
    let devcmd = format!("npm install --no-fund --no-audit && {}", cfg.dev);
    let run_dev = format!(
        "docker run -d --name {dev} --network host --restart unless-stopped \
         -e npm_config_cache=/cache/npm -e HOST=0.0.0.0 -e PORT={port} \
         -v \"$HOME/{rdir}\":/build -v \"$HOME/{base}/.cache-{img}\":/cache \
         -w {wd} {tag} sh -c {cmd} >/dev/null",
        port = cfg.port,
        rdir = cfg.remote_dir(),
        base = REMOTE_BASE,
        img = cfg.image,
        wd = cfg.workdir(),
        tag = cfg.tag(),
        cmd = shq(&devcmd),
    );
    if !ssh_ok(&run_dev) {
        eprintln!("{RED}dev-Container-Start fehlgeschlagen{RESET}");
        exit(1);
    }

    // public tunnel via cloudflared quick tunnel (no account, no config)
    let run_tunnel = format!(
        "docker run -d --name {tunnel} --network host --restart unless-stopped \
         {tag} cloudflared tunnel --no-autoupdate --url http://localhost:{port} >/dev/null",
        tag = cfg.tag(),
        port = cfg.port,
    );
    if !ssh_ok(&run_tunnel) {
        eprintln!("{RED}Tunnel-Start fehlgeschlagen{RESET}");
        exit(1);
    }

    print!("dev-Server startet auf atlas, warte auf Tunnel-URL ");
    io::stdout().flush().ok();
    let mut url = None;
    for _ in 0..30 {
        if let Some(u) = dev_url(cfg) {
            url = Some(u);
            break;
        }
        print!(".");
        io::stdout().flush().ok();
        sleep(Duration::from_secs(2));
    }
    match url {
        Some(u) => {
            println!(" {GREEN}✓{RESET}");
            println!("\n  {GREEN}{u}{RESET}\n");
            println!("{DIM}  dev-Server läuft auf atlas ({}), Mac bleibt kühl.{RESET}", cfg.name);
            println!("{DIM}  Code live bearbeiten:  ssh atlas   → ~/{}{RESET}", cfg.remote_dir());
            println!("{DIM}  Logs:  atlas dev logs   ·   Stop:  atlas dev stop{RESET}");
        }
        None => {
            println!(" {RED}keine URL{RESET}");
            eprintln!("Tunnel-Logs:");
            let (_, t) = dev_names(cfg);
            print!("{}", ssh_capture(&format!("docker logs {t} 2>&1 | tail -20")));
            exit(1);
        }
    }
}

// ---- atlas agent: metrics server for the iOS app --------------------------

fn agent(sub: &[String]) {
    match sub.first().map(String::as_str) {
        Some("logs") => {
            let err = Command::new("ssh")
                .args(["-t", SSH_HOST, "journalctl -u atlas-agent -f -n 40"])
                .exec();
            eprintln!("ssh: {err}");
            exit(1);
        }
        Some("status") => {
            run_inherit(Command::new("ssh").args([
                SSH_HOST,
                "systemctl status atlas-agent --no-pager | head -12",
            ]));
        }
        Some("stop") => {
            run_inherit(Command::new("ssh").args([SSH_HOST, "sudo systemctl stop atlas-agent"]));
            println!("{GREEN}agent gestoppt{RESET}");
        }
        Some("restart") => {
            run_inherit(Command::new("ssh").args([SSH_HOST, "sudo systemctl restart atlas-agent"]));
            println!("{GREEN}agent neu gestartet{RESET}");
        }
        _ => agent_install(),
    }
}

/// Pull the repo on atlas, build the agent, install + enable the systemd service.
fn agent_install() {
    ensure_up();
    println!("{DIM}baue + installiere atlas-agent auf atlas ...{RESET}");
    let script = "set -e; cd ~/atlas && git pull --quiet --ff-only && cd agent && \
         . ~/.cargo/env && cargo build --release --quiet && \
         sudo install -m755 target/release/atlas-agent /usr/local/bin/atlas-agent && \
         sudo cp atlas-agent.service /etc/systemd/system/atlas-agent.service && \
         sudo systemctl daemon-reload && sudo systemctl enable --now atlas-agent && \
         sleep 1 && systemctl is-active atlas-agent";
    if !run_inherit(Command::new("ssh").args([SSH_HOST, script])) {
        eprintln!("{RED}Agent-Installation fehlgeschlagen{RESET}");
        exit(1);
    }
    let host = "atlas.your-tailnet.ts.net:8787";
    println!("{GREEN}✓ atlas-agent läuft{RESET}  {DIM}(systemd, Autostart an){RESET}");
    println!("  {DIM}Metrics:{RESET} http://{host}/api/metrics");
    println!("  {DIM}In der App als Host eintragen:{RESET} {host}");
}
