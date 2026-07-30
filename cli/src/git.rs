//! git on atlas: the tree comes from GitHub, never from the Mac. Also the
//! one-time adoption of un-hashed warm build dirs and the `meta.json` manifest.

use std::path::{Path, PathBuf};
use std::process::{Command, exit};

use crate::config::ssh_host;
use crate::project::BuildCfg;
use crate::ssh::{run_inherit, shq, ssh_capture, ssh_ok};
use crate::state::short;
use crate::{DIM, RED, RESET};

/// The git working tree root for `--local`.
pub(crate) fn git_toplevel(root: &Path) -> PathBuf {
    let out = Command::new("git")
        .args([
            "-C".as_ref(),
            root.as_os_str(),
            "rev-parse".as_ref(),
            "--show-toplevel".as_ref(),
        ])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    if out.is_empty() {
        eprintln!(
            "{RED}--local needs a local git repo{RESET} (in {})",
            root.display()
        );
        exit(1);
    }
    PathBuf::from(out)
}

/// One-time adoption: if an un-hashed `~/atlas-builds/<name>` tree exists and
/// the `<name>-<hash8>` tree does not, move it over. Guarded (`! -e`), so it is
/// idempotent and never overwrites or merges. When two repos share a name,
/// whichever runs first adopts the shared un-hashed dir; the other builds
/// cleanly into its own hash dir, so same-name projects cannot collide.
fn adopt_legacy(cfg: &BuildCfg) {
    let legacy = cfg.legacy_base_dir();
    let new = cfg.base_dir();
    let out = ssh_capture(&format!(
        "legacy=\"$HOME/{legacy}\"; new=\"$HOME/{new}\"; \
         if [ ! -e \"$new\" ] && [ -d \"$legacy\" ]; then mv \"$legacy\" \"$new\" && echo adopted; fi"
    ));
    if out.trim() == "adopted" {
        println!(
            "{DIM}adopted warm build dir ~/{legacy} -> {}{RESET}",
            cfg.slug_id()
        );
    }
}

/// Write the identity manifest atomically (temp+mv). It is the source `atlas
/// ls` reads to map a hash dir back to its name/image (a name may contain '-',
/// so the dir name alone is ambiguous).
fn write_meta(cfg: &BuildCfg) {
    let json = format!(
        "{{\"name\":\"{}\",\"repo\":\"{}\",\"hash\":\"{}\",\"image\":\"{}\",\"dir\":\"{}\"}}",
        cfg.name, cfg.canonical_url, cfg.repo_hash, cfg.image, cfg.dir,
    );
    let f = cfg.meta_file();
    ssh_ok(&format!(
        "printf '%s\\n' {j} > \"$HOME/{f}.tmp\" && mv \"$HOME/{f}.tmp\" \"$HOME/{f}\"",
        j = shq(&json),
    ));
}

/// rsync the local working tree (uncommitted edits and all) up to a scratch
/// dir. Same 0700 hardening as the worktree path; the same excludes keep the
/// warm output dirs off the wire.
pub(crate) fn sync_local(cfg: &BuildCfg, toplevel: &Path) {
    adopt_legacy(cfg);
    let base = cfg.base_dir();
    let dest = cfg.local_dir();
    let setup = format!(
        "mkdir -p \"$HOME/{dest}\" \"$HOME/{cache}\" && \
         chmod 700 \"$HOME/{base}\"",
        cache = cfg.cache_dir(),
    );
    if !run_inherit(Command::new("ssh").args([ssh_host(), &setup])) {
        eprintln!("{RED}preparation on atlas failed{RESET}");
        exit(1);
    }
    println!("{DIM}sync (local working tree) -> atlas{RESET}");
    let ok = run_inherit(Command::new("rsync").args([
        "-az",
        "--delete",
        "--chmod=Dgo=,Fgo=",
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
        &format!("{}/", toplevel.display()),
        &format!("{}:{}/", ssh_host(), dest),
    ]));
    if !ok {
        eprintln!("{RED}rsync -> atlas failed{RESET}");
        exit(1);
    }
    // --chmod only reaches files rsync transferred; catch up the rest, scoped to
    // files we own so a prior root-owned build output does not abort it.
    ssh_ok(&format!(
        "d=\"$HOME/{dest}\"; chmod 700 \"$d\"; \
         find \"$d\" -user \"$(id -un)\" \\( -type d -o -type f \\) \
         -exec chmod go= {{}} + 2>/dev/null; true",
    ));
    write_meta(cfg);
}

