//! `atlas build` plus the shared flag parsing (branch/local/path/target) that
//! test/exec/run also use.

use std::process::{Command, exit};
use std::time::Instant;

use crate::config::ssh_host;
use crate::git::{git_toplevel, sync_local, sync_worktree};
use crate::project::{ensure_image, load_config_at, slug_of, valid_branch};
use crate::secrets::{env_file_prologue, warn_if_secrets_unpushed};
use crate::serve::start_name;
use crate::ssh::{ensure_up, run_inherit, shq, ssh_capture, ssh_ok};
use crate::state::{short, write_state};
use crate::{DIM, GREEN, RED, RESET};

/// What `atlas build` was asked to build, before the branch is resolved.
pub(crate) struct BuildFlags {
    pub(crate) local: bool, // --local / -l: the working tree, not a pushed ref
    pub(crate) path: Option<String>, // --path <subdir>: a subdir target (its own config)
    pub(crate) target: Option<String>, // --target <name>: a [target.NAME] in one config
    pub(crate) rest: Vec<String>, // everything else, for take_branch + the command
}

/// Pull `--local`/`-l`, `--path <p>`/`-p <p>` and `--target <t>`/`-t <t>` out of
/// the args, leaving `--branch` and the pass-through command for take_branch.
/// Stops at a literal `--` so those flags reach the build command untouched.
pub(crate) fn take_build_flags(argv: &[String]) -> BuildFlags {
    let mut local = false;
    let mut path: Option<String> = None;
    let mut target: Option<String> = None;
    let mut rest: Vec<String> = Vec::new();
    let mut i = 0;
    let need = |a: &str, argv: &[String], i: &mut usize| -> String {
        let Some(v) = argv.get(*i + 1) else {
            eprintln!("{RED}{a} needs an argument{RESET}");
            exit(1);
        };
        *i += 1;
        v.clone()
    };
    while i < argv.len() {
        let a = argv[i].as_str();
        if a == "--" {
            rest.extend_from_slice(&argv[i..]);
            break;
        }
        if a == "--local" || a == "-l" {
            local = true;
        } else if let Some(v) = a.strip_prefix("--path=").or_else(|| a.strip_prefix("-p=")) {
            path = Some(v.to_string());
        } else if a == "--path" || a == "-p" {
            path = Some(need(a, argv, &mut i));
        } else if let Some(v) = a
            .strip_prefix("--target=")
            .or_else(|| a.strip_prefix("-t="))
        {
            target = Some(v.to_string());
        } else if a == "--target" || a == "-t" {
            target = Some(need(a, argv, &mut i));
        } else {
            rest.push(argv[i].clone());
        }
        i += 1;
    }
    if path.is_some() && target.is_some() {
        eprintln!("{RED}--path and --target are mutually exclusive{RESET}");
        eprintln!(
            "{DIM}  --path D: its own target in a subdir; --target T: a named target in the root config{RESET}"
        );
        exit(1);
    }
    BuildFlags {
        local,
        path,
        target,
        rest,
    }
}

/// True if the args carry an explicit `--branch`/`-b` (before any `--`).
pub(crate) fn has_branch_flag(argv: &[String]) -> bool {
    argv.iter().take_while(|a| a.as_str() != "--").any(|a| {
        let a = a.as_str();
        a == "--branch" || a == "-b" || a.starts_with("--branch=") || a.starts_with("-b=")
    })
}

