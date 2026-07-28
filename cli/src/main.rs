//! atlas — control the atlas homelab server from the Mac.
//!
//!   atlas              interactive SSH session (execs `ssh atlas`)
//!   atlas boot         Wake-on-LAN, waits until SSH is reachable
//!   atlas shutdown     powers the box off, waits until it is down
//!   atlas restart      reboot, waits for the box to come back
//!   atlas status       is it up? which route (LAN / tailnet)?
//!   atlas build        build this project on atlas in a builder container
//!   atlas dev          run this project's dev server on atlas
//!   atlas secrets      push/list/drop this project's env file on atlas
//!   atlas api          build + install atlas-api (the control-plane server)
//!   atlas <cmd ...>    run any command on atlas (forwarded to ssh)

use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{self, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs, UdpSocket};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, exit};
use std::sync::OnceLock;
use std::thread::sleep;
use std::time::{Duration, Instant};

const GREEN: &str = "\x1b[32m";
const RED: &str = "\x1b[31m";
const DIM: &str = "\x1b[2m";
const RESET: &str = "\x1b[0m";

/// Placeholder MAC — set ATLAS_WOL_MAC to your server's real MAC for `boot`.
const DEFAULT_WOL_MAC: &str = "aa:bb:cc:dd:ee:ff";
/// Placeholder tailnet address — set ATLAS_TAILNET_ADDR to the real
/// `<host>.<tailnet>.ts.net:22`. Without it the tailnet ssh route is skipped
/// and `atlas dev` has no host to publish its URL on.
const DEFAULT_TAILNET_ADDR: &str = "atlas.your-tailnet.ts.net:22";

/// Runtime configuration. Every value resolves from, in order: a real
/// environment variable, the optional file `~/.config/atlas/env` (plain
/// KEY=VALUE lines, '#' comments), then a generic built-in default.
struct Config {
    ssh_host: String,      // ATLAS_SSH_HOST — ssh/rsync host (~/.ssh/config alias)
    wol_mac: [u8; 6],      // ATLAS_WOL_MAC — server NIC MAC for Wake-on-LAN
    wol_mac_is_default: bool,
    wol_broadcast: String, // ATLAS_WOL_BROADCAST — WoL broadcast addr:port
    lan_addr: String,      // ATLAS_LAN_ADDR — LAN ssh route host:port ("" = skip)
    tailnet_addr: String,  // ATLAS_TAILNET_ADDR — tailnet ssh route host:port ("" = skip)
    api_url: String,       // ATLAS_API_URL — atlas-api host:port
}

fn config() -> &'static Config {
    static CFG: OnceLock<Config> = OnceLock::new();
    CFG.get_or_init(Config::load)
}

/// The ssh/rsync host (ATLAS_SSH_HOST, default "atlas").
fn ssh_host() -> &'static str {
    &config().ssh_host
}

/// The host part of ATLAS_TAILNET_ADDR ("<host>.<tailnet>.ts.net:22" → the
/// name without the ssh port), or None when the route is switched off or the
/// value is still the shipped placeholder. `atlas dev` builds its URL from
/// this, so a machine that never configured the tailnet gets the tunnel.
fn tailnet_host() -> Option<&'static str> {
    let host = host_of(&config().tailnet_addr);
    if host.is_empty() || host == host_of(DEFAULT_TAILNET_ADDR) { None } else { Some(host) }
}

/// "host:port" → "host" (a bare "host" is returned unchanged).
fn host_of(addr: &str) -> &str {
    addr.rsplit_once(':').map_or(addr, |(h, _)| h)
}

impl Config {
    fn load() -> Config {
        let file = env_file_vars();
        // real env vars win over the config file, the file over the default
        let get = |key: &str, default: &str| -> String {
            env::var(key).ok().or_else(|| file.get(key).cloned()).unwrap_or_else(|| default.into())
        };
        let mac_str = get("ATLAS_WOL_MAC", DEFAULT_WOL_MAC);
        let Some(wol_mac) = parse_mac(&mac_str) else {
            eprintln!("{RED}ATLAS_WOL_MAC ungültig:{RESET} {mac_str} (Format: aa:bb:cc:dd:ee:ff)");
            exit(1);
        };
        let tailnet_addr = get("ATLAS_TAILNET_ADDR", DEFAULT_TAILNET_ADDR);
        // ATLAS_API_URL defaults to the tailnet host with the API's port 8787
        let tailnet_host = host_of(&tailnet_addr);
        let api_default =
            if tailnet_host.is_empty() { String::new() } else { format!("{tailnet_host}:8787") };
        Config {
            ssh_host: get("ATLAS_SSH_HOST", "atlas"),
            wol_mac,
            wol_mac_is_default: mac_str == DEFAULT_WOL_MAC,
            wol_broadcast: get("ATLAS_WOL_BROADCAST", "192.168.1.255:9"),
            lan_addr: get("ATLAS_LAN_ADDR", "192.168.1.100:22"),
            api_url: get("ATLAS_API_URL", &api_default),
            tailnet_addr,
        }
    }
}