pub(crate) fn sync_worktree(cfg: &BuildCfg, branch: &str, slug: &str) -> String {
    adopt_legacy(cfg);
    let url = &cfg.canonical_url;
    let base = cfg.base_dir();
    let repo = cfg.repo_dir();
    let wt = cfg.wt_dir(slug);

    // Clone (or repair an interrupted clone), then fetch. `--no-checkout`
    // because .repo only ever holds the object store.
    let setup = format!(
        "set -e; mkdir -p \"$HOME/{base}\" \"$HOME/{cache}\"; \
         chmod 700 \"$HOME/{REMOTE_BASE}\" \"$HOME/{base}\"; \
         r=\"$HOME/{repo}\"; \
         if [ -d \"$r\" ] && ! git -C \"$r\" rev-parse --git-dir >/dev/null 2>&1; then rm -rf \"$r\"; fi; \
         if [ ! -d \"$r\" ]; then git clone --quiet --no-checkout {url} \"$r\"; fi; \
         git -C \"$r\" remote set-url origin {url}; \
         git -C \"$r\" fetch --prune --quiet origin",
        REMOTE_BASE = crate::project::REMOTE_BASE,
        cache = cfg.cache_dir(),
        url = shq(url),
    );
    println!("{DIM}git fetch on atlas ({url}){RESET}");
    if !run_inherit(Command::new("ssh").args([ssh_host(), &setup])) {
        eprintln!("{RED}git fetch on atlas failed{RESET}");
        eprintln!(
            "{DIM}  private repos need ~/.git-credentials on atlas (https, not git@…){RESET}"
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
        eprintln!("{RED}branch '{branch}' does not exist on the remote{RESET}");
        let list = ssh_capture(&format!(
            "git -C \"$HOME/{repo}\" for-each-ref --format='%(refname:strip=3)' \
             refs/remotes/origin | grep -v '^HEAD$' | head -20"
        ));
        let list: Vec<&str> = list.split_whitespace().collect();
        if !list.is_empty() {
            eprintln!("{DIM}  available: {}{RESET}", list.join(", "));
        }
        exit(1);
    }

    // Create or update the worktree, healing anything a killed run left behind.
    // Detached HEAD, not a local branch: two worktrees may not check out the
    // same branch, and we only ever want exactly what origin/<branch> points at.
    // `clean -ffd` without -x on purpose — ignored files (node_modules, caches,
    // build output) are what keep the next run warm.
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
    if !run_inherit(Command::new("ssh").args([ssh_host(), &update])) {
        eprintln!("{RED}could not update the worktree for '{branch}'{RESET}");
        eprintln!(
            "{DIM}  escape hatch:  ssh {} 'rm -rf ~/{wt}'  and retry{RESET}",
            ssh_host()
        );
        exit(1);
    }
    println!("{DIM}  {branch} @ {}{RESET}", short(&commit));
    write_meta(cfg);
    commit
}

/// The current tip of <branch> on the remote, or None when it cannot be asked.
pub(crate) fn remote_tip(cfg: &BuildCfg, branch: &str) -> Option<String> {
    let out = ssh_capture(&format!(
        "git -C \"$HOME/{repo}\" ls-remote --heads origin {b} 2>/dev/null | head -1 | cut -f1",
        repo = cfg.repo_dir(),
        b = shq(branch),
    ));
    let sha = out.trim().to_string();
    (sha.len() >= 7 && sha.chars().all(|c| c.is_ascii_hexdigit())).then_some(sha)
}
