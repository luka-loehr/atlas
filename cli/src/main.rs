//! atlas — control the atlas homelab server from the Mac.
//!
//!   atlas              interactive SSH session (execs `ssh atlas`)
//!   atlas boot         Wake-on-LAN, waits until SSH is reachable
//!   atlas shutdown     powers the box off, waits until it is down
//!   atlas restart      reboot, waits for the box to come back
//!   atlas status       is it up? which route (LAN / tailnet)?
//!   atlas build        build a branch of this project on atlas (source: GitHub)
//!   atlas dev          run this project's dev server on atlas
//!   atlas start        run what `atlas build` produced for a branch
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
        Some("start") => start(&args[1..]),
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
         atlas status       up/down + route (LAN/tailnet)\n\n\
         PROJEKTE {DIM}(brauchen .atlas-build.toml; --branch B | -b B, Standard: main){RESET}\n  \
         atlas build [-b B]   Branch auf atlas bauen — atlas holt ihn von GitHub\n  \
         atlas build -b B -- …  alles nach '--' geht an den Build-Befehl\n  \
         atlas dev   [-b B]   dev-Server dieses Branches auf atlas, im Tailnet\n  \
         atlas dev --public   stattdessen öffentlich (cloudflared, zufällige URL)\n  \
         atlas dev   [-b B] url|logs|stop\n  \
         atlas start [-b B]   das GEBAUTE Ergebnis dieses Branches starten\n  \
         atlas start [-b B] status|logs|stop\n\n\
         SONST\n  \
         atlas secrets push env-file for this project (nie im git, 0600 auf atlas)\n  \
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

// ---- remote build, dev & start --------------------------------------------

/// What atlas keeps per project, relative to atlas' $HOME:
///
///   atlas-builds/<name>/.repo/            clone (created --no-checkout)
///   atlas-builds/<name>/wt/<slug>/        one worktree per branch
///   atlas-builds/<name>/state/<slug>.json what `atlas build` last produced
///   atlas-builds/.cache-<image>/          shared package caches
///
/// The Mac never pushes source here — GitHub is the meeting point and atlas
/// pulls. The tree is disposable: every run hard-resets it to origin/<branch>,
/// so it is never hand-edited and nothing may be stored in it.
const REMOTE_BASE: &str = "atlas-builds";
// Secrets live OUTSIDE the build tree: everything under REMOTE_BASE is a
// checkout that gets reset (or thrown away and re-cloned), so a file kept there
// would be deleted or silently stale. 0600 in a 0700 dir, injected as
// environment variables at run time rather than lying around as a file.
const SECRETS_BASE: &str = "atlas-secrets";

struct BuildCfg {
    root: PathBuf,          // dir holding .atlas-build.toml (the local checkout)
    name: String,           // project dir name on atlas
    image: String,          // builder key: universal | mobile
    dir: String,            // subdir (relative to the repo root) the build runs in
    build: String,          // build command (for `atlas build`)
    dev: String,            // dev-server command (for `atlas dev`)
    start: String,          // run-the-built-artifact command ("" = detect)
    install: String,        // dependency install for `atlas dev` ("" = detect)
    repo: String,           // git URL ("" = origin of the local checkout)
    port: u16,              // port the server binds on atlas
    artifacts: Vec<String>, // paths (relative to the repo root) the build produces
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
    /// `atlas-install` (in the builder image) probes the lockfile rather than
    /// assuming npm — getting that wrong is not a no-op, since `npm install`
    /// over a bun or pnpm project writes a second dependency tree next to the
    /// real one — and skips the install entirely when the lockfile is
    /// unchanged. An explicit `install = ...` in the config wins, for the
    /// repos where the lockfile is not the whole story.
    fn install_cmd(&self) -> String {
        if !self.install.is_empty() {
            return self.install.clone();
        }
        "atlas-install".into()
    }
    /// How `atlas start` runs what the build produced.
    ///
    /// Same lockfile probe as install_cmd and for the same reason — it is the
    /// package manager's own script runner that knows how to start the app.
    /// An explicit `start = ...` wins, and everything that is not a JS project
    /// (cargo, flutter, ...) needs one: `npm run start` is meaningless there.
    fn start_cmd(&self) -> String {
        if !self.start.is_empty() {
            return self.start.clone();
        }
        "if [ -f bun.lockb ] || [ -f bun.lock ]; then bun run start; \
         elif [ -f pnpm-lock.yaml ]; then pnpm start; \
         elif [ -f yarn.lock ]; then yarn start; \
         else npm run start; fi"
            .into()
    }
    fn workdir(&self) -> String {
        if self.dir == "." {
            "/build".into()
        } else {
            format!("/build/{}", self.dir)
        }
    }
    /// All paths below are relative to atlas' $HOME and are used inside
    /// double-quoted "$HOME/..." expansions; `name` and the branch slug are
    /// charset-validated, so they need no further quoting.
    fn base_dir(&self) -> String {
        format!("{REMOTE_BASE}/{}", self.name)
    }
    fn repo_dir(&self) -> String {
        format!("{}/.repo", self.base_dir())
    }
    fn wt_dir(&self, slug: &str) -> String {
        format!("{}/wt/{slug}", self.base_dir())
    }
    fn state_file(&self, slug: &str) -> String {
        format!("{}/state/{slug}.json", self.base_dir())
    }
    fn cache_dir(&self) -> String {
        format!("{REMOTE_BASE}/.cache-{}", self.image)
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
        start: String::new(),
        install: String::new(),
        repo: String::new(),
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
            "start" => c.start = v,
            "install" => c.install = v,
            "repo" => c.repo = v,
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

// ---- branches: validation, slug, flag parsing -----------------------------

/// A branch name reaches a remote shell, the filesystem (as a slug) and a
/// docker container name. Allow only what all three survive unquoted.
///
/// `__` is rejected because the slug maps '/' onto it: without that rule
/// `feature/x` and `feature__x` would be the same directory and the same
/// container, and `atlas start` would run the wrong build.
fn valid_branch(b: &str) -> bool {
    !b.is_empty()
        && b.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
        && !b.contains("..")
        && !b.contains("__")
        && !b.contains("//")
        && !b.ends_with('/')
        && b.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '/'))
}

