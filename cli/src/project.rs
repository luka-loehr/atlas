//! Per-project config: `atlas.toml` (v2; the legacy `.atlas-build.toml` is no
//! longer read — see `atlas migrate`),
//! the `BuildCfg` model, path/name validators, and the remote-path scheme.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, exit};

use crate::config::ssh_host;
use crate::hash::repo_hash_of;
use crate::ssh::{run_inherit, ssh_ok};
use crate::{DIM, RED, RESET};

/// What atlas keeps per project, relative to atlas' $HOME:
///
///   atlas-builds/<name>-<hash8>/.repo/            clone (created --no-checkout)
///   atlas-builds/<name>-<hash8>/wt/<slug>/        one worktree per branch
///   atlas-builds/<name>-<hash8>/state/<slug>.json what `atlas build` produced
///   atlas-builds/<name>-<hash8>/meta.json         project identity manifest
///   atlas-builds/.cache-<image>/                  shared package caches
///
/// The Mac never pushes source here — GitHub is the meeting point and atlas
/// pulls. The tree is disposable: every run hard-resets it to origin/<branch>.
pub(crate) const REMOTE_BASE: &str = "atlas-builds";
/// Secrets live OUTSIDE the build tree (which gets reset every run): a 0600
/// file in a 0700 dir, injected as environment variables at run time.
pub(crate) const SECRETS_BASE: &str = "atlas-secrets";

pub(crate) struct BuildCfg {
    pub(crate) root: PathBuf,     // dir holding the config (the local checkout)
    pub(crate) name: String,      // project id
    pub(crate) repo_hash: String, // hash8 of the canonical origin URL
    pub(crate) canonical_url: String, // normalized clone URL (also stored in meta.json)
    pub(crate) image: String,     // builder key: universal | mobile
    pub(crate) dir: String,       // subdir (relative to the repo root) the build runs in
    pub(crate) build: String,     // build command (for `atlas build`)
    pub(crate) test: String,      // test command ("" = detect) for `atlas test`
    pub(crate) dev: String,       // dev-server command (for `atlas dev`)
    pub(crate) start: String,     // run-the-built-artifact command ("" = detect)
    pub(crate) install: String,   // dependency install for `atlas dev` ("" = detect)
    pub(crate) repo: String,      // git URL ("" = origin of the local checkout)
    pub(crate) port: u16,         // port the server binds on atlas
    pub(crate) artifacts: Vec<String>, // paths (relative to the repo root) the build produces
    pub(crate) health: String,    // HTTP path `atlas health` probes (default "/")
}

/// What `docker build` needs to produce one image, and what to run it as.
pub(crate) struct ImageSpec {
    pub(crate) tag: String,     // docker tag to run
    pub(crate) context: String, // build context, relative to the atlas checkout
    pub(crate) target: String,  // multi-stage target inside that context
}

impl ImageSpec {
    /// The `docker build` invocation that produces this image.
    pub(crate) fn build_cmd(&self) -> String {
        format!(
            "docker build --target {} -t {} {}",
            self.target, self.tag, self.context
        )
    }
}

/// Every builder key the config accepts, in the order they are shown to the
/// user. Both resolve to targets of the one universal Dockerfile.
pub(crate) const IMAGE_KEYS: [&str; 2] = ["universal", "mobile"];

/// Resolve a config `image` key into the image that should run it. `dev` picks
/// the variant with cloudflared in it (the build target has no tunnel binary).
pub(crate) fn image_spec(key: &str, dev: bool) -> ImageSpec {
    let target = if key == "mobile" {
        "mobile"
    } else if dev {
        "dev"
    } else {
        "build"
    };
    ImageSpec {
        tag: format!(
            "atlas-universal-{}",
            if target == "build" { "builder" } else { target }
        ),
        context: "builder/universal".into(),
        target: target.into(),
    }
}

impl BuildCfg {
    pub(crate) fn spec(&self, dev: bool) -> ImageSpec {
        image_spec(&self.image, dev)
    }

    /// How `atlas dev` installs dependencies before starting the dev server.
    /// `atlas-install` probes the lockfile rather than assuming npm; an explicit
    /// `install = ...` wins.
    pub(crate) fn install_cmd(&self) -> String {
        if !self.install.is_empty() {
            return self.install.clone();
        }
        "atlas-install".into()
    }

