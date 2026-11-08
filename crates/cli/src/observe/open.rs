//! `atlas open`.

use std::process::{Command, exit};

use crate::build::take_branch;
use crate::project::{BuildCfg, load_config, slug_of};
use crate::serve::serve_url;
use crate::{DIM, RED, RESET};

pub(crate) fn open(argv: &[String]) {
    let (branch, _rest) = take_branch(argv);
    let slug = slug_of(&branch);
    let cfg = load_config();
    let Some(url) = resolve_url(&cfg, &slug) else {
        eprintln!("{RED}nothing running for {} @ {branch}{RESET}", cfg.name);
        exit(1);
    };
    println!("{DIM}{url}{RESET}");
    Command::new("open").arg(&url).status().ok();
}

/// The dev URL if any, else the started-build tailnet URL.
pub(super) fn resolve_url(cfg: &BuildCfg, slug: &str) -> Option<String> {
    crate::dev::dev_url(cfg, slug).or_else(|| serve_url(cfg, slug, "start"))
}
