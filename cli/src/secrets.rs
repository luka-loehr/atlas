//! `atlas secrets push/list/rm` and the env-file injection prologue.
//!
//! Secrets are kept out of the build tree (which gets reset every run): a 0600
//! file in a 0700 dir, handed to the container as environment variables at run
//! time. The file is streamed over ssh stdin so its contents never land in an
//! argv (world-readable in /proc). `secrets list` never prints contents.

use std::fs;
use std::process::{Command, exit};

use crate::config::ssh_host;
use crate::project::{BuildCfg, SECRETS_BASE, load_config};
use crate::ssh::{ensure_up, ssh_capture, ssh_ok};
use crate::{DIM, GREEN, RED, RESET};

pub(crate) fn secrets(sub: &[String]) {
    match sub.first().map(String::as_str) {
        Some("push") | Some("set") => secrets_push(sub.get(1).map(String::as_str)),
        Some("list") | Some("ls") => secrets_list(),
        Some("rm") | Some("remove") => secrets_rm(),
        _ => {
            println!(
                "atlas secrets push [file]  file (default: .env.local, else .env) to atlas, 0600\n\
                 atlas secrets list          which projects have one (never the contents)\n\
                 atlas secrets rm            drop this project's"
            );
        }
    }
}

/// Upload an env file for the current project, streamed over ssh stdin.
fn secrets_push(arg: Option<&str>) {
    let cfg = load_config();
    let local = match arg {
        Some(p) => cfg.root.join(p),
        None => {
            match [".env.local", ".env"]
                .iter()
                .map(|f| cfg.root.join(f))
                .find(|p| p.is_file())
            {
                Some(p) => p,
                None => {
                    eprintln!("{RED}no .env.local or .env found{RESET} (or pass a path)");
                    exit(1);
                }
            }
        }
    };
    let Ok(handle) = fs::File::open(&local) else {
        eprintln!("{RED}cannot read {}{RESET}", local.display());
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
        eprintln!("{RED}secrets push failed{RESET}");
        exit(1);
    }
    println!(
        "{GREEN}✓ {} → atlas:~/{}{RESET} {DIM}(0600){RESET}",
        local.display(),
        target
    );
    println!("{DIM}  injected as environment variables on every atlas build/dev{RESET}");
}

fn secrets_list() {
    ensure_up();
    let out = ssh_capture(&format!(
        "cd \"$HOME/{SECRETS_BASE}\" 2>/dev/null && stat -c '%n  %s B  %y' *.env 2>/dev/null | cut -c1-60"
    ));
    if out.trim().is_empty() {
        println!("{DIM}no secrets stored{RESET}");
        return;
    }
    print!("{out}");
}

/// Remove both the hashed and the un-hashed (`<name>.env`) secrets file for
/// this project.
fn secrets_rm() {
    let cfg = load_config();
    ensure_up();
    let hashed = cfg.secrets_file();
    let legacy = cfg.legacy_secrets_file();
    if !ssh_ok(&format!("rm -f \"$HOME/{hashed}\" \"$HOME/{legacy}\"")) {
        eprintln!("{RED}secrets rm failed{RESET}");
        exit(1);
    }
    println!("{GREEN}✓ secrets for {} removed{RESET}", cfg.name);
}

/// Shell prologue that sets $envf to a `--env-file` flag when this project has a
/// secrets file. Prefers the hashed path; an un-hashed `<name>.env` in the store
/// is read as a fallback until a `secrets push` writes the hashed file.
pub(crate) fn env_file_prologue(cfg: &BuildCfg) -> String {
    format!(
        "sec=\"$HOME/{hashed}\"; [ -f \"$sec\" ] || sec=\"$HOME/{legacy}\"; \
         envf=\"\"; [ -f \"$sec\" ] && envf=\"--env-file $sec\"; ",
        hashed = cfg.secrets_file(),
        legacy = cfg.legacy_secrets_file(),
    )
}

/// Warn when the project has a local env file but nothing in the store.
pub(crate) fn warn_if_secrets_unpushed(cfg: &BuildCfg) {
    let has_local = [".env.local", ".env"]
        .iter()
        .any(|f| cfg.root.join(f).is_file());
    if !has_local {
        return;
    }
    if ssh_ok(&format!(
        "[ -f \"$HOME/{}\" ] || [ -f \"$HOME/{}\" ]",
        cfg.secrets_file(),
        cfg.legacy_secrets_file()
    )) {
        return;
    }
    println!(
        "{DIM}note: .env exists locally but not on atlas — env files are not in git and so do \
         not travel with the branch.\n  atlas secrets push{RESET}"
    );
}