/// Branch → one path/container component. Bijective, because valid_branch
/// rejects `__`.
fn slug_of(branch: &str) -> String {
    branch.replace('/', "__")
}

fn branch_of_slug(slug: &str) -> String {
    slug.replace("__", "/")
}

/// Pull `--branch B` / `-b B` / `--branch=B` out of an argument list and return
/// it with the rest of the arguments (default "main").
///
/// Stops at a literal `--` so `atlas build -- --branch x` passes the flag on to
/// the build command instead of eating it.
fn take_branch(argv: &[String]) -> (String, Vec<String>) {
    let mut branch: Option<String> = None;
    let mut rest: Vec<String> = Vec::new();
    let mut i = 0;
    while i < argv.len() {
        let a = argv[i].as_str();
        if a == "--" {
            rest.extend_from_slice(&argv[i..]);
            break;
        }
        if let Some(v) = a.strip_prefix("--branch=").or_else(|| a.strip_prefix("-b=")) {
            branch = Some(v.to_string());
        } else if a == "--branch" || a == "-b" {
            let Some(v) = argv.get(i + 1) else {
                eprintln!("{RED}{a} braucht einen Branchnamen{RESET}");
                exit(1);
            };
            branch = Some(v.clone());
            i += 1;
        } else {
            rest.push(argv[i].clone());
        }
        i += 1;
    }
    let branch = branch.unwrap_or_else(|| "main".into());
    if !valid_branch(&branch) {
        eprintln!("{RED}ungültiger Branchname '{branch}'{RESET}");
        eprintln!("{DIM}  erlaubt: A-Za-z0-9._-/ , Anfang alphanumerisch, kein '..' und kein '__'{RESET}");
        exit(1);
    }
    (branch, rest)
}


/// First seven characters of a commit sha (never panics on a corrupt state).
fn short(sha: &str) -> &str {
    sha.get(..7).unwrap_or(sha)
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
/// Secrets are deliberately kept out of the build tree. Everything under
/// ~/atlas-builds is a git checkout that every build resets, so a secret parked
/// there is deleted by the next run (or, being gitignored, goes silently stale)
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
        "{DIM}Hinweis: .env liegt lokal, aber nicht auf atlas — env-Dateien liegen nicht \
         im git und kommen deshalb nicht mit dem Branch mit.\n  atlas secrets push{RESET}"
    );
}

// ---- git on atlas: the tree comes from GitHub, never from the Mac ---------

