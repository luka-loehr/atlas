//! What runs on the machine: the Atlas services and their queue, Docker
//! containers, the tailnet, and the power switch.

use std::collections::BTreeMap;
use std::time::Duration;

use axum::Json;
use axum::extract::{Path, State};
use chrono::{DateTime, Datelike, Local, TimeZone, Utc};
use serde_json::{Value, json};
use tokio::process::Command;

use crate::{ApiError, ApiResult, AppState};

/// Run a command and return its stdout; empty on any failure. Nothing here
/// may hang a request, so every call is bounded.
async fn output(program: &str, args: &[&str]) -> String {
    let run = Command::new(program).args(args).kill_on_drop(true).output();
    match tokio::time::timeout(Duration::from_secs(8), run).await {
        Ok(Ok(out)) => String::from_utf8_lossy(&out.stdout).into_owned(),
        _ => String::new(),
    }
}

// ---------------------------------------------------------------- services ---

const UNITS: &[(&str, &str)] = &[("atlas-server", "API and ingest workers"), ("atlas-ml", "Embeddings and faces")];

/// One screen's worth of "is Atlas healthy": the units, the database, the
/// model worker, and what the job queue still has to do.
pub async fn services(State(app): State<AppState>) -> ApiResult<Json<Value>> {
    let mut units = Vec::new();
    for (unit, role) in UNITS {
        let show = output(
            "systemctl",
            &["show", unit, "--property=ActiveState,SubState,ActiveEnterTimestamp,MemoryCurrent,NRestarts"],
        )
        .await;
        let property = |key: &str| {
            show.lines().find_map(|l| l.strip_prefix(key).and_then(|v| v.strip_prefix('='))).unwrap_or("").to_string()
        };
        units.push(json!({
            "unit": unit,
            "role": role,
            "state": property("ActiveState"),
            "detail": property("SubState"),
            "since": property("ActiveEnterTimestamp"),
            "memory": property("MemoryCurrent").parse::<u64>().ok(),
            "restarts": property("NRestarts").parse::<u64>().ok(),
        }));
    }

    let c = app.pool.get().await?;
    let database: String = c.query_one("SHOW server_version", &[]).await?.get(0);
    let size: i64 = c.query_one("SELECT pg_database_size(current_database())", &[]).await?.get(0);
    let mut queue: BTreeMap<String, BTreeMap<String, i64>> = BTreeMap::new();
    for row in c.query("SELECT kind, status, count(*) FROM ingest_jobs GROUP BY kind, status", &[]).await? {
        queue.entry(row.get(0)).or_default().insert(row.get(1), row.get(2));
    }
    let failed: Vec<Value> = c
        .query(
            "SELECT kind, owner_id, error, updated_at FROM ingest_jobs
             WHERE status = 'failed' ORDER BY updated_at DESC LIMIT 20",
            &[],
        )
        .await?
        .iter()
        .map(|r| {
            json!({
                "kind": r.get::<_, String>(0), "owner": r.get::<_, String>(1),
                "error": r.get::<_, Option<String>>(2), "at": r.get::<_, Option<DateTime<Utc>>>(3),
            })
        })
        .collect();
    drop(c);

    Ok(Json(json!({
        "units": units,
        "database": { "version": database, "bytes": size },
        "ml": app.ml.health().await,
        "vectors": app.ml.vectors.len().await,
        "queue": queue,
        "failed": failed,
    })))
}

// ------------------------------------------------------------------ docker ---

/// A name we let reach docker's argv: no option injection, no traversal.
fn safe_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() < 128
        && !name.starts_with('-')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

pub async fn containers() -> Json<Value> {
    let listing = output("docker", &["ps", "-a", "--format", "{{json .}}"]).await;
    let items: Vec<Value> = listing
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .map(|c| {
            json!({
                "name": c["Names"], "image": c["Image"], "state": c["State"],
                "status": c["Status"], "ports": c["Ports"],
            })
        })
        .collect();
    Json(json!({ "containers": items }))
}

pub async fn container(Path(name): Path<String>) -> ApiResult<Json<Value>> {
    if !safe_name(&name) {
        return Err(ApiError::NotFound);
    }
    let inspect = output("docker", &["inspect", &name]).await;
    let parsed: Value = serde_json::from_str(&inspect).unwrap_or(Value::Null);
    let c = parsed.get(0).ok_or(ApiError::NotFound)?;
    // docker writes a container's stderr to our stderr: fold both together
    let logs = Command::new("docker").args(["logs", "--tail", "200", &name]).kill_on_drop(true).output();
    let logs = match tokio::time::timeout(Duration::from_secs(8), logs).await {
        Ok(Ok(out)) => {
            let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
            text.push_str(&String::from_utf8_lossy(&out.stderr));
            text
        }
        _ => String::new(),
    };
    Ok(Json(json!({
        "name": name,
        "image": c["Config"]["Image"],
        "state": c["State"]["Status"],
        "started": c["State"]["StartedAt"],
        "restarts": c["RestartCount"],
        "ports": c["NetworkSettings"]["Ports"].as_object().map(|p| p.keys().cloned().collect::<Vec<_>>()),
        "logs": logs,
    })))
}

