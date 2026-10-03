//! `atlas deploy`: build + install the Atlas services on the server, and
//! manage their systemd units. `atlas connect`: the link that sets up the app.

use std::os::unix::process::CommandExt;
use std::process::{Command, exit};

use crate::config::{config, ssh_host};
use crate::ssh::{ensure_up, run_inherit};
use crate::{DIM, GREEN, RED, RESET};

const UNITS: &str = "atlas-server atlas-ml";

pub(crate) fn deploy(sub: &[String]) {
    match sub.first().map(String::as_str) {
        Some("logs") => {
            let err = Command::new("ssh")
                .args(["-t", ssh_host(), "journalctl -u atlas-server -u atlas-ml -f -n 60"])
                .exec();
            eprintln!("ssh: {err}");
            exit(1);
        }
        // `systemctl status` exits non-zero for an inactive unit, which is an
        // answer, not a failure.
        Some("status") => {
            run_inherit(Command::new("ssh").args([
                ssh_host(),
                &format!("systemctl status {UNITS} --no-pager --lines=0"),
            ]));
        }
        Some("stop") => systemctl("stop", "Atlas services stopped"),
        Some("restart") => systemctl("restart", "Atlas services restarted"),
        _ => install(),
    }
}

/// `sudo systemctl <verb>` on both units, reporting what actually happened.
fn systemctl(verb: &str, done: &str) {
    let ok = run_inherit(
        Command::new("ssh").args([ssh_host(), &format!("sudo systemctl {verb} {UNITS}")]),
    );
    if !ok {
        eprintln!("{RED}systemctl {verb} {UNITS} failed{RESET}");
        exit(1);
    }
    println!("{GREEN}{done}{RESET}");
}

/// Bring the checkout on the server to origin/main and run its installer,
/// which builds both services and only then installs and restarts them.
fn install() {
    ensure_up();
    println!("{DIM}building + installing atlas-server and atlas-ml on atlas ...{RESET}");
    let script = "set -e; cd ~/atlas && git fetch --quiet origin && \
         git reset --hard --quiet origin/main && scripts/atlas/install.sh";
    if !run_inherit(Command::new("ssh").args([ssh_host(), script])) {
        eprintln!("{RED}deploy failed{RESET}");
        exit(1);
    }
    let host = config().server_url.as_str();
    println!("{GREEN}✓ Atlas is running{RESET}  {DIM}(systemd, autostart on){RESET}");
    if !host.is_empty() {
        println!("  {DIM}server address for the app:{RESET} http://{host}");
    }
}

/// Print the link that connects the iOS app: the server address and the
/// token it needs, in one URL the app opens. The token is read from the
/// server's env file over ssh and never stored on this machine.
pub(crate) fn connect() {
    ensure_up();
    let host = config().server_url.as_str();
    if host.is_empty() {
        eprintln!("{RED}no server address:{RESET} set ATLAS_SERVER_URL (or ATLAS_TAILNET_ADDR) in ~/.config/atlas/env");
        exit(1);
    }
    let out = Command::new("ssh")
        .args([ssh_host(), "sudo sed -n 's/^ATLAS_TOKEN=//p' /etc/atlas/atlas.env"])
        .output();
    let token = match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => String::new(),
    };
    if token.is_empty() {
        eprintln!("{RED}no ATLAS_TOKEN in /etc/atlas/atlas.env on the server{RESET}");
        exit(1);
    }
    // the address is a URL inside a URL: escape what would end the parameter
    let address = format!("http://{host}").replace(':', "%3A").replace('/', "%2F");
    println!("atlas://connect?url={address}&token={token}");
    eprintln!("{DIM}open this link on the iPhone (AirDrop, Notes, Messages) with Atlas installed{RESET}");
}