/// The git URL atlas clones from: an explicit `repo = ...`, otherwise the
/// origin of the local checkout.
///
/// Read on the Mac, not derived from `name`: the project dir on atlas does not
/// encode the owner, and two projects of different owners can share a name.
fn repo_url(cfg: &BuildCfg) -> String {
    let raw = if cfg.repo.is_empty() {
        let out = Command::new("git")
            .args(["-C".as_ref(), cfg.root.as_os_str(), "remote".as_ref(), "get-url".as_ref(), "origin".as_ref()])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();
        if out.is_empty() {
            eprintln!("{RED}kein git-Remote 'origin'{RESET} in {}", cfg.root.display());
            eprintln!(
                "{DIM}  atlas baut aus GitHub, nicht vom Mac — Repo pushen, oder \
                 repo = \"https://...\" in .atlas-build.toml setzen{RESET}"
            );
            exit(1);
        }
        out
    } else {
        cfg.repo.clone()
    };
    match normalize_git_url(&raw) {
        Some(u) => u,
        None => {
            eprintln!("{RED}unbrauchbare Repo-URL:{RESET} {raw}");
            eprintln!("{DIM}  erlaubt: https://host/owner/repo.git oder git@host:owner/repo.git{RESET}");
            exit(1);
        }
    }
}

/// Rewrite an SSH remote to https and reject anything that is not a plain URL.
///
/// atlas authenticates with ~/.git-credentials, which only answers for https —
/// a `git@github.com:` remote fails there with "Permission denied (publickey)"
/// on a box that has no deploy key. The charset check is the second line of
/// defence after shq(): nothing with a shell metacharacter gets that far.
fn normalize_git_url(raw: &str) -> Option<String> {
    let s = raw.trim();
    if s.contains("://") && !s.starts_with("https://") && !s.starts_with("ssh://") {
        return None; // git://, http://, file:// — not what atlas can authenticate
    }
    let url = if s.starts_with("https://") {
        s.to_string()
    } else if let Some(rest) = s.strip_prefix("ssh://") {
        format!("https://{}", rest.rsplit_once('@').map_or(rest, |(_, h)| h))
    } else if let Some((user_host, path)) = s.split_once(':') {
        // scp form: git@host:owner/repo.git
        if user_host.contains('/') || path.is_empty() {
            return None;
        }
        let host = user_host.rsplit_once('@').map_or(user_host, |(_, h)| h);
        format!("https://{host}/{path}")
    } else {
        return None;
    };
    let (host, path) = url.strip_prefix("https://")?.split_once('/')?;
    if host.is_empty() || path.is_empty() {
        return None;
    }
    url.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '/' | ':' | '@' | '~' | '+' | '%'))
        .then_some(url)
}

