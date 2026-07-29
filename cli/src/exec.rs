//! `atlas test / exec / run`: execute on atlas, not just build there.
//!
//!   test   fresh-sync the tree, then run `cargo test`/`npm test` (or `test =`)
//!   exec   fresh-sync the tree, then run an arbitrary `-- CMD`
//!   run    run `-- CMD` against the ALREADY-built tree — no sync, no rebuild
//!
//! exec is the primitive; test and exec share the sync path, run skips it.

use std::process::{Command, exit};

use crate::build::{
    BuildFlags, command_from_extra, reject_local_with_branch, take_branch, take_build_flags,
};
use crate::config::ssh_host;
use crate::git::{git_toplevel, sync_local, sync_worktree};
use crate::project::{BuildCfg, ImageSpec, ensure_image, load_config_at, slug_of};
use crate::secrets::{env_file_prologue, warn_if_secrets_unpushed};
use crate::serve::start_name;
use crate::ssh::{ensure_up, shq, ssh_ok};
use crate::{DIM, RED, RESET};

/// `atlas test [flags] [-- <args>]` — run the project's tests on atlas.
pub(crate) fn test(argv: &[String]) {
    let flags = take_build_flags(argv);
    reject_local_with_branch(&flags, argv);
    let (branch, extra) = take_branch(&flags.rest);
    let cfg = load_config_at(flags.path.as_deref(), flags.target.as_deref());
    // Prefix `set -- <args>` so the detected/`test =` command's `"$@"` picks up
    // anything after `--`.
    let args = command_from_extra(&extra);
    let command = format!("set -- {args}; {}", cfg.test_cmd());
    remote_exec(&cfg, &flags, &branch, &command, true, "test");
}

/// `atlas exec [flags] -- <cmd>` — fresh-sync, then run any command in the root.
pub(crate) fn exec(argv: &[String]) {
    let flags = take_build_flags(argv);
    reject_local_with_branch(&flags, argv);
    let (branch, extra) = take_branch(&flags.rest);
    let command = command_from_extra(&extra);
    if command.is_empty() {
        eprintln!("{RED}atlas exec needs a command{RESET}  (after '--')");
        eprintln!("{DIM}  e.g. atlas exec --path web -- npm run typecheck{RESET}");
        exit(1);
    }
    let cfg = load_config_at(flags.path.as_deref(), flags.target.as_deref());
    remote_exec(&cfg, &flags, &branch, &command, true, "exec");
}

/// `atlas run [flags] -- <cmd>` — run a built artifact against the tree that
/// `atlas build` left, without touching it.
pub(crate) fn run(argv: &[String]) {
    let flags = take_build_flags(argv);
    reject_local_with_branch(&flags, argv);
    let (branch, extra) = take_branch(&flags.rest);
    let command = command_from_extra(&extra);
    if command.is_empty() {
        eprintln!("{RED}atlas run needs a command{RESET}  (after '--')");
        eprintln!(
            "{DIM}  e.g. atlas run --path security/tests/rt-harness -- ./target/release/attack-money --help{RESET}"
        );
        exit(1);
    }
    let cfg = load_config_at(flags.path.as_deref(), flags.target.as_deref());
    remote_exec(&cfg, &flags, &branch, &command, false, "run");
}

/// The shared body of test/exec/run: resolve the tree, optionally sync it fresh,
/// run `command` in the container and stream it, and exit with the command's
/// own code.
fn remote_exec(
    cfg: &BuildCfg,
    flags: &BuildFlags,
    branch: &str,
    command: &str,
    sync: bool,
    verb: &str,
) -> ! {
    ensure_up();
    let spec = cfg.spec(false);
    ensure_image(&spec);
    warn_if_secrets_unpushed(cfg);

    let slug = if flags.local {
        "local".to_string()
    } else {
        slug_of(branch)
    };
    let (src_dir, mount_repo) = if flags.local {
        (cfg.local_dir(), false)
    } else {
        (cfg.wt_dir(&slug), true)
    };

    if sync {
        if flags.local {
            println!("{DIM}  --local: no .git synced{RESET}");
            let top = git_toplevel(&cfg.root);
            sync_local(cfg, &top);
        } else {
            sync_worktree(cfg, branch, &slug);
        }
    } else if !ssh_ok(&format!("[ -d \"$HOME/{src_dir}\" ]")) {
        let what = if flags.local {
            "--local".to_string()
        } else {
            format!("-b {branch}")
        };
        eprintln!("{RED}nothing built{RESET} ({what}) — build first:  atlas build {what}");
        exit(1);
    }

    // Only a fresh sync of a branch tree can pull the rug out from a running app.
    let running = start_name(cfg, &slug);
    let was_running = sync
        && !flags.local
        && ssh_ok(&format!(
            "docker ps -q --filter name=^{running}$ | grep -q ."
        ));
    if was_running {
        println!("{DIM}  {running} stopped for {verb}{RESET}");
        ssh_ok(&format!("docker stop {running} >/dev/null"));
    }

    println!("{DIM}{verb} on atlas ({}):{RESET} {command}", spec.tag);
    let code = container_exec(cfg, &spec, &src_dir, mount_repo, command);

    if was_running {
        if ssh_ok(&format!("docker start {running} >/dev/null")) {
            println!("{DIM}  {running} restarted{RESET}");
        } else {
            eprintln!("{RED}  {running} could not be restarted{RESET} — atlas start");
        }
    }
    exit(code);
}

/// docker-run `command` in the build image against `src_dir`, streaming, and
/// return its exit code. Mirrors build's container invocation but adds
/// `--network host` so the command runs from atlas' real network position.
fn container_exec(
    cfg: &BuildCfg,
    spec: &ImageSpec,
    src_dir: &str,
    mount_repo: bool,
    command: &str,
) -> i32 {
    let repo_mount = if mount_repo {
        format!("-v \"$HOME/{r}\":\"$HOME/{r}\" ", r = cfg.repo_dir())
    } else {
        String::new()
    };
    let remote = format!(
        "{prologue}docker run --rm --network host $envf \
         -e CARGO_HOME=/cache/cargo -e npm_config_cache=/cache/npm \
         -e PUB_CACHE=/cache/pub -e XDG_CACHE_HOME=/cache/xdg \
         -e GRADLE_USER_HOME=/cache/gradle \
         -v \"$HOME/{src}\":/build -v \"$HOME/{cache}\":/cache \
         {repo_mount}\
         -w {wd} {tag} sh -c {cmd}; rc=$?; \
         sudo chown -R $(id -u):$(id -g) \"$HOME/{src}\" >/dev/null 2>&1; exit $rc",
        prologue = env_file_prologue(cfg),
        src = src_dir,
        cache = cfg.cache_dir(),
        wd = cfg.workdir(),
        tag = spec.tag,
        cmd = shq(command),
    );
    Command::new("ssh")
        .args([ssh_host(), &remote])
        .status()
        .ok()
        .and_then(|s| s.code())
        .unwrap_or(1)
}
