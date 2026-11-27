//! Standalone API & S3 CLI subcommands (`auth`, `buckets`, `files`/`s3`,
//! `photos`, `keys`, `accounts`, `openapi`).

pub mod auth;
pub mod buckets;
pub mod files;
pub mod iam;
pub mod openapi;
pub mod photos;

use std::future::Future;
use std::process::exit;

use anyhow::Result;

use crate::{RED, RESET};

/// Runs an async CLI subcommand on a Tokio runtime and exits non-zero on error.
pub fn run_async<F>(fut: F)
where
    F: Future<Output = Result<()>>,
{
    let rt = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("{RED}error:{RESET} failed to start async runtime: {e}");
            exit(1);
        }
    };
    if let Err(e) = rt.block_on(fut) {
        let msg = crate::sanitize::sanitize_multiline(&format!("{e:#}"));
        eprintln!("{RED}error:{RESET} {msg}");
        exit(1);
    }
}

/// Prepends the command name so `clap::Parser::parse_from` formats help/usage
/// as `atlas <subcommand> ...`.
pub fn argv_with_name(name: &str, args: &[String]) -> Vec<String> {
    let mut full = Vec::with_capacity(args.len() + 1);
    full.push(format!("atlas {name}"));
    full.extend(args.iter().cloned());
    full
}