/// Make ~/atlas-builds/<name>/wt/<slug> an exact checkout of origin/<branch>
/// and return the commit it now sits on.
///
/// Everything here runs as the ssh user and never under sudo: root has no git
/// credentials on the box, so a sudo-wrapped fetch would fail on private repos.
fn sync_worktree(cfg: &BuildCfg, branch: &str, slug: &str) -> String {
    let url = repo_url(cfg);
    let base = cfg.base_dir();
    let repo = cfg.repo_dir();
    let wt = cfg.wt_dir(slug);

    // Clone (or repair an interrupted clone), then fetch. `--no-checkout`
    // because .repo only ever holds the object store — the branches live in
    // worktrees next to it.
    let setup = format!(
        "set -e; mkdir -p \"$HOME/{base}\" \"$HOME/{cache}\"; \
         chmod 700 \"$HOME/{REMOTE_BASE}\" \"$HOME/{base}\"; \
         r=\"$HOME/{repo}\"; \
         if [ -d \"$r\" ] && ! git -C \"$r\" rev-parse --git-dir >/dev/null 2>&1; then rm -rf \"$r\"; fi; \
         if [ ! -d \"$r\" ]; then git clone --quiet --no-checkout {url} \"$r\"; fi; \
         git -C \"$r\" remote set-url origin {url}; \
         git -C \"$r\" fetch --prune --quiet origin",
        cache = cfg.cache_dir(),
        url = shq(&url),
    );
    println!("{DIM}git fetch auf atlas ({url}){RESET}");
    if !run_inherit(Command::new("ssh").args([ssh_host(), &setup])) {
        eprintln!("{RED}git fetch auf atlas fehlgeschlagen{RESET}");
        eprintln!(
            "{DIM}  private Repos brauchen ~/.git-credentials auf atlas (https, nicht git@…){RESET}"
        );
        exit(1);
    }

    // Resolve the branch before touching the worktree, so a typo is a sentence
    // and not a git stack trace half-way through a checkout.
    let commit = ssh_capture(&format!(
        "git -C \"$HOME/{repo}\" rev-parse --verify --quiet {rev}",
        rev = shq(&format!("refs/remotes/origin/{branch}^{{commit}}")),
    ))
    .trim()
    .to_string();
    if commit.len() < 7 || !commit.chars().all(|c| c.is_ascii_hexdigit()) {
        eprintln!("{RED}Branch '{branch}' gibt es auf dem Remote nicht{RESET}");
        let list = ssh_capture(&format!(
            "git -C \"$HOME/{repo}\" for-each-ref --format='%(refname:strip=3)' \
             refs/remotes/origin | grep -v '^HEAD$' | head -20"
        ));
        let list: Vec<&str> = list.split_whitespace().collect();
        if !list.is_empty() {
            eprintln!("{DIM}  vorhanden: {}{RESET}", list.join(", "));
        }
        exit(1);
    }

    // Create or update the worktree, and heal anything a killed run left
    // behind: a stale admin entry, a directory that is no longer a worktree, a
    // half-finished rebase/merge, local modifications. The tree is disposable
    // by design, so healing means throwing it away rather than asking.
    //
    // Detached HEAD, not a local branch: two worktrees may not check out the
    // same branch, and we only ever want exactly what origin/<branch> points at.
    //
    // `clean -ffd` without -x on purpose — ignored files are node_modules, the
    // package caches and the build output, i.e. everything that makes the next
    // run warm. Only untracked-and-not-ignored leftovers go.
    let update = format!(
        "set -e; r=\"$HOME/{repo}\"; w=\"$HOME/{wt}\"; \
         git -C \"$r\" worktree prune; \
         if [ -d \"$w\" ] && ! git -C \"$w\" rev-parse --is-inside-work-tree >/dev/null 2>&1; \
           then rm -rf \"$w\"; fi; \
         if [ -d \"$w\" ]; then \
           ( for op in am rebase merge cherry-pick revert; do \
               git -C \"$w\" $op --abort >/dev/null 2>&1 || true; done; \
             git -C \"$w\" reset --hard --quiet {sha} && git -C \"$w\" clean -ffdq ) \
           || rm -rf \"$w\"; \
         fi; \
         if [ ! -d \"$w\" ]; then mkdir -p \"$HOME/{base}/wt\"; \
           git -C \"$r\" worktree add --detach --force --quiet \"$w\" {sha}; fi; \
         chmod 700 \"$w\"; \
         find \"$w\" -user \"$(id -un)\" \\( -type d -o -type f \\) \
           -exec chmod go= {{}} + 2>/dev/null || true",
        sha = shq(&commit),
    );
    // The permissions walk is the same one the old rsync did and for the same
    // reason: this tree is a checkout of a PRIVATE repo on a box where other
    // processes exist. Scoped to files we own because a dev container runs as
    // root and leaves root-owned output that a bare `chmod -R` chokes on.
    if !run_inherit(Command::new("ssh").args([ssh_host(), &update])) {
        eprintln!("{RED}Worktree für '{branch}' konnte nicht aktualisiert werden{RESET}");
        eprintln!("{DIM}  Notausgang:  ssh {} 'rm -rf ~/{wt}'  und nochmal{RESET}", ssh_host());
        exit(1);
    }
    println!("{DIM}  {branch} @ {}{RESET}", short(&commit));
    commit
}

/// The current tip of <branch> on the remote, or None when it cannot be asked.
/// Used for the staleness warning only — no network must never block a start.
fn remote_tip(cfg: &BuildCfg, branch: &str) -> Option<String> {
    let out = ssh_capture(&format!(
        "git -C \"$HOME/{repo}\" ls-remote --heads origin {b} 2>/dev/null | head -1 | cut -f1",
        repo = cfg.repo_dir(),
        b = shq(branch),
    ));
    let sha = out.trim().to_string();
    (sha.len() >= 7 && sha.chars().all(|c| c.is_ascii_hexdigit())).then_some(sha)
}

/// Hash key for a project's `tailscale serve` port.
///
/// `main` in dev mode keeps the bare project name, so the URL a project has
/// always had — and every OAuth redirect, webhook and `allowedDevOrigins`
/// entry configured against it — does not move now that branches exist.
/// Everything else gets its own port, so two branches (or a dev server and a
/// started build) can be up at the same time without fighting.
fn port_key(cfg: &BuildCfg, slug: &str, mode: &str) -> String {
    if slug == "main" && mode == "dev" {
        cfg.name.clone()
    } else {
        format!("{}/{slug}#{mode}", cfg.name)
    }
}

