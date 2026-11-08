//! Per-project config: `atlas.toml` (the only filename the CLI reads — `atlas
//! migrate` converts a `.atlas-build.toml`),
//! the `BuildCfg` model, path/name validators, and the remote-path scheme.

use std::path::PathBuf;
use std::process::{Command, exit};

use crate::config::ssh_host;
use crate::ssh::{run_inherit, ssh_ok};
use crate::{DIM, RED, RESET};

mod load;
mod names;

pub(crate) use load::{load_config, load_config_at};
pub(crate) use names::{
    branch_of_slug, dns_branch, host_label, slug_of, valid_branch, valid_host_label,
};

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
    /// The un-hashed dir (`~/atlas-builds/<name>`), for one-time adoption.
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
    /// The un-hashed secrets path (`<name>.env`), read as a fallback when the
    /// hashed file is absent.
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