    /// How `atlas start` runs what the build produced.
    pub(crate) fn start_cmd(&self) -> String {
        if !self.start.is_empty() {
            return self.start.clone();
        }
        "if [ -f bun.lockb ] || [ -f bun.lock ]; then bun run start; \
         elif [ -f pnpm-lock.yaml ]; then pnpm start; \
         elif [ -f yarn.lock ]; then yarn start; \
         else npm run start; fi"
            .into()
    }

    /// The default command for `atlas test`, when no `test = ...` is set.
    pub(crate) fn test_cmd(&self) -> String {
        if !self.test.is_empty() {
            return format!("{} \"$@\"", self.test);
        }
        "if [ -f Cargo.toml ]; then cargo test \"$@\"; \
         elif [ -f bun.lockb ] || [ -f bun.lock ]; then bun test \"$@\"; \
         elif [ -f pnpm-lock.yaml ]; then pnpm test \"$@\"; \
         elif [ -f yarn.lock ]; then yarn test \"$@\"; \
         else npm test \"$@\"; fi"
            .into()
    }

    pub(crate) fn workdir(&self) -> String {
        if self.dir == "." {
            "/build".into()
        } else {
            format!("/build/{}", self.dir)
        }
    }

    /// `<name>-<hash8>` — the collision-free project id used for dirs and
    /// container names.
    pub(crate) fn slug_id(&self) -> String {
        format!("{}-{}", self.name, self.repo_hash)
    }

    /// All paths below are relative to atlas' $HOME and used inside
    /// double-quoted "$HOME/..." expansions; `name`, the hash and the branch
    /// slug are charset-validated, so they need no further quoting.
    pub(crate) fn base_dir(&self) -> String {
        format!("{REMOTE_BASE}/{}", self.slug_id())
    }
    /// The pre-hash legacy dir (`~/atlas-builds/<name>`), for one-time adoption.
    pub(crate) fn legacy_base_dir(&self) -> String {
        format!("{REMOTE_BASE}/{}", self.name)
    }
    pub(crate) fn repo_dir(&self) -> String {
        format!("{}/.repo", self.base_dir())
    }
    pub(crate) fn wt_dir(&self, slug: &str) -> String {
        format!("{}/wt/{slug}", self.base_dir())
    }
    pub(crate) fn local_dir(&self) -> String {
        format!("{}/local", self.base_dir())
    }
    pub(crate) fn meta_file(&self) -> String {
        format!("{}/meta.json", self.base_dir())
    }
    /// An artifact path relative to the mounted /build root.
    pub(crate) fn artifact_rel(&self, a: &str) -> String {
        if self.dir == "." {
            a.to_string()
        } else {
            format!("{}/{a}", self.dir)
        }
    }
    pub(crate) fn state_file(&self, slug: &str) -> String {
        format!("{}/state/{slug}.json", self.base_dir())
    }
    pub(crate) fn cache_dir(&self) -> String {
        format!("{REMOTE_BASE}/.cache-{}", self.image)
    }
    /// The hashed secrets path `secrets push` always writes.
    pub(crate) fn secrets_file(&self) -> String {
        format!("{SECRETS_BASE}/{}.env", self.slug_id())
    }
    /// The pre-hash secrets path, still read as a back-compat fallback.
    pub(crate) fn legacy_secrets_file(&self) -> String {
        format!("{SECRETS_BASE}/{}.env", self.name)
    }
}

/// Build the builder image on atlas if it is not there yet.
pub(crate) fn ensure_image(spec: &ImageSpec) {
    let tag = &spec.tag;
    if ssh_ok(&format!("docker image inspect {tag} >/dev/null 2>&1")) {
        return;
    }
    println!("{DIM}image {tag} is missing — building it on atlas (one-time, a few minutes){RESET}");
    let ok = run_inherit(Command::new("ssh").args([
        ssh_host(),
        &format!(
            "cd ~/atlas && git pull --quiet --ff-only && {}",
            spec.build_cmd()
        ),
    ]));
    if !ok {
        eprintln!("{RED}image build failed{RESET}");
        exit(1);
    }
}

/// Walk up from cwd to find the config and parse it.
pub(crate) fn load_config() -> BuildCfg {
    load_config_selected(None, None)
}

