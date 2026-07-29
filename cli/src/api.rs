//! `atlas api`: build + install and manage the control-plane systemd unit.

use std::os::unix::process::CommandExt;
use std::process::{Command, exit};

use crate::config::{config, ssh_host};
use crate::ssh::{ensure_up, run_inherit};
use crate::{DIM, GREEN, RED, RESET};

pub(crate) fn api(sub: &[String]) {
    match sub.first().map(String::as_str) {
        Some("logs") => {
            let err = Command::new("ssh")
                .args(["-t", ssh_host(), "journalctl -u atlas-api -f -n 40"])
                .exec();
            eprintln!("ssh: {err}");
            exit(1);
        }
        // `systemctl status` exits non-zero for an inactive unit, which is an
        // answer, not a failure.
        Some("status") => {
            run_inherit(Command::new("ssh").args([
                ssh_host(),
                "systemctl status atlas-api --no-pager | head -12",
            ]));
        }
        Some("stop") => systemctl("stop", "atlas-api stopped"),
        Some("restart") => systemctl("restart", "atlas-api restarted"),
        _ => api_install(),
    }
}

/// `sudo systemctl <verb> atlas-api`, reporting what actually happened.
fn systemctl(verb: &str, done: &str) {
    let ok = run_inherit(
        Command::new("ssh").args([ssh_host(), &format!("sudo systemctl {verb} atlas-api")]),
    );
    if !ok {
        eprintln!("{RED}systemctl {verb} atlas-api failed{RESET}");
        exit(1);
    }
    println!("{GREEN}{done}{RESET}");
}

/// Pull the repo on atlas, build the API server, install + enable the unit.
///
/// `set -e` plus the `&&` chain is deliberate: nothing is installed and the
/// running unit is not restarted unless the release build succeeded.
fn api_install() {
    ensure_up();
    println!("{DIM}building + installing atlas-api on atlas ...{RESET}");
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
        eprintln!("{RED}API installation failed{RESET}");
        exit(1);
    }
    let host = config().api_url.as_str();
    println!("{GREEN}✓ atlas-api is running{RESET}  {DIM}(systemd, autostart on){RESET}");
    if !host.is_empty() {
        println!("  {DIM}metrics:{RESET} http://{host}/api/metrics");
        println!("  {DIM}enter as host in the app:{RESET} {host}");
    }
}
