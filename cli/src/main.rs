//! atlas — control the atlas homelab build server from the Mac.
//!
//!   atlas              interactive SSH session (execs `ssh atlas`)
//!   atlas boot         Wake-on-LAN, waits until SSH is reachable
//!   atlas shutdown     powers the box off, waits until it is down
//!   atlas restart      reboot, waits for the box to come back
//!   atlas status       is it up? which route (LAN / tailnet)?
//!   atlas build        build this project on atlas (a pushed branch, or --local)
//!   atlas dev          run this project's dev server on atlas
//!   atlas start        run what `atlas build` produced for a branch
//!   atlas secrets      push/list/drop this project's env file on atlas
//!   atlas api          build + install atlas-api (the control-plane server)
//!   atlas <cmd ...>    run any command on atlas (forwarded to ssh)

mod api;
mod build;
mod config;
mod dev;
mod exec;
mod git;
mod hash;
mod machine;
mod observe;
mod project;
mod secrets;
mod serve;
mod ssh;
mod state;
mod web;

use std::env;

/// ANSI colors, shared across the whole binary.
pub(crate) const GREEN: &str = "\x1b[32m";
pub(crate) const RED: &str = "\x1b[31m";
pub(crate) const DIM: &str = "\x1b[2m";
pub(crate) const RESET: &str = "\x1b[0m";

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => ssh::ssh(&[]),
        Some("boot") | Some("up") | Some("wake") => machine::boot(),
        Some("shutdown") | Some("off") | Some("poweroff") => machine::shutdown(),
        Some("restart") | Some("reboot") => machine::restart(),
        Some("status") => machine::status(),
        Some("build") => build::build(&args[1..]),
        Some("test") => exec::test(&args[1..]),
        Some("exec") => exec::exec(&args[1..]),
        Some("run") => exec::run(&args[1..]),
        Some("watch") => observe::watch(&args[1..]),
        Some("dev") => dev::dev(&args[1..]),
        Some("start") => serve::start(&args[1..]),
        Some("api") => api::api(&args[1..]),
        Some("secrets") => secrets::secrets(&args[1..]),
        Some("ls") => observe::ls(),
        Some("logs") => observe::logs(&args[1..]),
        Some("health") => observe::health(&args[1..]),
        Some("open") => observe::open(&args[1..]),
        Some("doctor") => observe::doctor(),
        Some("info") => observe::info(),
        Some("migrate") => config::migrate(&args[1..]),
        Some("help") | Some("-h") | Some("--help") => help(),
        // Handle before the ssh passthrough below, or `atlas --version` would
        // run `ssh atlas --version` and print ssh's usage.
        Some("--version") | Some("-V") | Some("version") => {
            println!("atlas {}", env!("CARGO_PKG_VERSION"));
        }
        // anything else: run it on atlas (`atlas htop`, `atlas nvidia-smi`, ...)
        Some(_) => ssh::ssh(&args),
    }
}

fn help() {
    println!(
        "atlas — the homelab build server\n\n\
         USAGE\n  \
         atlas                SSH into atlas\n  \
         atlas <cmd ...>      run a command on atlas (e.g. atlas nvidia-smi)\n\n\
         MACHINE\n  \
         atlas boot           wake via WoL, wait until reachable\n  \
         atlas shutdown       power off, wait until down\n  \
         atlas restart        reboot, wait until back\n  \
         atlas status         up/down + route (LAN / tailnet)\n  \
         atlas doctor         preflight: reachability, docker, disk, images, tunnel, Caddy\n\n\
         BUILD {DIM}(needs atlas.toml; --branch B | -b B, default main; --local = working tree){RESET}\n  \
         atlas build [-b B]        build a pushed branch on atlas (atlas fetches it from GitHub)\n  \
         atlas build --local       build the local working tree (uncommitted, no push)\n  \
         atlas build --path D       build subdir D as its own root (its own atlas.toml)\n  \
         atlas build --target T     build the named [target.T] from the root config\n  \
         atlas build ... -- ...     everything after '--' goes to the build command\n  \
         atlas test  [-b B] [-- a]  run tests on atlas (cargo/npm test); exit code returns\n  \
         atlas exec  [-b B] -- CMD  fresh-sync, then run CMD in the build root on atlas\n  \
         atlas run   [-b B] -- CMD  run a BUILT artifact on atlas (no sync, no rebuild)\n  \
         atlas watch                watch the working tree, re-run build --local on change\n  \
         {DIM}test/exec/run share --local | --path D | --target T; run with --network host{RESET}\n\n\
         SERVE\n  \
         atlas dev   [-b B]         dev server on atlas, on the tailnet (private, stable URL)\n  \
         atlas dev   [-b B] --public  publish at https://<name>.lukaloehr.com (stable)\n  \
         atlas dev   [-b B] url|logs|stop\n  \
         atlas start [-b B]         run the BUILT result of this branch\n  \
         atlas start [-b B] status|logs|stop\n  \
         atlas api                  build + install the control-plane API  ·  api logs|status|stop|restart\n\n\
         OBSERVE\n  \
         atlas ls                   fleet: every project on atlas — branches, running, URL, disk\n  \
         atlas logs  [-b B] [-f]     docker logs of this project's dev/start container\n  \
         atlas health [-b B]        HTTP-probe the dev/start URL; non-zero exit if unhealthy\n  \
         atlas open  [-b B]         open the dev/start URL in the browser\n  \
         atlas info                 this project: name, repo, hash, remote dir, image, URL, secrets\n\n\
         CONFIG\n  \
         atlas secrets push [file]  upload env file for this project (never in git, 0600 on atlas)\n  \
         atlas secrets list|rm      which projects have one  ·  drop this project's\n  \
         atlas migrate              convert a .atlas-build.toml config file to atlas.toml\n  \
         atlas --version            print the version"
    );
}
