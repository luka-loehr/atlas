//! The machine's numbers, read straight from /proc, /sys and statvfs.

use std::fs;

use serde::Serialize;

use crate::Config;

pub(super) fn read_trimmed(path: &str) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

pub fn hostname() -> String {
    read_trimmed("/etc/hostname")
        .or_else(|| read_trimmed("/proc/sys/kernel/hostname"))
        .unwrap_or_else(|| "atlas".into())
}

/// (total, idle) jiffies summed over all cores.
pub(super) fn cpu_jiffies() -> (u64, u64) {
    let stat = fs::read_to_string("/proc/stat").unwrap_or_default();
    let fields: Vec<u64> = stat
        .lines()
        .next()
        .unwrap_or("")
        .split_whitespace()
        .skip(1)
        .filter_map(|x| x.parse().ok())
        .collect();
    let idle = fields.get(3).copied().unwrap_or(0) + fields.get(4).copied().unwrap_or(0);
    (fields.iter().sum(), idle)
}

pub(super) fn cpu_percent(before: (u64, u64), now: (u64, u64)) -> f32 {
    let total = now.0.saturating_sub(before.0);
    let idle = now.1.saturating_sub(before.1);
    if total == 0 {
        return 0.0;
    }
    ((1.0 - idle as f64 / total as f64) * 100.0).clamp(0.0, 100.0) as f32
}

/// (percent used, GiB used, GiB total)
pub(super) fn memory() -> (f32, f32, f32) {
    let info = fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let gib = |key: &str| {
        info.lines()
            .find(|l| l.starts_with(key))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|x| x.parse::<f64>().ok())
            .unwrap_or(0.0)
            / 1_048_576.0
    };
    let total = gib("MemTotal:");
    let used = (total - gib("MemAvailable:")).max(0.0);
    let percent = if total > 0.0 {
        used / total * 100.0
    } else {
        0.0
    };
    (percent as f32, used as f32, total as f32)
}

/// Cumulative rx/tx over physical interfaces. Loopback, container bridges
/// and the tailscale device are skipped: their traffic either never leaves
/// the box or is already counted on the NIC it leaves through.
pub(super) fn net_bytes() -> (u64, u64) {
    let dev = fs::read_to_string("/proc/net/dev").unwrap_or_default();
    let (mut rx, mut tx) = (0u64, 0u64);
    for line in dev.lines().skip(2) {
        let Some((name, rest)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim();
        if name == "lo"
            || ["docker", "veth", "br-", "tailscale"]
                .iter()
                .any(|p| name.starts_with(p))
        {
            continue;
        }
        let fields: Vec<&str> = rest.split_whitespace().collect();
        if fields.len() >= 9 {
            rx += fields[0].parse::<u64>().unwrap_or(0);
            tx += fields[8].parse::<u64>().unwrap_or(0);
        }
    }
    (rx, tx)
}

/// The CPU package sensor (coretemp on Intel, k10temp/zenpower on AMD).
pub(super) fn cpu_temp() -> Option<f32> {
    for entry in fs::read_dir("/sys/class/hwmon").ok()?.flatten() {
        let dir = entry.path();
        let name = read_trimmed(&dir.join("name").to_string_lossy())?;
        if matches!(name.as_str(), "coretemp" | "k10temp" | "zenpower") {
            let millis: f32 = read_trimmed(&dir.join("temp1_input").to_string_lossy())?
                .parse()
                .ok()?;
            return Some(millis / 1000.0);
        }
    }
    None
}

const RAPL_ENERGY: &str = "/sys/class/powercap/intel-rapl:0/energy_uj";
const RAPL_RANGE: &str = "/sys/class/powercap/intel-rapl:0/max_energy_range_uj";

/// Microjoules since boot. Root-only by default; scripts/power makes it
/// readable.
pub(super) fn rapl_energy() -> Option<u64> {
    read_trimmed(RAPL_ENERGY)?.parse().ok()
}

pub(super) fn rapl_watts(before: u64, now: u64, seconds: f64) -> Option<f32> {
    if seconds <= 0.0 {
        return None;
    }
    let joules = if now >= before {
        now - before
    } else {
        // the counter wrapped
        let range: u64 = read_trimmed(RAPL_RANGE)?.parse().ok()?;
        (range - before).saturating_add(now)
    };
    Some((joules as f64 / 1_000_000.0 / seconds) as f32)
}

#[derive(Serialize)]
pub(super) struct Disk {
    mount: String,
    used: u64,
    total: u64,
}

/// The filesystems the library lives on, each once.
pub(super) fn disks(cfg: &Config) -> Vec<Disk> {
    use std::os::unix::fs::MetadataExt;
    let mounts: Vec<(String, String)> = fs::read_to_string("/proc/mounts")
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let mut fields = l.split_whitespace();
            Some((fields.next()?.to_string(), fields.next()?.to_string()))
        })
        .collect();
    // A filesystem can be mounted more than once (a bind mount into the
    // library): name it by where its device is mounted first.
    let mount_of = |path: &std::path::Path| -> String {
        let path = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        let device = mounts
            .iter()
            .filter(|(_, at)| path.starts_with(at))
            .max_by_key(|(_, at)| at.len())
            .map(|(d, _)| d);
        mounts
            .iter()
            .find(|(d, _)| Some(d) == device)
            .map_or_else(|| "/".to_string(), |(_, at)| at.clone())
    };
    let mut seen = Vec::new();
    let mut out = Vec::new();
    for path in [
        std::path::PathBuf::from("/"),
        cfg.originals_dir(),
        cfg.blobs_dir(),
    ] {
        let Ok(meta) = fs::metadata(&path) else {
            continue;
        };
        if seen.contains(&meta.dev()) {
            continue;
        }
        seen.push(meta.dev());
        let Ok(c_path) = std::ffi::CString::new(path.to_string_lossy().as_bytes()) else {
            continue;
        };
        let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
        // SAFETY: c_path is a valid NUL-terminated string and stat is a
        // properly sized, writable statvfs the call fills in.
        if unsafe { libc::statvfs(c_path.as_ptr(), &mut stat) } != 0 {
            continue;
        }
        let block = stat.f_frsize as u64;
        let total = stat.f_blocks as u64 * block;
        out.push(Disk {
            mount: mount_of(&path),
            used: total - stat.f_bfree as u64 * block,
            total,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cpu_percent_is_the_busy_share_of_the_interval() {
        assert_eq!(cpu_percent((1000, 800), (1100, 825)), 75.0);
        assert_eq!(cpu_percent((1000, 800), (1000, 800)), 0.0);
    }
}
