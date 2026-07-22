//! GitHub-style activity history: how many minutes atlas was awake on each
//! day (reconstructed from the persistent systemd journal's boot list — works
//! retroactively, no collection warm-up) plus commits/day in the monorepo.

use std::process::Command;

use crate::actions::extract_num;

const DAYS: i64 = 154; // 22 weeks of heatmap

fn run(cmd: &str, args: &[&str]) -> String {
    Command::new(cmd)
        .args(args)
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

/// Local-time offset in seconds (journal + git timestamps are UTC).
fn tz_offset_s() -> i64 {
    let z = run("date", &["+%z"]); // e.g. "+0200"
    let z = z.trim();
    if z.len() != 5 {
        return 0;
    }
    let sign = if z.starts_with('-') { -1 } else { 1 };
    let h: i64 = z[1..3].parse().unwrap_or(0);
    let m: i64 = z[3..5].parse().unwrap_or(0);
    sign * (h * 3600 + m * 60)
}

/// Civil date from days-since-epoch (Howard Hinnant's algorithm).
fn civil(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn date_str(day: i64) -> String {
    let (y, m, d) = civil(day);
    format!("{y:04}-{m:02}-{d:02}")
}

/// Boot intervals [first_entry, last_entry] in unix seconds.
fn boots() -> Vec<(i64, i64)> {
    let text = run("journalctl", &["--list-boots", "-o", "json"]);
    text.split('{')
        .skip(1)
        .filter_map(|chunk| {
            let first = extract_num(chunk, "first_entry")? as i64 / 1_000_000;
            let last = extract_num(chunk, "last_entry")? as i64 / 1_000_000;
            (last > first && first > 0).then_some((first, last))
        })
        .collect()
}

/// Commit timestamps in the monorepo clone.
fn commits() -> Vec<i64> {
    // ATLAS_REPO_DIR: git checkout whose commits feed the heatmap
    // (default: the monorepo clone at $HOME/atlas)
    let repo = std::env::var("ATLAS_REPO_DIR")
        .ok()
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/root".into());
            format!("{home}/atlas")
        });
    run(
        "git",
        &["-C", &repo, "log", "--since=160 days ago", "--format=%ct"],
    )
    .lines()
    .filter_map(|l| l.trim().parse().ok())
    .collect()
}

/// GET /api/activity — one entry per day, oldest first.
pub fn activity() -> String {
    let off = tz_offset_s();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let today = (now + off).div_euclid(86_400);
    let first_day = today - (DAYS - 1);

    let mut online_s = vec![0i64; DAYS as usize];
    let mut boot_count = vec![0u32; DAYS as usize];
    for (start, end) in boots() {
        let boot_day = (start + off).div_euclid(86_400);
        if boot_day >= first_day && boot_day <= today {
            boot_count[(boot_day - first_day) as usize] += 1;
        }
        // clip the interval into the window, then split it across days
        let mut t = start.max(first_day * 86_400 - off);
        let end = end.min(now);
        while t < end {
            let day = (t + off).div_euclid(86_400);
            if day > today {
                break;
            }
            let day_end = (day + 1) * 86_400 - off;
            let span = end.min(day_end) - t;
            if day >= first_day {
                online_s[(day - first_day) as usize] += span;
            }
            t = end.min(day_end);
        }
    }

    let mut commit_count = vec![0u32; DAYS as usize];
    for ts in commits() {
        let day = (ts + off).div_euclid(86_400);
        if day >= first_day && day <= today {
            commit_count[(day - first_day) as usize] += 1;
        }
    }

    let days: Vec<String> = (0..DAYS as usize)
        .map(|i| {
            format!(
                "{{\"d\":\"{}\",\"min\":{},\"boots\":{},\"commits\":{}}}",
                date_str(first_day + i as i64),
                (online_s[i] / 60).min(1440),
                boot_count[i],
                commit_count[i]
            )
        })
        .collect();
    format!(
        "{{\"today\":\"{}\",\"days\":[{}]}}",
        date_str(today),
        days.join(",")
    )
}