/// Write the per-branch build record. Only ever called after a build exited 0,
/// so a failed build cannot leave a target that `atlas start` would trust.
///
/// Written to a temp file and moved into place: a run killed mid-write would
/// otherwise leave truncated JSON that reads as "no target" at best and as a
/// bogus commit at worst.
fn write_state(cfg: &BuildCfg, branch: &str, slug: &str, commit: &str, secs: u64) {
    let arts = cfg.artifacts.iter().map(|a| format!("\"{a}\"")).collect::<Vec<_>>().join(",");
    // The timestamp is the box's, taken at write time, and is passed as its own
    // printf argument: everything else goes through shq(), which single-quotes
    // and would keep a `$(date …)` as literal text.
    let head = format!("{{\"branch\":\"{branch}\",\"commit\":\"{commit}\",\"built_at\":\"");
    let tail = format!(
        "\",\"ok\":true,\"seconds\":{secs},\"image\":\"{img}\",\"artifacts\":[{arts}]}}",
        img = cfg.image,
    );
    let f = cfg.state_file(slug);
    ssh_ok(&format!(
        "mkdir -p \"$(dirname \"$HOME/{f}\")\" \
         && printf '%s%s%s\\n' {h} \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" {t} > \"$HOME/{f}.tmp\" \
         && mv \"$HOME/{f}.tmp\" \"$HOME/{f}\"",
        h = shq(&head),
        t = shq(&tail),
    ));
}

/// One field out of the per-branch state file. Empty when there is no target,
/// the file is unreadable, or the field is missing — every caller treats empty
/// as "no usable target" rather than guessing.
fn state_field(cfg: &BuildCfg, slug: &str, key: &str) -> String {
    ssh_capture(&format!(
        "sed -n 's/.*\"{key}\":\"\\([^\"]*\\)\".*/\\1/p' \"$HOME/{f}\" 2>/dev/null | head -1",
        f = cfg.state_file(slug),
    ))
    .trim()
    .to_string()
}

/// Branches that currently have a successful build on atlas.
fn built_branches(cfg: &BuildCfg) -> Vec<String> {
    let out = ssh_capture(&format!(
        "ls \"$HOME/{}/state\" 2>/dev/null | sed 's/\\.json$//'",
        cfg.base_dir()
    ));
    out.split_whitespace().map(branch_of_slug).collect()
}

fn build(argv: &[String]) {
    let (branch, extra) = take_branch(argv);
    let slug = slug_of(&branch);
    let cfg = load_config();
    if cfg.build.is_empty() || cfg.artifacts.is_empty() {
        eprintln!("{RED}.atlas-build.toml hat kein build/artifacts{RESET}");
        exit(1);
    }
    ensure_up();
    let spec = cfg.spec(false);
    ensure_image(&spec);
    warn_if_secrets_unpushed(&cfg);
    let commit = sync_worktree(&cfg, &branch, &slug);

    // Everything after a literal `--` is for the build command, not for us.
    let mut buildcmd = cfg.build.clone();
    for a in extra.iter().filter(|a| a.as_str() != "--") {
        buildcmd.push(' ');
        buildcmd.push_str(a);
    }
    // .repo is mounted at its own absolute path, not just /build: a worktree's
    // `.git` is a FILE containing `gitdir: <abs path into .repo>`. Without the
    // object store visible at exactly that path, every git command inside the
    // build fails with "not a git repository" — which breaks any build that
    // stamps a version or embeds a commit.
    //
    // Run as root inside the container (works for every base image, incl.
    // flutter's SDK dir), then chown the worktree back to the SSH user so the
    // next fetch and the next start don't trip over root-owned files. `; rc=$?`
    // keeps the build's exit code even though the chown always runs.
    let remote = format!(
        "{prologue}docker run --rm $envf \
         -e CARGO_HOME=/cache/cargo -e npm_config_cache=/cache/npm \
         -e PUB_CACHE=/cache/pub -e XDG_CACHE_HOME=/cache/xdg \
         -e GRADLE_USER_HOME=/cache/gradle \
         -v \"$HOME/{wt}\":/build -v \"$HOME/{cache}\":/cache \
         -v \"$HOME/{repo}\":\"$HOME/{repo}\" \
         -w {wd} {tag} sh -c {cmd}; rc=$?; \
         sudo chown -R $(id -u):$(id -g) \"$HOME/{wt}\" >/dev/null 2>&1; exit $rc",
        prologue = env_file_prologue(&cfg),
        wt = cfg.wt_dir(&slug),
        cache = cfg.cache_dir(),
        repo = cfg.repo_dir(),
        wd = cfg.workdir(),
        tag = spec.tag,
        cmd = shq(&buildcmd),
    );
    println!("{DIM}build auf atlas ({}):{RESET} {buildcmd}", spec.tag);
    let t0 = Instant::now();
    let ok = run_inherit(Command::new("ssh").args([ssh_host(), &remote]));
    let secs = t0.elapsed().as_secs();
    if !ok {
        eprintln!("{RED}Build fehlgeschlagen{RESET} (nach {secs}s)");
        eprintln!("{DIM}  kein Target für '{branch}' hinterlegt — atlas start bleibt beim alten{RESET}");
        exit(1);
    }

    // The build said 0; make sure it actually produced what it claims, so
    // `atlas start` cannot be pointed at an empty directory.
    let missing = ssh_capture(&format!(
        "for a in {arts}; do [ -e \"$HOME/{wt}/$a\" ] || echo \"$a\"; done",
        arts = cfg.artifacts.iter().map(|a| shq(a)).collect::<Vec<_>>().join(" "),
        wt = cfg.wt_dir(&slug),
    ));
    let missing: Vec<&str> = missing.split_whitespace().collect();
    if !missing.is_empty() {
        eprintln!("{RED}Build meldete Erfolg, aber es fehlt:{RESET} {}", missing.join(", "));
        eprintln!("{DIM}  kein Target hinterlegt — artifacts in .atlas-build.toml prüfen{RESET}");
        exit(1);
    }

    write_state(&cfg, &branch, &slug, &commit, secs);
    println!(
        "{GREEN}✓ build fertig{RESET} in {}m {:02}s  {DIM}({branch} @ {}, {}){RESET}",
        secs / 60,
        secs % 60,
        short(&commit),
        spec.tag
    );
    println!("{DIM}  starten:  atlas start{}{RESET}", if branch == "main" { String::new() } else { format!(" -b {branch}") });
}