/// Optional config file `~/.config/atlas/env`: plain KEY=VALUE lines, lines
/// starting with '#' are comments, surrounding quotes around values are
/// stripped. Keeps personal addresses out of shell profiles and the repo.
fn env_file_vars() -> HashMap<String, String> {
    let mut vars = HashMap::new();
    let Ok(home) = env::var("HOME") else {
        return vars;
    };
    let Ok(text) = fs::read_to_string(Path::new(&home).join(".config/atlas/env")) else {
        return vars;
    };
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let v = v.trim();
        let v = v
            .strip_prefix('"')
            .and_then(|s| s.strip_suffix('"'))
            .or_else(|| v.strip_prefix('\'').and_then(|s| s.strip_suffix('\'')))
            .unwrap_or(v);
        vars.insert(k.trim().to_string(), v.to_string());
    }
    vars
}

/// Parse a colon-separated MAC like "aa:bb:cc:dd:ee:ff".
fn parse_mac(s: &str) -> Option<[u8; 6]> {
    let mut mac = [0u8; 6];
    let mut n = 0;
    for part in s.split(':') {
        if n == 6 {
            return None;
        }
        mac[n] = u8::from_str_radix(part, 16).ok()?;
        n += 1;
    }
    (n == 6).then_some(mac)
}

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
        Some("api") => api(&args[1..]),
        Some("secrets") => secrets(&args[1..]),
        Some("help") | Some("-h") | Some("--help") => help(),
        // anything else: run it on atlas (`atlas htop`, `atlas nvidia-smi`, ...)
        Some(_) => ssh(&args),
    }
}

fn help() {
    println!(
        "atlas — the homelab server\n\n\
         USAGE:\n  \
         atlas              SSH into atlas\n  \
         atlas boot         wake via WoL, wait until reachable\n  \
         atlas shutdown     power off, wait until down\n  \
         atlas restart      reboot, wait until back\n  \
         atlas status       up/down + route (LAN/tailnet)\n  \
         atlas build        build this project on atlas (needs .atlas-build.toml)\n  \
         atlas dev          run its dev server on atlas, reachable on the tailnet\n  \
         atlas dev --public expose it publicly instead (cloudflared, random URL)\n  \
         atlas dev url      print the URL of the running dev server\n  \
         atlas dev stop     stop the dev server + tunnel + serve config\n  \
         atlas dev logs     follow the dev-server logs\n  \
         atlas secrets push env-file for this project (never synced, 0600 on atlas)\n  \
         atlas secrets list/rm  show which projects have one / drop it\n  \
         atlas api          build+install the control-plane API (for the iOS apps)\n  \
         atlas api logs     follow the API logs   ·   api status/stop/restart\n  \
         atlas <cmd ...>    run a command on atlas (e.g. atlas nvidia-smi)"
    );
}

/// Replace this process with ssh — a real interactive session, no wrapper.
fn ssh(remote_cmd: &[String]) -> ! {
    let err = Command::new("ssh")
        .arg("-t")
        .arg(ssh_host())
        .args(remote_cmd)
        .exec();
    eprintln!("ssh konnte nicht gestartet werden: {err}");
    exit(1);
}

