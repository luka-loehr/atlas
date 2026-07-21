//! Energy logging: integrate full-system power over time into Postgres so the
//! app can show a per-day cost bar chart and a running lifetime total.
//!
//! One row per day in `power_daily(day, wh, samples)`. A background thread
//! samples system watts every 10 s, accumulates Wh, and flushes to the DB
//! roughly once a minute (UPSERT that adds onto the current day). Cost is left
//! to the app so the €/kWh tariff stays user-configurable.

use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

/// Run a query inside the postgres container (trust auth for the atlas user —
/// no password needed, same path the manual psql calls use).
fn psql(sql: &str) -> Option<String> {
    let out = Command::new("docker")
        .args([
            "exec", "atlas-postgres", "psql", "-U", "atlas", "-d", "atlas", "-tAc", sql,
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).to_string())
}

pub fn start_logger() {
    thread::spawn(|| {
        let _ = psql(
            "CREATE TABLE IF NOT EXISTS power_daily (\
             day date PRIMARY KEY, \
             wh double precision NOT NULL DEFAULT 0, \
             samples bigint NOT NULL DEFAULT 0, \
             updated_at timestamptz DEFAULT now())",
        );
        let mut accum_wh = 0.0f64;
        let mut samples = 0i64;
        let mut last = Instant::now();
        let mut ticks = 0u32;
        loop {
            thread::sleep(Duration::from_secs(10));
            let now = Instant::now();
            let dt_h = now.duration_since(last).as_secs_f64() / 3600.0;
            last = now;
            if let Some(w) = crate::metrics::system_power_sample() {
                accum_wh += w * dt_h;
                samples += 1;
            }
            ticks += 1;
            // flush ~once a minute; a restart loses at most the unflushed minute
            if ticks >= 6 && accum_wh > 0.0 {
                let sql = format!(
                    "INSERT INTO power_daily(day, wh, samples) \
                     VALUES (CURRENT_DATE, {accum_wh:.5}, {samples}) \
                     ON CONFLICT (day) DO UPDATE SET \
                     wh = power_daily.wh + EXCLUDED.wh, \
                     samples = power_daily.samples + EXCLUDED.samples, \
                     updated_at = now()"
                );
                if psql(&sql).is_some() {
                    accum_wh = 0.0;
                    samples = 0;
                }
                ticks = 0;
            }
        }
    });
}

/// `{"days":[{"day":"2026-07-21","wh":1234.5},…],"total_wh":98765.4}`
pub fn daily_json() -> String {
    let rows = psql(
        "SELECT day::text, round(wh::numeric,1) FROM power_daily \
         WHERE day > CURRENT_DATE - 31 ORDER BY day",
    )
    .unwrap_or_default();
    let total = psql("SELECT round(coalesce(sum(wh),0)::numeric,1) FROM power_daily")
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "0".into());

    let mut items = String::new();
    for line in rows.lines() {
        let mut p = line.split('|');
        if let (Some(day), Some(wh)) = (p.next(), p.next()) {
            let day = day.trim();
            let wh = wh.trim();
            if day.is_empty() || wh.is_empty() {
                continue;
            }
            if !items.is_empty() {
                items.push(',');
            }
            items.push_str(&format!("{{\"day\":\"{day}\",\"wh\":{wh}}}"));
        }
    }
    format!("{{\"days\":[{items}],\"total_wh\":{total}}}")
}