// ----------------------------------------------------------------- tailnet ---

pub async fn network() -> Json<Value> {
    let status: Value = serde_json::from_str(&output("tailscale", &["status", "--json"]).await).unwrap_or(Value::Null);
    let node = |n: &Value| {
        json!({
            "name": n["HostName"], "dns": n["DNSName"], "os": n["OS"],
            "addresses": n["TailscaleIPs"], "online": n["Online"],
            "exit_node": n["ExitNode"], "offers_exit_node": n["ExitNodeOption"],
            "last_seen": n["LastSeen"], "rx": n["RxBytes"], "tx": n["TxBytes"],
        })
    };
    let mut peers: Vec<Value> = status["Peer"].as_object().map(|p| p.values().map(node).collect()).unwrap_or_default();
    peers.sort_by_key(|p| (!p["online"].as_bool().unwrap_or(false), p["name"].as_str().unwrap_or("").to_lowercase()));
    Json(json!({
        "available": !status.is_null(),
        "state": status["BackendState"],
        "tailnet": status["CurrentTailnet"]["Name"],
        "self": node(&status["Self"]),
        "peers": peers,
    }))
}

// ---------------------------------------------------------------- activity ---

const ACTIVITY_DAYS: i64 = 154; // 22 weeks of heatmap

/// Per local day, oldest first: minutes the machine was up (rebuilt from the
/// journal's boot list, so it works retroactively), boots, and commits in
/// the Atlas checkout.
pub async fn activity(State(app): State<AppState>) -> Json<Value> {
    let today = Local::now().date_naive();
    let first = today - chrono::Duration::days(ACTIVITY_DAYS - 1);
    let index = |day: chrono::NaiveDate| -> Option<usize> {
        let offset = (day - first).num_days();
        (0..ACTIVITY_DAYS).contains(&offset).then_some(offset as usize)
    };
    let mut minutes = vec![0i64; ACTIVITY_DAYS as usize];
    let mut boots = vec![0u32; ACTIVITY_DAYS as usize];
    let mut commits = vec![0u32; ACTIVITY_DAYS as usize];

    let boot_list: Value =
        serde_json::from_str(&output("journalctl", &["--list-boots", "-o", "json"]).await).unwrap_or(Value::Null);
    for boot in boot_list.as_array().into_iter().flatten() {
        let micros = |key: &str| boot[key].as_i64().and_then(|us| Local.timestamp_micros(us).single());
        let (Some(start), Some(end)) = (micros("first_entry"), micros("last_entry")) else { continue };
        if let Some(i) = index(start.date_naive()) {
            boots[i] += 1;
        }
        // split the uptime interval at local midnights
        let mut cursor = start;
        while cursor < end {
            let day = cursor.date_naive();
            let midnight = (day + chrono::Duration::days(1))
                .and_hms_opt(0, 0, 0)
                .and_then(|t| Local.from_local_datetime(&t).earliest())
                .unwrap_or(end);
            let until = end.min(midnight);
            if let Some(i) = index(day) {
                minutes[i] += (until - cursor).num_minutes();
            }
            if until <= cursor {
                break;
            }
            cursor = until;
        }
    }

    let repo = app.cfg.repo_dir.to_string_lossy().into_owned();
    let log = output("git", &["-C", &repo, "log", "--since=160 days ago", "--format=%ct"]).await;
    for stamp in log.lines().filter_map(|l| l.trim().parse::<i64>().ok()) {
        if let Some(i) = Local.timestamp_opt(stamp, 0).single().and_then(|t| index(t.date_naive())) {
            commits[i] += 1;
        }
    }

    let days: Vec<Value> = (0..ACTIVITY_DAYS as usize)
        .map(|i| {
            let day = first + chrono::Duration::days(i as i64);
            json!({
                "d": format!("{:04}-{:02}-{:02}", day.year(), day.month(), day.day()),
                "min": minutes[i].min(1440), "boots": boots[i], "commits": commits[i],
            })
        })
        .collect();
    Json(json!({ "today": today.to_string(), "days": days }))
}

// ------------------------------------------------------------------- power ---

/// Answers first, then acts a second later, so the response still makes it
/// out. Needs passwordless sudo for exactly `systemctl poweroff|reboot`.
pub async fn power(Path(action): Path<String>) -> ApiResult<Json<Value>> {
    let verb = match action.as_str() {
        "shutdown" => "poweroff",
        "restart" => "reboot",
        _ => return Err(ApiError::NotFound),
    };
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(1)).await;
        let _ = Command::new("sudo").args(["-n", "systemctl", verb]).status().await;
    });
    Ok(Json(json!({ "ok": true, "action": action })))
}

#[cfg(test)]
mod tests {
    use super::safe_name;

    #[test]
    fn container_names_cannot_be_options_or_paths() {
        assert!(safe_name("atlas-postgres"));
        assert!(!safe_name("--help"));
        assert!(!safe_name("a/b"));
        assert!(!safe_name(""));
    }
}