/// One quick TCP probe of port 22. Returns the route name if reachable.
fn probe() -> Option<&'static str> {
    let cfg = config();
    // probed in order; WoL itself only works from inside the LAN
    for (route, host) in [("LAN", cfg.lan_addr.as_str()), ("tailnet", cfg.tailnet_addr.as_str())] {
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

fn boot() {
    if let Some(route) = probe() {
        println!("{GREEN}atlas läuft schon{RESET} ({route})");
        return;
    }
    if config().wol_mac_is_default {
        println!("{DIM}Hinweis: ATLAS_WOL_MAC ist nicht gesetzt — der Platzhalter weckt keinen echten Server{RESET}");
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
        println!(" {RED}timeout{RESET} — nicht im LAN? Sonst: Wake über den Router-Fernzugriff");
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
        .args([ssh_host(), "sudo poweroff"])
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
        .args([ssh_host(), "sudo reboot"])
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
// Secrets live OUTSIDE the synced build tree: anything under REMOTE_BASE is a
// mirror of the Mac and gets rewritten by every rsync, so a file kept there
// would be either clobbered or silently stale. 0600 in a 0700 dir, injected as
// environment variables at run time rather than lying around as a file.
const SECRETS_BASE: &str = "atlas-secrets";

struct BuildCfg {
    root: PathBuf,          // dir holding .atlas-build.toml == rsync root
    name: String,           // remote build dir name
    image: String,          // builder key: universal | mobile
    dir: String,            // subdir (relative to root) the build runs in
    build: String,          // build command (for `atlas build`)
    dev: String,            // dev-server command (for `atlas dev`)
    install: String,        // dependency install for `atlas dev` ("" = detect)
    port: u16,              // dev-server port to tunnel
    artifacts: Vec<String>, // paths (relative to root) to copy back
}

/// What `docker build` needs to produce one image, and what to run it as.
///
/// The universal Dockerfile emits every image as a target of one file so they
/// share layers; this is the one place that maps a config key onto a tag.
struct ImageSpec {
    tag: String,     // docker tag to run
    context: String, // build context, relative to the atlas checkout
    target: String,  // multi-stage target inside that context
}

impl ImageSpec {
    /// The `docker build` invocation that produces this image.
    fn build_cmd(&self) -> String {
        format!("docker build --target {} -t {} {}", self.target, self.tag, self.context)
    }
}

/// Every builder key `.atlas-build.toml` accepts, in the order they are shown
/// to the user. Both resolve to targets of the one universal Dockerfile.
const IMAGE_KEYS: [&str; 2] = ["universal", "mobile"];

/// Resolve a config `image` key into the image that should run it.
///
/// `dev` picks the variant with cloudflared in it — the build target
/// deliberately has no tunnel binary, so a build container cannot open one.
/// The key is checked against IMAGE_KEYS by load_config, so anything reaching
/// here is known.
fn image_spec(key: &str, dev: bool) -> ImageSpec {
    // mobile carries the Flutter/Android SDK and is the same image for build
    // and dev: it is expensive enough that splitting it again to add a tunnel
    // binary would not pay for itself.
    let target = if key == "mobile" {
        "mobile"
    } else if dev {
        "dev"
    } else {
        "build"
    };
    ImageSpec {
        tag: format!("atlas-universal-{}", if target == "build" { "builder" } else { target }),
        context: "builder/universal".into(),
        target: target.into(),
    }
}

impl BuildCfg {
    fn spec(&self, dev: bool) -> ImageSpec {
        image_spec(&self.image, dev)
    }

    /// How `atlas dev` installs dependencies before starting the dev server.
    ///
    /// Detected from the lockfile inside the container instead of assumed,
    /// because the answer differs per project and getting it wrong is not a
    /// no-op: running `npm install` over a bun or pnpm project writes a second
    /// dependency tree next to the real one. An explicit `install = ...` in
    /// the config wins, for the repos where the lockfile is not the whole
    /// story.
    fn install_cmd(&self) -> String {
        if !self.install.is_empty() {
            return self.install.clone();
        }
        "if [ -f bun.lockb ] || [ -f bun.lock ]; then bun install --frozen-lockfile; \
         elif [ -f pnpm-lock.yaml ]; then corepack enable && pnpm install --frozen-lockfile; \
         elif [ -f yarn.lock ]; then corepack enable && yarn install --immutable; \
         else npm install --no-fund --no-audit; fi"
            .into()
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
    fn secrets_file(&self) -> String {
        format!("{SECRETS_BASE}/{}.env", self.name)
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
        install: String::new(),
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
        let (k, v) = (k.trim(), parse_toml_value(v));
        match k {
            "name" => c.name = v,
            "image" => c.image = v,
            "dir" => c.dir = v,
            "build" => c.build = v,
            "dev" => c.dev = v,
            "install" => c.install = v,
            "port" => {
                c.port = v.parse().unwrap_or_else(|_| {
                    eprintln!("{RED}.atlas-build.toml: ungültiger port{RESET} ({v})");
                    exit(1);
                })
            }
            "artifacts" => c.artifacts = v.split_whitespace().map(String::from).collect(),
            _ => {}
        }
    }
    if c.name.is_empty() || c.image.is_empty() {
        eprintln!("{RED}.atlas-build.toml unvollständig{RESET} (name, image nötig)");
        exit(1);
    }
    // name/image/dir/artifacts end up inside remote shell commands and rsync
    // paths — enforce a safe charset (image: a closed allowlist) instead of
    // trusting the config file
    if !valid_name(&c.name) {
        eprintln!("{RED}.atlas-build.toml: ungültiger name{RESET} (erlaubt: A-Za-z0-9._-)");
        exit(1);
    }
    // There is exactly one builder context, so an unknown key has nothing to
    // resolve to — catch it here rather than letting docker report a missing
    // build context after the machine has already been woken.
    if !IMAGE_KEYS.contains(&c.image.as_str()) {
        eprintln!(
            "{RED}.atlas-build.toml: unbekanntes image '{}'{RESET} (erlaubt: {})",
            c.image,
            IMAGE_KEYS.join(" | ")
        );
        exit(1);
    }
    if c.dir != "." && !valid_rel_path(&c.dir) {
        eprintln!("{RED}.atlas-build.toml: ungültiges dir{RESET} (relativer Pfad ohne '..')");
        exit(1);
    }
    for a in &c.artifacts {
        if !valid_rel_path(a) {
            eprintln!("{RED}.atlas-build.toml: ungültiges artifact '{a}'{RESET} (relativer Pfad ohne '..')");
            exit(1);
        }
    }
    c
}

/// Minimal TOML value handling: strips surrounding quotes and inline
/// `# comments` (the file is a flat key=value list, no full TOML needed).
fn parse_toml_value(raw: &str) -> String {
    let raw = raw.trim();
    for q in ['"', '\''] {
        if let Some(rest) = raw.strip_prefix(q)
            && let Some(end) = rest.find(q)
        {
            return rest[..end].to_string();
        }
    }
    let end = raw.find('#').unwrap_or(raw.len());
    raw[..end].trim().to_string()
}

/// `name`/`image` become docker tags, container names and remote dir names
/// inside ssh commands — allow only a conservative charset.
fn valid_name(s: &str) -> bool {
    !s.is_empty()
        && s.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
        && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// Relative path used in remote shell commands and as a local rsync
/// `--delete` target: no absolute paths, no `..`, no leading `-`.
fn valid_rel_path(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with(['/', '-'])
        && s.split('/').all(|p| {
            !p.is_empty()
                && p != "."
                && p != ".."
                && p.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        })
}

fn run_inherit(cmd: &mut Command) -> bool {
    cmd.status().map(|s| s.success()).unwrap_or(false)
}

fn ssh_ok(remote: &str) -> bool {
    Command::new("ssh")
        .args([ssh_host(), remote])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn ssh_capture(remote: &str) -> String {
    Command::new("ssh")
        .args([ssh_host(), remote])
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

/// Build the builder image on atlas if it is not there yet.
fn ensure_image(spec: &ImageSpec) {
    let tag = &spec.tag;
    if ssh_ok(&format!("docker image inspect {tag} >/dev/null 2>&1")) {
        return;
    }
    println!("{DIM}Image {tag} fehlt — baue es auf atlas (einmalig, ein paar Minuten){RESET}");
    let ok = run_inherit(Command::new("ssh").args([
        ssh_host(),
        &format!("cd ~/atlas && git pull --quiet --ff-only && {}", spec.build_cmd()),
    ]));
    if !ok {
        eprintln!("{RED}Image-Build fehlgeschlagen{RESET}");
        exit(1);
    }
}

// ---- secrets --------------------------------------------------------------

/// `atlas secrets push [file] | list | rm`
///
/// Secrets are deliberately kept out of the synced tree. Everything under
/// ~/atlas-builds is an rsync mirror of the Mac, so a secret parked there is
/// rewritten by every sync (or, being excluded from it, goes silently stale)
/// and lingers on disk for as long as the project does. The store is a 0600
/// file in a 0700 directory outside that tree, handed to the container as
/// environment variables at run time instead of lying around as a file.
fn secrets(sub: &[String]) {
    match sub.first().map(String::as_str) {
        Some("push") | Some("set") => secrets_push(sub.get(1).map(String::as_str)),
        Some("list") | Some("ls") => secrets_list(),
        Some("rm") | Some("remove") => secrets_rm(),
        _ => {
            println!(
                "atlas secrets push [datei]  Datei (Standard: .env.local, sonst .env) nach atlas, 0600\n\
                 atlas secrets list          welche Projekte eine haben (nie der Inhalt)\n\
                 atlas secrets rm            die dieses Projekts löschen"
            );
        }
    }
}

/// Upload an env file for the current project. Streamed over ssh stdin so the
/// contents never land in a shell argument (argv is world-readable in /proc)
/// and never touch an intermediate file on the way.
fn secrets_push(arg: Option<&str>) {
    let cfg = load_config();
    let local = match arg {
        Some(p) => cfg.root.join(p),
        None => match [".env.local", ".env"].iter().map(|f| cfg.root.join(f)).find(|p| p.is_file()) {
            Some(p) => p,
            None => {
                eprintln!("{RED}keine .env.local oder .env gefunden{RESET} (oder Pfad angeben)");
                exit(1);
            }
        },
    };
    let Ok(handle) = fs::File::open(&local) else {
        eprintln!("{RED}kann {} nicht lesen{RESET}", local.display());
        exit(1);
    };
    ensure_up();
    let target = cfg.secrets_file();
    // umask before the redirect: the file is never even briefly group/world
    // readable between creation and chmod.
    let remote = format!(
        "umask 077 && mkdir -p \"$HOME/{SECRETS_BASE}\" && chmod 700 \"$HOME/{SECRETS_BASE}\" \
         && cat > \"$HOME/{target}\" && chmod 600 \"$HOME/{target}\""
    );
    let ok = Command::new("ssh")
        .args([ssh_host(), &remote])
        .stdin(handle)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !ok {
        eprintln!("{RED}secrets push fehlgeschlagen{RESET}");
        exit(1);
    }
    println!("{GREEN}✓ {} → atlas:~/{}{RESET} {DIM}(0600){RESET}", local.display(), target);
    println!("{DIM}  wird bei jedem atlas build/dev als Umgebungsvariablen injiziert{RESET}");
}

fn secrets_list() {
    ensure_up();
    let out = ssh_capture(&format!(
        "cd \"$HOME/{SECRETS_BASE}\" 2>/dev/null && stat -c '%n  %s B  %y' *.env 2>/dev/null | cut -c1-60"
    ));
    if out.trim().is_empty() {
        println!("{DIM}keine secrets hinterlegt{RESET}");
        return;
    }
    print!("{out}");
}

fn secrets_rm() {
    let cfg = load_config();
    ensure_up();
    let target = cfg.secrets_file();
    if !ssh_ok(&format!("rm -f \"$HOME/{target}\"")) {
        eprintln!("{RED}secrets rm fehlgeschlagen{RESET}");
        exit(1);
    }
    println!("{GREEN}✓ secrets für {} gelöscht{RESET}", cfg.name);
}

/// Shell prologue that sets $envf to a --env-file flag when this project has a
/// secrets file, and to nothing when it does not. Evaluated on atlas inside
/// the same command as `docker run`, so it costs no extra round trip and
/// cannot race with a push.
fn env_file_prologue(cfg: &BuildCfg) -> String {
    format!(
        "sec=\"$HOME/{}\"; envf=\"\"; [ -f \"$sec\" ] && envf=\"--env-file $sec\"; ",
        cfg.secrets_file()
    )
}

/// Warn when the project has a local env file but nothing in the store — the
/// build would otherwise run without the variables it expects and fail in a
/// way that looks like a code problem.
fn warn_if_secrets_unpushed(cfg: &BuildCfg) {
    let has_local = [".env.local", ".env"].iter().any(|f| cfg.root.join(f).is_file());
    if !has_local {
        return;
    }
    if ssh_ok(&format!("test -f \"$HOME/{}\"", cfg.secrets_file())) {
        return;
    }
    println!(
        "{DIM}Hinweis: .env liegt lokal, aber nicht auf atlas — env-Dateien werden nicht \
         mitsynchronisiert.\n  atlas secrets push{RESET}"
    );
}

/// rsync the project tree to atlas (outputs/caches stay on their own sides).
fn sync_to_atlas(cfg: &BuildCfg) {
    let ok = run_inherit(Command::new("ssh").args([
        ssh_host(),
        // 0700 on the base: the tree below holds whole checkouts of private
        // repos and was 0775/0755 on a box where any process could read it.
        // The project dir itself is handled by rsync's --chmod below, because
        // -a would otherwise re-apply the Mac's 0755 on every sync.
        &format!(
            "mkdir -p {d} {REMOTE_BASE}/.cache-{i} && chmod 700 \"$HOME/{REMOTE_BASE}\"",
            d = cfg.remote_dir(),
            i = cfg.image
        ),
    ]));
    if !ok {
        eprintln!("{RED}mkdir auf atlas fehlgeschlagen{RESET}");
        exit(1);
    }
    println!("{DIM}sync -> atlas{RESET}");
    let ok = run_inherit(Command::new("rsync").args([
        "-az",
        "--delete",
        // Strip group/other off everything that lands on atlas while leaving
        // the owner bits (and therefore the execute bit on scripts) alone.
        // Done here rather than as a chmod because -a re-applies the source's
        // permissions on every sync, undoing anything set out of band.
        "--chmod=Dgo=,Fgo=",
        // Secrets do not travel with the source. The two sample files are the
        // exception: they carry no values and repos do read them. Include
        // rules must precede the exclude they carve out of — rsync takes the
        // first rule that matches.
        "--include",
        ".env.example",
        "--include",
        ".env.sample",
        "--exclude",
        ".env",
        "--exclude",
        ".env.*",
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
        &format!("{}:{}/", ssh_host(), cfg.remote_dir()),
    ]));
    if !ok {
        eprintln!("{RED}rsync -> atlas fehlgeschlagen{RESET}");
        exit(1);
    }
    // --chmod above only reaches files rsync actually transferred, so a tree
    // that synced before this existed keeps its old 0755. Catch those up here.
    //
    // Scoped to files WE own and error-swallowing on purpose: `atlas dev` runs
    // its container as root and never chowns back (unlike a build), so it
    // leaves root-owned output under .next that this user can neither chmod nor
    // needs to — it is generated, not the private source we are hiding. A bare
    // `chmod -R` choked on exactly that ("Permission denied" on .next/dev). The
    // `find -user` only walks our own files, so it is idempotent and cheap to
    // repeat every sync.
    ssh_ok(&format!(
        "d=\"$HOME/{d}\"; chmod 700 \"$d\" 2>/dev/null; \
         find \"$d\" -user \"$(id -un)\" \\( -type d -o -type f \\) \
         -exec chmod go= {{}} + 2>/dev/null; true",
        d = cfg.remote_dir()
    ));
}

fn build(extra: &[String]) {
    let cfg = load_config();
    if cfg.build.is_empty() || cfg.artifacts.is_empty() {
        eprintln!("{RED}.atlas-build.toml hat kein build/artifacts{RESET}");
        exit(1);
    }
    ensure_up();
    let spec = cfg.spec(false);
    ensure_image(&spec);
    warn_if_secrets_unpushed(&cfg);
    sync_to_atlas(&cfg);

    let mut buildcmd = cfg.build.clone();
    for a in extra {
        buildcmd.push(' ');
        buildcmd.push_str(a);
    }
    // Run as root inside the container (works for every base image, incl.
    // flutter's SDK dir), then chown the tree back to the SSH user so the next
    // rsync and the artifact pull don't trip over root-owned files. `; rc=$?`
    // keeps the build's exit code even though the chown always runs.
    let remote = format!(
        "{prologue}docker run --rm $envf \
         -e CARGO_HOME=/cache/cargo -e npm_config_cache=/cache/npm \
         -e PUB_CACHE=/cache/pub -e XDG_CACHE_HOME=/cache/xdg \
         -e GRADLE_USER_HOME=/cache/gradle \
         -v \"$HOME/{dir}\":/build -v \"$HOME/{base}/.cache-{img}\":/cache \
         -w {wd} {tag} sh -c {cmd}; rc=$?; \
         sudo chown -R $(id -u):$(id -g) \"$HOME/{dir}\" >/dev/null 2>&1; exit $rc",
        prologue = env_file_prologue(&cfg),
        dir = cfg.remote_dir(),
        base = REMOTE_BASE,
        img = cfg.image,
        wd = cfg.workdir(),
        tag = spec.tag,
        cmd = shq(&buildcmd),
    );
    println!("{DIM}build on atlas ({}):{RESET} {buildcmd}", spec.tag);
    let t0 = Instant::now();
    let ok = run_inherit(Command::new("ssh").args([ssh_host(), &remote]));
    let secs = t0.elapsed().as_secs();
    if !ok {
        eprintln!("{RED}Build fehlgeschlagen{RESET} (nach {secs}s)");
        exit(1);
    }

    println!("{DIM}sync artifacts <- atlas{RESET}");
    for art in &cfg.artifacts {
        let local = cfg.root.join(art);
        fs::create_dir_all(&local).ok();
        let ok = run_inherit(Command::new("rsync").args([
            "-az",
            "--delete",
            &format!("{}:{}/{art}/", ssh_host(), cfg.remote_dir()),
            &format!("{}/", local.display()),
        ]));
        if !ok {
            eprintln!("{RED}Artefakt-Sync fehlgeschlagen{RESET} ({art})");
            exit(1);
        }
    }
    println!(
        "{GREEN}✓ build fertig{RESET} in {}m {:02}s  {DIM}(atlas, {}){RESET}",
        secs / 60,
        secs % 60,
        spec.tag
    );
    for art in &cfg.artifacts {
        println!("  → {}", cfg.root.join(art).display());
    }
}

// ---- atlas dev: run a dev server on atlas, on the tailnet by default ------

fn dev(sub: &[String]) {
    let cfg = load_config();
    match sub.first().map(String::as_str) {
        Some("stop") => dev_stop(&cfg),
        Some("url") => {
            println!("{}", dev_url(&cfg).unwrap_or_else(|| "(kein dev-Server aktiv)".into()))
        }
        Some("logs") => dev_logs(&cfg),
        // `--tunnel` is the old mental model ("gib mir den Tunnel"), `--public`
        // says what actually changes: the dev server leaves the tailnet.
        _ => dev_start(&cfg, sub.iter().any(|a| a == "--public" || a == "--tunnel")),
    }
}

fn dev_names(cfg: &BuildCfg) -> (String, String) {
    (format!("atlas-dev-{}", cfg.name), format!("atlas-tunnel-{}", cfg.name))
}

/// The HTTPS port `tailscale serve` publishes this project's dev server on.
///
/// Derived from the project name so it survives restarts — that is the whole
/// point of the tailnet path: OAuth redirects, webhooks and Next.js'
/// allowedDevOrigins are configured once instead of after every start. Port
/// and not a path prefix (`/dairo-frontend/`) because frameworks emit absolute
/// asset URLs like `/_next/static/...`, which a prefix silently breaks.
///
/// The band avoids collisions in both directions: 443 on atlas is taken by
/// another service, ports below 20000 are where the box's own services sit
/// (8788 photos, 8787 atlas-api), and Linux hands out 32768+ as ephemeral
/// source ports.
fn tailnet_port(name: &str) -> u16 {
    // FNV-1a, four lines and no dependency. Deliberately not std's hasher:
    // that one is free to change its output between Rust releases, which would
    // silently move every project's URL on the next `cargo install`.
    let mut h: u32 = 0x811c_9dc5;
    for b in name.as_bytes() {
        h = (h ^ u32::from(*b)).wrapping_mul(0x0100_0193);
    }
    20000 + (h % 1000) as u16
}

/// Whichever URL currently serves this project: the tailnet one when its serve
/// config is up, otherwise the tunnel's.
fn dev_url(cfg: &BuildCfg) -> Option<String> {
    tailnet_url(cfg).or_else(|| tunnel_url(cfg))
}

/// The tailnet URL, but only if `tailscale serve` is really publishing it —
/// `atlas dev url` must not print an address that answers nothing.
fn tailnet_url(cfg: &BuildCfg) -> Option<String> {
    let host = tailnet_host()?;
    let port = tailnet_port(&cfg.name);
    // `serve status` is readable without sudo and prints one `https://host:port`
    // line per published port; anchor the match so the proxy target lines
    // ("|-- / proxy http://127.0.0.1:3000") cannot match a port by accident.
    let up = ssh_capture(&format!(
        "tailscale serve status 2>/dev/null | grep -qE '^https://[^ ]+:{port}([ /]|$)' && echo up"
    ));
    (up.trim() == "up").then(|| format!("https://{host}:{port}"))
}

/// Scrape the public URL out of the tunnel container's logs.
fn tunnel_url(cfg: &BuildCfg) -> Option<String> {
    let (_, tunnel) = dev_names(cfg);
    let out = ssh_capture(&format!(
        "docker logs {tunnel} 2>&1 | grep -oE 'https://[a-z0-9-]+\\.trycloudflare\\.com' | head -1"
    ));
    let url = out.trim();
    if url.is_empty() { None } else { Some(url.to_string()) }
}

/// Drop this project's serve config. Unlike the containers, it is host state:
/// tailscaled persists it and re-publishes the port after a reboot, so leaving
/// it behind would advertise a dead port forever. `off` on a port that has no
/// handler exits 1 — expected, hence the discarded status.
fn tailnet_serve_off(cfg: &BuildCfg) {
    if tailnet_host().is_none() {
        return;
    }
    let port = tailnet_port(&cfg.name);
    ssh_ok(&format!("sudo tailscale serve --https={port} off >/dev/null 2>&1"));
}

fn dev_stop(cfg: &BuildCfg) {
    let (dev, tunnel) = dev_names(cfg);
    ssh_ok(&format!("docker rm -f {dev} {tunnel} >/dev/null 2>&1"));
    tailnet_serve_off(cfg);
    println!("{GREEN}dev gestoppt{RESET} ({})", cfg.name);
}

fn dev_logs(cfg: &BuildCfg) -> ! {
    let (dev, _) = dev_names(cfg);
    let err = Command::new("ssh")
        .args(["-t", ssh_host(), &format!("docker logs -f {dev}")])
        .exec();
    eprintln!("ssh: {err}");
    exit(1);
}

fn dev_start(cfg: &BuildCfg, public: bool) {
    if cfg.dev.is_empty() {
        eprintln!("{RED}.atlas-build.toml hat kein dev = ...{RESET}");
        exit(1);
    }
    ensure_up();
    let spec = cfg.spec(true);
    ensure_image(&spec);
    warn_if_secrets_unpushed(cfg);
    sync_to_atlas(cfg);
    let (dev, tunnel) = dev_names(cfg);

    // Without a tailnet host there is nothing to publish on, so the public
    // tunnel is the only way out — say why rather than failing.
    let tailnet = if public { None } else { tailnet_host() };
    if !public && tailnet.is_none() {
        println!(
            "{DIM}ATLAS_TAILNET_ADDR ist nicht gesetzt oder noch der Platzhalter \
             (~/.config/atlas/env) — ohne Tailnet-Host bleibt nur der öffentliche Tunnel{RESET}"
        );
    }

    // fresh start — the serve config too, because it outlives the containers
    ssh_ok(&format!("docker rm -f {dev} {tunnel} >/dev/null 2>&1"));
    tailnet_serve_off(cfg);

    // dev server: --network host so it binds atlas' real port; node_modules
    // persist in the synced dir, so the install is warm after the first run.
    //
    // The install step is picked from the lockfile rather than hardcoded to
    // npm: a bun or pnpm project used to get `npm install` run over it, which
    // either fails or silently produces a second, wrong dependency tree.
    let devcmd = format!("{} && {}", cfg.install_cmd(), cfg.dev);
    let run_dev = format!(
        "{prologue}docker run -d --name {dev} --network host --restart unless-stopped $envf \
         -e npm_config_cache=/cache/npm -e HOST=0.0.0.0 -e PORT={port} \
         -v \"$HOME/{rdir}\":/build -v \"$HOME/{base}/.cache-{img}\":/cache \
         -w {wd} {tag} sh -c {cmd} >/dev/null",
        prologue = env_file_prologue(cfg),
        port = cfg.port,
        rdir = cfg.remote_dir(),
        base = REMOTE_BASE,
        img = cfg.image,
        wd = cfg.workdir(),
        tag = spec.tag,
        cmd = shq(&devcmd),
    );
    if !ssh_ok(&run_dev) {
        eprintln!("{RED}dev-Container-Start fehlgeschlagen{RESET}");
        exit(1);
    }

    match tailnet {
        Some(host) => dev_expose_tailnet(cfg, host),
        None => dev_expose_tunnel(cfg, &spec),
    }
    println!("{DIM}  dev-Server läuft auf atlas ({}), Mac bleibt kühl.{RESET}", cfg.name);
    println!("{DIM}  Code live bearbeiten:  ssh {}   → ~/{}{RESET}", ssh_host(), cfg.remote_dir());
    println!("{DIM}  Logs:  atlas dev logs   ·   Stop:  atlas dev stop{RESET}");
}

/// Publish the dev server on the tailnet.
///
/// tailscaled runs on atlas' host, not in the container, so the serve config
/// is set over ssh; a container has no way to reach the local API socket.
/// sudo because writing the serve config is root-only unless the box has run
/// `tailscale set --operator=$USER` — the same passwordless sudo `atlas build`
/// already needs for its chown.
///
/// No wait loop here: this URL is computed from the config, not discovered in
/// a log, so there is nothing to wait for. It answers 502 until the install
/// and the dev server are through, which `atlas dev logs` shows.
fn dev_expose_tailnet(cfg: &BuildCfg, host: &str) {
    let port = tailnet_port(&cfg.name);
    let ok = ssh_ok(&format!(
        "sudo tailscale serve --bg --https={port} http://127.0.0.1:{dev} >/dev/null",
        dev = cfg.port
    ));
    if !ok {
        eprintln!("{RED}tailscale serve fehlgeschlagen{RESET} (Port {port})");
        eprintln!(
            "{DIM}  läuft tailscaled auf atlas, und ist HTTPS im Tailnet aktiviert?\n  \
             Alternative: atlas dev --public{RESET}"
        );
        exit(1);
    }
    println!("\n  {GREEN}https://{host}:{port}{RESET}\n");
    println!("{DIM}  nur im Tailnet erreichbar, direkt über WireGuard — und die URL{RESET}");
    println!("{DIM}  bleibt gleich, taugt also für OAuth-Redirects und Webhooks.{RESET}");
    println!("{DIM}  Öffentlich stattdessen:  atlas dev --public{RESET}");
}

/// Public cloudflared quick tunnel (no account, no config) — opt-in, because
/// it puts an unauthenticated dev server with this project's secrets on the
/// open internet, under a subdomain that is random again on every start.
///
/// The URL only exists once cloudflared has registered it with the edge, so
/// unlike the tailnet path this one has to wait for it to show up in the log.
fn dev_expose_tunnel(cfg: &BuildCfg, spec: &ImageSpec) {
    let (_, tunnel) = dev_names(cfg);
    let run_tunnel = format!(
        "docker run -d --name {tunnel} --network host --restart unless-stopped \
         {tag} cloudflared tunnel --no-autoupdate --url http://localhost:{port} >/dev/null",
        tag = spec.tag,
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
        if let Some(u) = tunnel_url(cfg) {
            url = Some(u);
            break;
        }
        print!(".");
        io::stdout().flush().ok();
        sleep(Duration::from_secs(2));
    }
    let Some(u) = url else {
        println!(" {RED}keine URL{RESET}");
        eprintln!("Tunnel-Logs:");
        print!("{}", ssh_capture(&format!("docker logs {tunnel} 2>&1 | tail -20")));
        exit(1);
    };
    println!(" {GREEN}✓{RESET}");
    println!("\n  {GREEN}{u}{RESET}\n");
    println!("{DIM}  öffentlich erreichbar, ohne Login — die Subdomain ist bei jedem{RESET}");
    println!("{DIM}  Start eine andere.{RESET}");
}

// ---- atlas api: control-plane server for the iOS apps ---------------------

fn api(sub: &[String]) {
    match sub.first().map(String::as_str) {
        Some("logs") => {
            let err = Command::new("ssh")
                .args(["-t", ssh_host(), "journalctl -u atlas-api -f -n 40"])
                .exec();
            eprintln!("ssh: {err}");
            exit(1);
        }
        // `systemctl status` exits non-zero for an inactive unit, which is an
        // answer, not a failure — the other two really did not do their job.
        Some("status") => {
            run_inherit(Command::new("ssh").args([
                ssh_host(),
                "systemctl status atlas-api --no-pager | head -12",
            ]));
        }
        Some("stop") => systemctl("stop", "atlas-api gestoppt"),
        Some("restart") => systemctl("restart", "atlas-api neu gestartet"),
        _ => api_install(),
    }
}

/// `sudo systemctl <verb> atlas-api`, reporting what actually happened —
/// printing success on a failed ssh call is worse than no output at all.
fn systemctl(verb: &str, done: &str) {
    let ok = run_inherit(
        Command::new("ssh").args([ssh_host(), &format!("sudo systemctl {verb} atlas-api")]),
    );
    if !ok {
        eprintln!("{RED}systemctl {verb} atlas-api fehlgeschlagen{RESET}");
        exit(1);
    }
    println!("{GREEN}{done}{RESET}");
}

/// Pull the repo on atlas, build the API server, install + enable the systemd unit.
///
/// The predecessor unit is torn down *after* the new binary and unit are in
/// place, never before: a release build that fails on the server would
/// otherwise leave the box with no control plane at all, over the same SSH
/// path that manages its power. The teardown itself is not optional — the old
/// unit binds the same port, so leaving it enabled makes atlas-api exit on
/// bind at the next reboot.
fn api_install() {
    ensure_up();
    println!("{DIM}baue + installiere atlas-api auf atlas ...{RESET}");
    let script = "set -e; cd ~/atlas && git fetch --quiet origin && \
         git reset --hard --quiet origin/main && cd api && \
         . ~/.cargo/env && cargo build --release --quiet && \
         sudo install -m755 target/release/atlas-api /usr/local/bin/atlas-api && \
         sudo cp atlas-api.service /etc/systemd/system/atlas-api.service && \
         sudo sh -c '[ -f /etc/atlas-agent.env ] && mv /etc/atlas-agent.env /etc/atlas-api.env || true' && \
         sudo sh -c '[ -f /etc/atlas-api.env ] && sed -i s/^ATLAS_AGENT_/ATLAS_API_/ /etc/atlas-api.env || true' && \
         { sudo systemctl disable --now atlas-agent >/dev/null 2>&1 || true; } && \
         sudo rm -f /usr/local/bin/atlas-agent /etc/systemd/system/atlas-agent.service && \
         sudo systemctl daemon-reload && sudo systemctl enable --quiet atlas-api && \
         sudo systemctl restart atlas-api && \
         sleep 1 && systemctl is-active atlas-api";
    if !run_inherit(Command::new("ssh").args([ssh_host(), script])) {
        eprintln!("{RED}Installation der API fehlgeschlagen{RESET}");
        exit(1);
    }
    let host = config().api_url.as_str();
    println!("{GREEN}✓ atlas-api läuft{RESET}  {DIM}(systemd, Autostart an){RESET}");
    if !host.is_empty() {
        println!("  {DIM}Metrics:{RESET} http://{host}/api/metrics");
        println!("  {DIM}In der App als Host eintragen:{RESET} {host}");
    }
}