// ---- atlas start: run what `atlas build` produced, for one branch ---------

fn start(argv: &[String]) {
    let (branch, rest) = take_branch(argv);
    let slug = slug_of(&branch);
    let cfg = load_config();
    match rest.first().map(String::as_str) {
        Some("stop") => start_stop(&cfg, &slug, &branch),
        Some("logs") => start_logs(&cfg, &slug),
        Some("status") => start_status(&cfg, &slug, &branch),
        _ => start_run(&cfg, &branch, &slug),
    }
}

fn start_name(cfg: &BuildCfg, slug: &str) -> String {
    format!("atlas-start-{}-{slug}", cfg.name)
}

fn start_run(cfg: &BuildCfg, branch: &str, slug: &str) {
    ensure_up();

    // Branch-native, and this is the whole point: start never builds. A branch
    // without a target is a stop, not an implicit 20-minute build.
    let commit = state_field(cfg, slug, "commit");
    if commit.is_empty() {
        eprintln!("{RED}kein Target für '{branch}' auf atlas{RESET}");
        let have = built_branches(cfg);
        if have.is_empty() {
            eprintln!("{DIM}  für dieses Projekt wurde noch nichts gebaut{RESET}");
        } else {
            eprintln!("{DIM}  gebaut: {}{RESET}", have.join(", "));
        }
        eprintln!("{DIM}  bauen mit:  atlas build{}{RESET}", if branch == "main" { String::new() } else { format!(" -b {branch}") });
        exit(1);
    }

    // Stale is a warning, never a refusal: the user asked for the built
    // target, not for the newest code.
    if let Some(tip) = remote_tip(cfg, branch)
        && tip != commit
    {
        println!(
            "{DIM}Achtung: Target ist {} , origin/{branch} steht auf {} — atlas build zum Auffrischen{RESET}",
            short(&commit),
            short(&tip)
        );
    }

    let spec = cfg.spec(true);
    ensure_image(&spec);
    warn_if_secrets_unpushed(cfg);
    let name = start_name(cfg, slug);

    // Fresh container and a fresh serve mapping: the mapping outlives the
    // container, so a stale one would proxy to a port nothing listens on.
    ssh_ok(&format!("docker rm -f {name} >/dev/null 2>&1"));
    serve_off(cfg, slug, "start");

    let run = format!(
        "{prologue}docker run -d --name {name} --network host --restart unless-stopped $envf \
         -e npm_config_cache=/cache/npm -e HOST=0.0.0.0 -e PORT={port} \
         -v \"$HOME/{wt}\":/build -v \"$HOME/{cache}\":/cache \
         -v \"$HOME/{repo}\":\"$HOME/{repo}\" \
         -w {wd} {tag} sh -c {cmd} >/dev/null",
        prologue = env_file_prologue(cfg),
        port = cfg.port,
        wt = cfg.wt_dir(slug),
        cache = cfg.cache_dir(),
        repo = cfg.repo_dir(),
        wd = cfg.workdir(),
        tag = spec.tag,
        cmd = shq(&cfg.start_cmd()),
    );
    if !ssh_ok(&run) {
        eprintln!("{RED}Start fehlgeschlagen{RESET}");
        exit(1);
    }
    println!("{GREEN}✓ {} läuft{RESET}  {DIM}({branch} @ {}){RESET}", cfg.name, short(&commit));
    match tailnet_host() {
        Some(host) => {
            let port = tailnet_port(&port_key(cfg, slug, "start"));
            if ssh_ok(&format!(
                "sudo tailscale serve --bg --https={port} http://127.0.0.1:{app} >/dev/null",
                app = cfg.port
            )) {
                println!("  {GREEN}https://{host}:{port}{RESET}");
            }
        }
        None => println!("{DIM}  kein Tailnet-Host gesetzt — nur auf atlas selbst erreichbar{RESET}"),
    }
    println!("{DIM}  Logs:  atlas start logs   ·   Stop:  atlas start stop{RESET}");
}