/// Load the config for `atlas build`, honoring `--path` and `--target`.
pub(crate) fn load_config_at(sub: Option<&str>, target: Option<&str>) -> BuildCfg {
    load_config_selected(sub, target)
}

/// Locate the `atlas.toml` config file. Returns (file, scoped).
///
/// The legacy `.atlas-build.toml` format is no longer read: everything has been
/// migrated and the new CLI is the only one in use. A stray legacy file can
/// still be converted one-off with `atlas migrate`, but it is not a fallback.
fn resolve_config_file(sub: Option<&str>, cwd: &Path) -> (PathBuf, bool) {
    match sub {
        Some(p) => {
            let d = cwd.join(p);
            if !d.is_dir() {
                eprintln!("{RED}--path: not a directory{RESET} ({p})");
                exit(1);
            }
            let a = d.join("atlas.toml");
            if a.is_file() {
                return (a, true);
            }
            eprintln!("{RED}--path {p}: no atlas.toml there{RESET}");
            eprintln!(
                "{DIM}  --path D expects D as its own build target with its own atlas.toml{RESET}"
            );
            exit(1);
        }
        None => {
            let mut dir = cwd.to_path_buf();
            loop {
                let a = dir.join("atlas.toml");
                if a.is_file() {
                    return (a, false);
                }
                if !dir.pop() {
                    eprintln!("{RED}no atlas.toml found{RESET} (here or in a parent directory)");
                    exit(1);
                }
            }
        }
    }
}

fn load_config_selected(sub: Option<&str>, target: Option<&str>) -> BuildCfg {
    let cwd = env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let (file, scoped) = resolve_config_file(sub, &cwd);
    let cfg_dir = file.parent().unwrap_or(Path::new(".")).to_path_buf();
    let text = fs::read_to_string(&file).unwrap_or_default();
    let (top, targets) = parse_sections(&text);

    // Resolve which key/value set applies: a chosen [target.T], or the flat top
    // level. A file with targets demands one be named; a --target against a flat
    // file is a mistake worth catching, not ignoring.
    let names: Vec<String> = targets.iter().map(|(n, _)| n.clone()).collect();
    let chosen: Vec<(String, String)> = if !targets.is_empty() {
        let want = match target {
            Some(t) => t,
            None => {
                eprintln!("{RED}this config has targets{RESET} — atlas build --target <name>");
                eprintln!("{DIM}  available: {}{RESET}", names.join(", "));
                exit(1);
            }
        };
        let Some((_, kvs)) = targets.iter().find(|(n, _)| n == want) else {
            eprintln!("{RED}no target '{want}'{RESET}");
            eprintln!("{DIM}  available: {}{RESET}", names.join(", "));
            exit(1);
        };
        top.iter().cloned().chain(kvs.iter().cloned()).collect()
    } else {
        if let Some(t) = target {
            eprintln!("{RED}--target {t}: this config has no targets{RESET}");
            exit(1);
        }
        top.clone()
    };

    let mut c = BuildCfg {
        root: cfg_dir.clone(),
        name: String::new(),
        repo_hash: String::new(),
        canonical_url: String::new(),
        image: String::new(),
        dir: ".".into(),
        build: String::new(),
        test: String::new(),
        dev: String::new(),
        start: String::new(),
        install: String::new(),
        repo: String::new(),
        port: 3000,
        artifacts: Vec::new(),
        health: "/".into(),
    };
    // Top level first (shared defaults), then the target's own keys win.
    let base_had_name = top.iter().any(|(k, _)| k == "name");
    for (k, v) in &chosen {
        apply_kv(&mut c, k, v);
    }
    // A target without its own name inherits "<repo>-<target>", so each gets a
    // distinct remote dir + cache instead of clobbering the shared one.
    if let Some(t) = target {
        let target_set_name = targets
            .iter()
            .find(|(n, _)| n == t)
            .map(|(_, kvs)| kvs.iter().any(|(k, _)| k == "name"))
            .unwrap_or(false);
        if !target_set_name && base_had_name {
            c.name = format!("{}-{t}", c.name);
        }
    }

    // `--path D` makes D the build root, expressed relative to the repo root.
    if scoped {
        let prefix = repo_subdir(&cfg_dir);
        c.dir = join_dir(&prefix, &c.dir);
    }

    if c.name.is_empty() || c.image.is_empty() {
        eprintln!("{RED}config incomplete{RESET} (name, image required)");
        exit(1);
    }
    if !valid_name(&c.name) {
        eprintln!("{RED}config: invalid name{RESET} (allowed: A-Za-z0-9._-)");
        exit(1);
    }
    if !IMAGE_KEYS.contains(&c.image.as_str()) {
        eprintln!(
            "{RED}config: unknown image '{}'{RESET} (allowed: {})",
            c.image,
            IMAGE_KEYS.join(" | ")
        );
        exit(1);
    }
    if c.dir != "." && !valid_rel_path(&c.dir) {
        eprintln!("{RED}config: invalid dir{RESET} (relative path without '..')");
        exit(1);
    }
    for a in &c.artifacts {
        if !valid_rel_path(a) {
            eprintln!("{RED}config: invalid artifact '{a}'{RESET} (relative path without '..')");
            exit(1);
        }
    }
    if !valid_health(&c.health) {
        eprintln!(
            "{RED}config: invalid health '{}'{RESET} (must start with '/', no whitespace)",
            c.health
        );
        exit(1);
    }

    // Resolve the canonical URL once and derive the deterministic project hash
    // from it. Every remote path is keyed on this, so it is computed here and
    // cached on the config instead of per-call.
    c.canonical_url = repo_url(&c);
    c.repo_hash = repo_hash_of(&c.canonical_url);
    c
}

