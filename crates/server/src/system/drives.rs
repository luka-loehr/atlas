//! The drives inside the machine: what each one is (SSD or HDD, how it is
//! connected), what is mounted on it and how full, and its health as SMART
//! reports it (passed, temperature, hours, wear). `smartctl` needs root; the
//! service may run it through `sudo -n` like the power switch. A sleeping
//! HDD is left asleep (`-n standby`), and the answer is kept for a minute.

use std::sync::OnceLock;
use std::time::{Duration, Instant};

use axum::Json;
use serde_json::{Value, json};
use tokio::process::Command;
use tokio::sync::Mutex;

use crate::ApiResult;

const FRESH: Duration = Duration::from_secs(60);

fn cache() -> &'static Mutex<Option<(Instant, Value)>> {
    static CACHE: OnceLock<Mutex<Option<(Instant, Value)>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

/// stdout of a bounded command; empty on any failure.
async fn output(program: &str, args: &[&str]) -> String {
    let run = Command::new(program).args(args).kill_on_drop(true).output();
    match tokio::time::timeout(Duration::from_secs(10), run).await {
        Ok(Ok(out)) => String::from_utf8_lossy(&out.stdout).into_owned(),
        _ => String::new(),
    }
}

pub async fn drives() -> ApiResult<Json<Value>> {
    let mut cached = cache().lock().await;
    if let Some((at, value)) = cached.as_ref()
        && at.elapsed() < FRESH
    {
        return Ok(Json(value.clone()));
    }
    // loop devices (7) and network block devices (43) are not drives
    let listing = output(
        "lsblk",
        &["-J", "-b", "-e", "7,43", "-o", "NAME,MODEL,ROTA,SIZE,TRAN,TYPE,FSSIZE,FSUSED,MOUNTPOINT"],
    )
    .await;
    let disks = disks(&listing);
    let health = futures_util::future::join_all(disks.iter().map(|d| smart(d.name.clone()))).await;
    let drives: Vec<Value> = disks.into_iter().zip(health).map(|(d, h)| d.json(h)).collect();
    let value = json!({ "drives": drives });
    *cached = Some((Instant::now(), value.clone()));
    Ok(Json(value))
}

struct Disk {
    name: String,
    model: Option<String>,
    rotational: bool,
    size: u64,
    transport: Option<String>,
    mounts: Vec<Value>,
}

impl Disk {
    fn json(self, health: Value) -> Value {
        json!({
            "name": self.name,
            "model": self.model,
            "kind": if self.rotational { "hdd" } else { "ssd" },
            "transport": self.transport,
            "size": self.size,
            "mounts": self.mounts,
            "health": health,
        })
    }
}

/// The whole disks of an lsblk listing, each with every mounted filesystem
/// below it (partitions, LVM, crypt).
fn disks(listing: &str) -> Vec<Disk> {
    let Ok(root) = serde_json::from_str::<Value>(listing) else { return Vec::new() };
    let mut out = Vec::new();
    for dev in root["blockdevices"].as_array().into_iter().flatten() {
        if dev["type"] != "disk" || dev["size"].as_u64().unwrap_or(0) == 0 {
            continue;
        }
        let mut mounts = Vec::new();
        collect_mounts(dev, &mut mounts);
        out.push(Disk {
            name: dev["name"].as_str().unwrap_or_default().to_string(),
            model: dev["model"].as_str().map(|m| m.trim().to_string()),
            rotational: dev["rota"].as_bool().unwrap_or(false),
            size: dev["size"].as_u64().unwrap_or(0),
            transport: dev["tran"].as_str().map(str::to_string),
            mounts,
        });
    }
    out
}

fn collect_mounts(dev: &Value, out: &mut Vec<Value>) {
    if let (Some(mount), Some(size)) = (dev["mountpoint"].as_str(), dev["fssize"].as_u64())
        && !mount.starts_with("/boot")
        && mount != "[SWAP]"
    {
        out.push(json!({ "mount": mount, "size": size, "used": dev["fsused"].as_u64().unwrap_or(0) }));
    }
    for child in dev["children"].as_array().into_iter().flatten() {
        collect_mounts(child, out);
    }
}