fn start_stop(cfg: &BuildCfg, slug: &str, branch: &str) {
    ssh_ok(&format!("docker rm -f {} >/dev/null 2>&1", start_name(cfg, slug)));
    serve_off(cfg, slug, "start");
    println!("{GREEN}gestoppt{RESET} ({} @ {branch})", cfg.name);
}

fn start_logs(cfg: &BuildCfg, slug: &str) -> ! {
    let err = Command::new("ssh")
        .args(["-t", ssh_host(), &format!("docker logs -f {}", start_name(cfg, slug))])
        .exec();
    eprintln!("ssh: {err}");
    exit(1);
}

fn start_status(cfg: &BuildCfg, slug: &str, branch: &str) {
    let commit = state_field(cfg, slug, "commit");
    if commit.is_empty() {
        println!("{DIM}kein Target für '{branch}'{RESET}");
        let have = built_branches(cfg);
        if !have.is_empty() {
            println!("{DIM}  gebaut: {}{RESET}", have.join(", "));
        }
        return;
    }
    let built = state_field(cfg, slug, "built_at");
    let running = ssh_capture(&format!(
        "docker inspect -f '{{{{.State.Running}}}}' {} 2>/dev/null",
        start_name(cfg, slug)
    ));
    println!("{}  {branch} @ {}", cfg.name, short(&commit));
    println!("  gebaut:  {}", if built.is_empty() { "?".into() } else { built });
    println!("  läuft:   {}", if running.trim() == "true" { "ja" } else { "nein" });
    if let Some(tip) = remote_tip(cfg, branch)
        && tip != commit
    {
        println!("  {DIM}veraltet — origin/{branch} steht auf {}{RESET}", short(&tip));
    }
}

// ---- atlas dev: run a dev server on atlas, on the tailnet by default ------

fn dev(argv: &[String]) {
    let (branch, sub) = take_branch(argv);
    let slug = slug_of(&branch);
    let cfg = load_config();
    match sub.first().map(String::as_str) {
        Some("stop") => dev_stop(&cfg, &slug, &branch),
        Some("url") => {
            println!("{}", dev_url(&cfg, &slug).unwrap_or_else(|| "(kein dev-Server aktiv)".into()))
        }
        Some("logs") => dev_logs(&cfg, &slug),
        // `--tunnel` is the old mental model ("gib mir den Tunnel"), `--public`
        // says what actually changes: the dev server leaves the tailnet.
        _ => dev_start(&cfg, &branch, &slug, sub.iter().any(|a| a == "--public" || a == "--tunnel")),
    }
}

