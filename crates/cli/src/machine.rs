//! Power control: boot (Wake-on-LAN), shutdown, restart, status.

use std::io::{self, Write};
use std::process::{Command, exit};
use std::time::Duration;

use crate::config::{config, ssh_host};
use crate::ssh::{probe, send_wol, wait_for};
use crate::{DIM, GREEN, RED, RESET};

pub(crate) fn boot() {
    if let Some(route) = probe() {
        println!("{GREEN}atlas is already running{RESET} ({route})");
        return;
    }
    if config().wol_mac_is_default {
        println!(
            "{DIM}note: ATLAS_WOL_MAC is not set — the placeholder wakes no real server{RESET}"
        );
    }
    if let Err(e) = send_wol() {
        eprintln!("{RED}WoL packet failed:{RESET} {e}");
        exit(1);
    }
    print!("magic packet sent, waiting for boot {DIM}(only possible on the home LAN){RESET} ");
    io::stdout().flush().ok();
    if wait_for(true, Duration::from_secs(120)) {
        println!(" {GREEN}atlas is awake{RESET}");
    } else {
        println!(
            " {RED}timeout{RESET} — not on the LAN? Otherwise: wake via the router's remote access"
        );
        exit(1);
    }
}

pub(crate) fn shutdown() {
    if probe().is_none() {
        println!("atlas is already off");
        return;
    }
    // ssh often reports 255 when poweroff drops the connection — ignore the
    // exit code and trust the port-22-down probe instead
    Command::new("ssh")
        .args([ssh_host(), "sudo poweroff"])
        .output()
        .ok();
    print!("poweroff sent, waiting ");
    io::stdout().flush().ok();
    if wait_for(false, Duration::from_secs(60)) {
        println!(" {GREEN}atlas is off{RESET}");
    } else {
        println!(" {RED}atlas still responds{RESET} — please check manually");
        exit(1);
    }
}

pub(crate) fn restart() {
    if probe().is_none() {
        println!("atlas is off — use `atlas boot`");
        exit(1);
    }
    Command::new("ssh")
        .args([ssh_host(), "sudo reboot"])
        .output()
        .ok();
    print!("reboot sent, waiting for shutdown ");
    io::stdout().flush().ok();
    if !wait_for(false, Duration::from_secs(60)) {
        println!(" {RED}atlas is not going down{RESET}");
        exit(1);
    }
    print!(" it is down, waiting for boot ");
    io::stdout().flush().ok();
    if wait_for(true, Duration::from_secs(120)) {
        println!(" {GREEN}atlas is back up{RESET}");
    } else {
        println!(" {RED}timeout while coming back up{RESET}");
        exit(1);
    }
}

pub(crate) fn status() {
    match probe() {
        Some(route) => println!("{GREEN}●{RESET} atlas is up  {DIM}via {route}{RESET}"),
        None => println!("{RED}●{RESET} atlas is off"),
    }
}