/// SMART for one drive, as a few plain numbers; `null` when it cannot be
/// read, `{"asleep": true}` for an HDD in standby.
async fn smart(name: String) -> Value {
    let path = format!("/dev/{name}");
    let text = output("sudo", &["-n", "smartctl", "-j", "-a", "-n", "standby", &path]).await;
    let Ok(s) = serde_json::from_str::<Value>(&text) else { return Value::Null };
    parse_smart(&s)
}

fn parse_smart(s: &Value) -> Value {
    let asleep = s["smartctl"]["messages"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|m| m["string"].as_str().is_some_and(|t| t.contains("STANDBY")));
    if asleep {
        return json!({ "asleep": true });
    }
    if s["smart_status"].is_null() {
        return Value::Null;
    }
    let attribute = |id: u64| {
        s["ata_smart_attributes"]["table"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|a| a["id"].as_u64() == Some(id))
            .and_then(|a| a["raw"]["value"].as_u64())
    };
    let nvme = &s["nvme_smart_health_information_log"];
    json!({
        "passed": s["smart_status"]["passed"].as_bool(),
        "temperature": s["temperature"]["current"].as_u64(),
        "hours": s["power_on_time"]["hours"].as_u64(),
        "rpm": s["rotation_rate"].as_u64().filter(|r| *r > 0),
        // NVMe: how much of the rated endurance is used, the spare left,
        // what was written (data units are 1000 × 512 bytes)
        "wear": nvme["percentage_used"].as_u64(),
        "spare": nvme["available_spare"].as_u64(),
        "written": nvme["data_units_written"].as_u64().map(|u| u * 512_000),
        "media_errors": nvme["media_errors"].as_u64(),
        // ATA: sectors moved away, waiting, unreadable
        "reallocated": attribute(5),
        "pending": attribute(197),
        "uncorrectable": attribute(198),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whole_disks_with_their_mounts_through_lvm() {
        let listing = r#"{"blockdevices":[
          {"name":"nvme0n1","model":"Fast SSD ","rota":false,"size":1000,"tran":"nvme","type":"disk","fssize":null,"fsused":null,"mountpoint":null,
           "children":[{"name":"nvme0n1p1","rota":false,"size":1,"type":"part","fssize":1,"fsused":1,"mountpoint":"/boot/efi"},
                       {"name":"nvme0n1p3","rota":false,"size":900,"type":"part","fssize":null,"fsused":null,"mountpoint":null,
                        "children":[{"name":"vg-root","rota":false,"size":900,"type":"lvm","fssize":800,"fsused":700,"mountpoint":"/"}]}]},
          {"name":"sdz","model":null,"rota":true,"size":0,"tran":"usb","type":"disk"},
          {"name":"sda","model":"Big HDD","rota":true,"size":4000,"tran":"sata","type":"disk","fssize":null,"fsused":null,"mountpoint":null,
           "children":[{"name":"sda1","rota":true,"size":4000,"type":"part","fssize":3900,"fsused":100,"mountpoint":"/srv/bulk"}]}]}"#;
        let d = disks(listing);
        assert_eq!(d.len(), 2);
        assert_eq!(d[0].model.as_deref(), Some("Fast SSD"));
        assert!(!d[0].rotational);
        assert_eq!(d[0].mounts, vec![json!({"mount": "/", "size": 800, "used": 700})]);
        assert!(d[1].rotational);
        assert_eq!(d[1].mounts[0]["mount"], "/srv/bulk");
    }

    #[test]
    fn smart_of_an_nvme_drive_and_a_sleeping_hdd() {
        let nvme = json!({"smart_status":{"passed":true},"temperature":{"current":27},"power_on_time":{"hours":3134},
                          "nvme_smart_health_information_log":{"percentage_used":5,"available_spare":100,"data_units_written":2,"media_errors":0}});
        let h = parse_smart(&nvme);
        assert_eq!(h["passed"], true);
        assert_eq!(h["wear"], 5);
        assert_eq!(h["written"], 1_024_000);
        assert!(h["reallocated"].is_null());
        let asleep = json!({"smartctl":{"messages":[{"string":"Device is in STANDBY mode, exit(2)"}]}});
        assert_eq!(parse_smart(&asleep), json!({"asleep": true}));
    }
}