/// Minimal TOML value handling: strips surrounding quotes and inline
/// `# comments` (the file is a flat key=value list, no full TOML needed).
pub(crate) fn parse_toml_value(raw: &str) -> String {
    let raw = raw.trim();
    for q in ['"', '\''] {
        if let Some(rest) = raw.strip_prefix(q)
            && let Some(end) = rest.find(q)
        {
            return rest[..end].to_string();
        }
    }
    let end = raw.find('#').unwrap_or(raw.len());
    raw[..end].trim().to_string()
}

/// A single `key = value` pair.
type Kv = (String, String);
/// The flat top-level keys and the ordered `[target.NAME]` sections of a config.
type Sections = (Vec<Kv>, Vec<(String, Vec<Kv>)>);

/// Split a config into its flat top-level keys and any `[target.NAME]` sections,
/// preserving order so later keys win.
pub(crate) fn parse_sections(text: &str) -> Sections {
    let mut top: Vec<Kv> = Vec::new();
    let mut targets: Vec<(String, Vec<Kv>)> = Vec::new();
    let mut cur: Option<usize> = None;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(inner) = line.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
            let Some(name) = inner.trim().strip_prefix("target.") else {
                eprintln!("{RED}config: only [target.NAME] is supported{RESET} ({line})");
                exit(1);
            };
            let name = name.trim().to_string();
            if !valid_name(&name) {
                eprintln!("{RED}config: invalid target name{RESET} ({name})");
                exit(1);
            }
            targets.push((name, Vec::new()));
            cur = Some(targets.len() - 1);
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let kv = (k.trim().to_string(), parse_toml_value(v));
        match cur {
            None => top.push(kv),
            Some(i) => targets[i].1.push(kv),
        }
    }
    (top, targets)
}

/// Apply one config key to the builder. Shared by the top-level pass and each
/// target section, so both understand exactly the same keys.
pub(crate) fn apply_kv(c: &mut BuildCfg, k: &str, v: &str) {
    let v = v.to_string();
    match k {
        "name" => c.name = v,
        "image" => c.image = v,
        "dir" => c.dir = v,
        "build" => c.build = v,
        "test" => c.test = v,
        "dev" => c.dev = v,
        "start" => c.start = v,
        "install" => c.install = v,
        "repo" => c.repo = v,
        "health" => c.health = v,
        "port" => {
            c.port = v.parse().unwrap_or_else(|_| {
                eprintln!("{RED}config: invalid port{RESET} ({v})");
                exit(1);
            })
        }
        "artifacts" => c.artifacts = v.split_whitespace().map(String::from).collect(),
        _ => {}
    }
}

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
/// `<name>-<dns-branch>`. The full public host is this + `.lukaloehr.com`.
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