fn dev_names(cfg: &BuildCfg, slug: &str) -> (String, String) {
    (format!("atlas-dev-{}-{slug}", cfg.name), format!("atlas-tunnel-{}-{slug}", cfg.name))
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
fn dev_url(cfg: &BuildCfg, slug: &str) -> Option<String> {
    tailnet_url(cfg, slug).or_else(|| tunnel_url(cfg, slug))
}

/// The tailnet URL, but only if `tailscale serve` is really publishing it —
/// `atlas dev url` must not print an address that answers nothing.
fn tailnet_url(cfg: &BuildCfg, slug: &str) -> Option<String> {
    let host = tailnet_host()?;
    let port = tailnet_port(&port_key(cfg, slug, "dev"));
    // `serve status` is readable without sudo and prints one `https://host:port`
    // line per published port; anchor the match so the proxy target lines
    // ("|-- / proxy http://127.0.0.1:3000") cannot match a port by accident.
    let up = ssh_capture(&format!(
        "tailscale serve status 2>/dev/null | grep -qE '^https://[^ ]+:{port}([ /]|$)' && echo up"
    ));
    (up.trim() == "up").then(|| format!("https://{host}:{port}"))
}

/// Scrape the public URL out of the tunnel container's logs.
fn tunnel_url(cfg: &BuildCfg, slug: &str) -> Option<String> {
    let (_, tunnel) = dev_names(cfg, slug);
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
fn serve_off(cfg: &BuildCfg, slug: &str, mode: &str) {
    if tailnet_host().is_none() {
        return;
    }
    let port = tailnet_port(&port_key(cfg, slug, mode));
    ssh_ok(&format!("sudo tailscale serve --https={port} off >/dev/null 2>&1"));
}

fn dev_stop(cfg: &BuildCfg, slug: &str, branch: &str) {
    let (dev, tunnel) = dev_names(cfg, slug);
    ssh_ok(&format!("docker rm -f {dev} {tunnel} >/dev/null 2>&1"));
    serve_off(cfg, slug, "dev");
    println!("{GREEN}dev gestoppt{RESET} ({} @ {branch})", cfg.name);
}

fn dev_logs(cfg: &BuildCfg, slug: &str) -> ! {
    let (dev, _) = dev_names(cfg, slug);
    let err = Command::new("ssh")
        .args(["-t", ssh_host(), &format!("docker logs -f {dev}")])
        .exec();
    eprintln!("ssh: {err}");
    exit(1);
}

fn dev_start(cfg: &BuildCfg, branch: &str, slug: &str, public: bool) {
    if cfg.dev.is_empty() {
        eprintln!("{RED}.atlas-build.toml hat kein dev = ...{RESET}");
        exit(1);
    }
    ensure_up();
    let spec = cfg.spec(true);
    ensure_image(&spec);
    warn_if_secrets_unpushed(cfg);
    let commit = sync_worktree(cfg, branch, slug);
    let (dev, tunnel) = dev_names(cfg, slug);

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
    serve_off(cfg, slug, "dev");

    // dev server: --network host so it binds atlas' real port; node_modules
    // persist in the branch's worktree (git clean keeps ignored files), so the
    // install is warm after the first run on that branch.
    //
    // The install step is picked from the lockfile rather than hardcoded to
    // npm: a bun or pnpm project used to get `npm install` run over it, which
    // either fails or silently produces a second, wrong dependency tree.
    let devcmd = format!("{} && {}", cfg.install_cmd(), cfg.dev);
    let run_dev = format!(
        "{prologue}docker run -d --name {dev} --network host --restart unless-stopped $envf \
         -e npm_config_cache=/cache/npm -e HOST=0.0.0.0 -e PORT={port} \
         -v \"$HOME/{wt}\":/build -v \"$HOME/{cache}\":/cache \
         -v \"$HOME/{repo}\":\"$HOME/{repo}\" \
         -w {wd} {tag} sh -c {cmd} >/dev/null",
        prologue = env_file_prologue(cfg),
        port = cfg.port,
        wt = cfg.wt_dir(slug),
        cache = cfg.cache_dir(),
        repo = cfg.repo_dir(),
        wd = cfg.workdir(),
        tag = spec.tag,
        cmd = shq(&devcmd),
    );
    if !ssh_ok(&run_dev) {
        eprintln!("{RED}dev-Container-Start fehlgeschlagen{RESET}");
        exit(1);
    }

    match tailnet {
        Some(host) => dev_expose_tailnet(cfg, slug, host),
        None => dev_expose_tunnel(cfg, slug, &spec),
    }
    println!(
        "{DIM}  dev-Server läuft auf atlas ({} @ {branch}, {}), Mac bleibt kühl.{RESET}",
        cfg.name,
        short(&commit)
    );
    // Deliberately no "edit live on atlas" hint any more: the worktree is
    // disposable and every run hard-resets it to origin/<branch>. Edit on the
    // Mac (or wherever), push, and run this again.
    println!("{DIM}  Änderungen:  push → atlas dev{RESET}");
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
fn dev_expose_tailnet(cfg: &BuildCfg, slug: &str, host: &str) {
    let port = tailnet_port(&port_key(cfg, slug, "dev"));
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
fn dev_expose_tunnel(cfg: &BuildCfg, slug: &str, spec: &ImageSpec) {
    let (_, tunnel) = dev_names(cfg, slug);
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
        if let Some(u) = tunnel_url(cfg, slug) {
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
/// `set -e` plus the `&&` chain is deliberate: nothing is installed and the
/// running unit is not restarted unless the release build succeeded. This is
/// the same SSH path that manages the box' power, so a half-applied update
/// would leave it with no control plane and no way back in but a physical one.
fn api_install() {
    ensure_up();
    println!("{DIM}baue + installiere atlas-api auf atlas ...{RESET}");
    let script = "set -e; cd ~/atlas && git fetch --quiet origin && \
         git reset --hard --quiet origin/main && cd api && \
         . ~/.cargo/env && cargo build --release --quiet && \
         sudo install -m755 target/release/atlas-api /usr/local/bin/atlas-api && \
         sed \"s|^User=.*|User=$(id -un)|\" atlas-api.service \
           | sudo tee /etc/systemd/system/atlas-api.service >/dev/null && \
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
