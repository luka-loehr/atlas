//! `atlas watch`.

use std::path::Path;
use std::process::Command;
use std::thread::sleep;
use std::time::{Duration, Instant, UNIX_EPOCH};

use crate::build::take_build_flags;
use crate::git::{EXCLUDES, git_toplevel};
use crate::project::load_config_at;
use crate::{DIM, RESET};

pub(crate) fn watch(argv: &[String]) {
    let flags = take_build_flags(argv);
    let cfg = load_config_at(flags.path.as_deref(), flags.target.as_deref());
    let top = git_toplevel(&cfg.root);

    // Build the child command once: `atlas build --local [--path D] [--target T]`.
    let exe = std::env::current_exe().unwrap_or_else(|_| "atlas".into());
    let mut child_args: Vec<String> = vec!["build".into(), "--local".into()];
    if let Some(p) = &flags.path {
        child_args.push("--path".into());
        child_args.push(p.clone());
    }
    if let Some(t) = &flags.target {
        child_args.push("--target".into());
        child_args.push(t.clone());
    }

    println!(
        "{DIM}watching {} (build --local on change) — Ctrl-C to stop{RESET}",
        top.display()
    );

    let mut last_seen = max_mtime(&top);
    let mut dirty = false;
    let mut last_change = Instant::now();
    loop {
        sleep(Duration::from_millis(400));
        let m = max_mtime(&top);
        if m > last_seen {
            last_seen = m;
            dirty = true;
            last_change = Instant::now();
        }
        if dirty && last_change.elapsed() >= Duration::from_millis(800) {
            dirty = false;
            println!("{DIM}change detected -> build --local{RESET}");
            // Spawn a child so a failing build (which exits non-zero) does not
            // kill the watcher; the normal build output streams through.
            Command::new(&exe).args(&child_args).status().ok();
        }
    }
}

/// Maximum mtime (ms since epoch) of any non-excluded file under `dir`.
fn max_mtime(dir: &Path) -> u64 {
    let mut max = 0u64;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in entries.flatten() {
            let name = e.file_name();
            let name = name.to_string_lossy();
            if EXCLUDES.contains(&name.as_ref()) {
                continue;
            }
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() {
                stack.push(e.path());
            } else if let Ok(md) = e.metadata()
                && let Ok(mt) = md.modified()
                && let Ok(dur) = mt.duration_since(UNIX_EPOCH)
            {
                let ms = dur.as_millis() as u64;
                if ms > max {
                    max = ms;
                }
            }
        }
    }
    max
}
