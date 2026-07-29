//! Per-branch build state (`state/<slug>.json`) and reading the `meta.json`
//! identity manifest.

use crate::project::{BuildCfg, branch_of_slug};
use crate::ssh::{shq, ssh_capture, ssh_ok};

/// First seven characters of a commit sha (never panics on a corrupt state).
pub(crate) fn short(sha: &str) -> &str {
    sha.get(..7).unwrap_or(sha)
}

/// Write the per-branch build record. Only ever called after a build exited 0.
/// Written to a temp file and moved into place so a killed run cannot leave
/// truncated JSON behind.
pub(crate) fn write_state(cfg: &BuildCfg, branch: &str, slug: &str, commit: &str, secs: u64) {
    let arts = cfg
        .artifacts
        .iter()
        .map(|a| format!("\"{a}\""))
        .collect::<Vec<_>>()
        .join(",");
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
/// the file is unreadable, or the field is missing.
pub(crate) fn state_field(cfg: &BuildCfg, slug: &str, key: &str) -> String {
    ssh_capture(&format!(
        "sed -n 's/.*\"{key}\":\"\\([^\"]*\\)\".*/\\1/p' \"$HOME/{f}\" 2>/dev/null | head -1",
        f = cfg.state_file(slug),
    ))
    .trim()
    .to_string()
}

/// Branches that currently have a successful build on atlas.
pub(crate) fn built_branches(cfg: &BuildCfg) -> Vec<String> {
    let out = ssh_capture(&format!(
        "ls \"$HOME/{}/state\" 2>/dev/null | sed 's/\\.json$//'",
        cfg.base_dir()
    ));
    out.split_whitespace().map(branch_of_slug).collect()
}
