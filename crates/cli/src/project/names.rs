//! Names and paths: validators for what reaches a shell or a docker tag,
//! branch slugs, host labels, and the repository's canonical URL.

use std::path::Path;
use std::process::{Command, exit};

use super::BuildCfg;
use crate::{DIM, RED, RESET};

/// The path from the repo root to `dir`, via git (`--show-prefix`).
pub(crate) fn repo_subdir(dir: &Path) -> String {
    let out = Command::new("git")
        .args([
            "-C".as_ref(),
            dir.as_os_str(),
            "rev-parse".as_ref(),
            "--show-prefix".as_ref(),
        ])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    if out.is_empty() {
        eprintln!("{RED}--path needs a git repo{RESET} (in {})", dir.display());
        exit(1);
    }
    out.trim_end_matches('/').to_string()
}

/// Join a repo-relative prefix with a config's own `dir`.
pub(crate) fn join_dir(prefix: &str, dir: &str) -> String {
    let dir = if dir == "." { "" } else { dir };
    match (prefix.is_empty(), dir.is_empty()) {
        (true, true) => ".".into(),
        (false, true) => prefix.to_string(),
        (true, false) => dir.to_string(),
        (false, false) => format!("{prefix}/{dir}"),
    }
}

/// `name`/`image` become docker tags, container names and remote dir names
/// inside ssh commands — allow only a conservative charset.
pub(crate) fn valid_name(s: &str) -> bool {
    !s.is_empty()
        && s.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// Relative path used in remote shell commands and as a local rsync
/// `--delete` target: no absolute paths, no `..`, no leading `-`.
pub(crate) fn valid_rel_path(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with(['/', '-'])
        && s.split('/').all(|p| {
            !p.is_empty()
                && p != "."
                && p != ".."
                && p.chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        })
}

/// The `health` path reaches a remote curl URL: must be `/`-anchored, carry no
/// whitespace, and no shell metacharacters.
pub(crate) fn valid_health(s: &str) -> bool {
    s.starts_with('/')
        && !s.chars().any(char::is_whitespace)
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '.' | '_' | '-' | '~'))
}

/// A branch name reaches a remote shell, the filesystem (as a slug) and a
/// docker container name. `__` is rejected because the slug maps '/' onto it.
pub(crate) fn valid_branch(b: &str) -> bool {
    !b.is_empty()
        && b.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
        && !b.contains("..")
        && !b.contains("__")
        && !b.contains("//")
        && !b.ends_with('/')
        && b.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '/'))
}

/// Branch → one path/container component. Bijective, because valid_branch
/// rejects `__`.
pub(crate) fn slug_of(branch: &str) -> String {
    branch.replace('/', "__")
}

pub(crate) fn branch_of_slug(slug: &str) -> String {
    slug.replace("__", "/")
}

/// Flatten a branch into a DNS host label: lowercase, every run of non
/// `[a-z0-9]` chars becomes a single '-', trimmed at the ends.
pub(crate) fn dns_branch(branch: &str) -> String {
    let mut out = String::new();
    let mut prev_dash = false;
    for c in branch.to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
            prev_dash = false;
        } else if !prev_dash {
            out.push('-');
            prev_dash = true;
        }
    }
    out.trim_matches('-').to_string()
}

/// The public host label for a project/branch: `<name>` for main, else
/// `<name>-<dns-branch>`. The full public host is this + `.` + the configured
/// ATLAS_DEV_DOMAIN.
pub(crate) fn host_label(cfg: &BuildCfg, slug: &str) -> String {
    let branch = branch_of_slug(slug);
    if branch == "main" {
        cfg.name.clone()
    } else {
        format!("{}-{}", cfg.name, dns_branch(&branch))
    }
}

/// A DNS host label must match ^[a-z0-9-]{1,63}$ and the full host stay ≤253.
pub(crate) fn valid_host_label(label: &str) -> bool {
    !label.is_empty()
        && label.len() <= 63
        && label
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// The git URL atlas clones from: an explicit `repo = ...`, otherwise the
/// origin of the local checkout, normalized to https.
pub(crate) fn repo_url(cfg: &BuildCfg) -> String {
    let raw = if cfg.repo.is_empty() {
        let out = Command::new("git")
            .args([
                "-C".as_ref(),
                cfg.root.as_os_str(),
                "remote".as_ref(),
                "get-url".as_ref(),
                "origin".as_ref(),
            ])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();
        if out.is_empty() {
            eprintln!(
                "{RED}no git remote 'origin'{RESET} in {}",
                cfg.root.display()
            );
            eprintln!(
                "{DIM}  atlas builds from GitHub, not from the Mac — push the repo, or set \
                 repo = \"https://...\" in atlas.toml{RESET}"
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
            eprintln!("{RED}unusable repo URL:{RESET} {raw}");
            eprintln!(
                "{DIM}  allowed: https://host/owner/repo.git or git@host:owner/repo.git{RESET}"
            );
            exit(1);
        }
    }
}

/// Rewrite an SSH remote to https and reject anything that is not a plain URL.
pub(crate) fn normalize_git_url(raw: &str) -> Option<String> {
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
        .all(|c| {
            c.is_ascii_alphanumeric()
                || matches!(c, '.' | '_' | '-' | '/' | ':' | '@' | '~' | '+' | '%')
        })
        .then_some(url)
}