/// Pull `--branch B` / `-b B` / `--branch=B` out and return it with the rest of
/// the arguments (default "main"). Stops at a literal `--`.
pub(crate) fn take_branch(argv: &[String]) -> (String, Vec<String>) {
    let mut branch: Option<String> = None;
    let mut rest: Vec<String> = Vec::new();
    let mut i = 0;
    while i < argv.len() {
        let a = argv[i].as_str();
        if a == "--" {
            rest.extend_from_slice(&argv[i..]);
            break;
        }
        if let Some(v) = a
            .strip_prefix("--branch=")
            .or_else(|| a.strip_prefix("-b="))
        {
            branch = Some(v.to_string());
        } else if a == "--branch" || a == "-b" {
            let Some(v) = argv.get(i + 1) else {
                eprintln!("{RED}{a} needs a branch name{RESET}");
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
        eprintln!("{RED}invalid branch name '{branch}'{RESET}");
        eprintln!("{DIM}  allowed: A-Za-z0-9._-/ , alphanumeric start, no '..' and no '__'{RESET}");
        exit(1);
    }
    (branch, rest)
}

/// `--local` and `--branch` name two different sources for the tree; together
/// they contradict. Shared by build and test/exec/run.
pub(crate) fn reject_local_with_branch(flags: &BuildFlags, argv: &[String]) {
    if flags.local && has_branch_flag(argv) {
        eprintln!("{RED}--local and --branch are mutually exclusive{RESET}");
        eprintln!("{DIM}  --local uses the working tree, --branch a pushed ref{RESET}");
        exit(1);
    }
}

/// Everything after the first literal `--` (or the whole list when there is no
/// `--`), each token shell-quoted.
pub(crate) fn command_from_extra(extra: &[String]) -> String {
    let start = extra
        .iter()
        .position(|a| a == "--")
        .map(|i| i + 1)
        .unwrap_or(0);
    extra[start..]
        .iter()
        .map(|a| shq(a))
        .collect::<Vec<_>>()
        .join(" ")
}

pub(crate) fn build(argv: &[String]) {
    let flags = take_build_flags(argv);
    reject_local_with_branch(&flags, argv);
    let (branch, extra) = take_branch(&flags.rest);
    let cfg = load_config_at(flags.path.as_deref(), flags.target.as_deref());
    if cfg.build.is_empty() || cfg.artifacts.is_empty() {
        eprintln!("{RED}config has no build/artifacts{RESET}");
        exit(1);
    }
    ensure_up();
    let spec = cfg.spec(false);
    ensure_image(&spec);
    warn_if_secrets_unpushed(&cfg);

    // Resolve where /build comes from. `--local` rsyncs the working tree into
    // its own dir; otherwise a detached worktree at origin/<branch>.
    let (src_dir, slug, label, commit, mount_repo) = if flags.local {
        println!("{DIM}  --local: no .git synced — git version stamps stay empty{RESET}");
        let top = git_toplevel(&cfg.root);
        sync_local(&cfg, &top);
        (
            cfg.local_dir(),
            "local".to_string(),
            "local working tree".to_string(),
            String::new(),
            false,
        )
    } else {
        let slug = slug_of(&branch);
        let commit = sync_worktree(&cfg, &branch, &slug);
        let label = format!("{branch} @ {}", short(&commit));
        (cfg.wt_dir(&slug), slug, label, commit, true)
    };

    // Everything after a literal `--` is for the build command, not for us.
    let mut buildcmd = cfg.build.clone();
    for a in extra.iter().filter(|a| a.as_str() != "--") {
        buildcmd.push(' ');
        buildcmd.push_str(a);
    }
    // .repo is mounted at its own absolute path: a worktree's `.git` is a FILE
    // containing `gitdir: <abs path into .repo>`. A --local tree has no `.git`.
    let repo_mount = if mount_repo {
        format!("-v \"$HOME/{r}\":\"$HOME/{r}\" ", r = cfg.repo_dir())
    } else {
        String::new()
    };
    let remote = format!(
        "{prologue}docker run --rm $envf \
         -e CARGO_HOME=/cache/cargo -e npm_config_cache=/cache/npm \
         -e PUB_CACHE=/cache/pub -e XDG_CACHE_HOME=/cache/xdg \
         -e GRADLE_USER_HOME=/cache/gradle \
         -v \"$HOME/{src}\":/build -v \"$HOME/{cache}\":/cache \
         {repo_mount}\
         -w {wd} {tag} sh -c {cmd}; rc=$?; \
         sudo chown -R $(id -u):$(id -g) \"$HOME/{src}\" >/dev/null 2>&1; exit $rc",
        prologue = env_file_prologue(&cfg),
        src = src_dir,
        cache = cfg.cache_dir(),
        wd = cfg.workdir(),
        tag = spec.tag,
        cmd = shq(&buildcmd),
    );

    // A running app serves out of the same worktree a branch build rewrites, so
    // stop it first, start it again after. A --local build touches no running
    // app, so this whole dance is skipped there.
    let running = start_name(&cfg, &slug);
    let was_running = !flags.local
        && ssh_ok(&format!(
            "docker ps -q --filter name=^{running}$ | grep -q ."
        ));
    if was_running {
        println!("{DIM}  {running} stopped for the build{RESET}");
        ssh_ok(&format!("docker stop {running} >/dev/null"));
    }

    println!("{DIM}build on atlas ({}):{RESET} {buildcmd}", spec.tag);
    let t0 = Instant::now();
    let ok = run_inherit(Command::new("ssh").args([ssh_host(), &remote]));
    let secs = t0.elapsed().as_secs();
    if !ok {
        eprintln!("{RED}build failed{RESET} (after {secs}s)");
        if was_running {
            eprintln!("{DIM}  {running} left stopped (half-written .next){RESET}");
        }
        exit(1);
    }

    // The build said 0; make sure it produced what it claims.
    let missing = ssh_capture(&format!(
        "for a in {arts}; do [ -e \"$HOME/{src}/$a\" ] || echo \"$a\"; done",
        arts = cfg
            .artifacts
            .iter()
            .map(|a| shq(&cfg.artifact_rel(a)))
            .collect::<Vec<_>>()
            .join(" "),
        src = src_dir,
    ));
    let missing: Vec<&str> = missing.split_whitespace().collect();
    if !missing.is_empty() {
        eprintln!(
            "{RED}build reported success, but these are missing:{RESET} {}",
            missing.join(", ")
        );
        eprintln!("{DIM}  check artifacts in atlas.toml{RESET}");
        exit(1);
    }

    // Only a branch build is startable — a local tree has no ref to reproduce.
    if !flags.local {
        write_state(&cfg, &branch, &slug, &commit, secs);
    }
    println!(
        "{GREEN}✓ build done{RESET} in {}m {:02}s  {DIM}({label}, {}){RESET}",
        secs / 60,
        secs % 60,
        spec.tag
    );

    if flags.local {
        for a in &cfg.artifacts {
            println!(
                "{DIM}  lives on atlas (not copied): ~/{src_dir}/{}{RESET}",
                cfg.artifact_rel(a)
            );
        }
        println!("{DIM}  run it:  atlas run --local -- ./<path/to/binary>{RESET}");
    } else if was_running {
        if ssh_ok(&format!("docker start {running} >/dev/null")) {
            println!("{DIM}  {running} restarted on the fresh build{RESET}");
        } else {
            eprintln!("{RED}  {running} could not be restarted{RESET} — atlas start");
        }
    } else {
        println!(
            "{DIM}  start:  atlas start{}{RESET}",
            if branch == "main" {
                String::new()
            } else {
                format!(" -b {branch}")
            }
        );
    }
}
