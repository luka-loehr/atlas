//! Database access: one pool per process, embedded migrations, and a
//! LISTEN connection that turns Postgres notifications into a channel.

use std::time::Duration;

use anyhow::{Context, Result};
use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod};
use futures_util::StreamExt;
use tokio::sync::mpsc;
use tokio_postgres::{AsyncMessage, NoTls};

use crate::{env, home};

/// Every schema version, oldest first. The baseline carries version 7, the
/// last of the incremental files it replaced, so a database that already
/// reached 7 skips it.
const MIGRATIONS: &[(i32, &str)] = &[
    (7, include_str!("../../../db/migrations/0007_baseline.sql")),
    (8, include_str!("../../../db/migrations/0008_unified.sql")),
    (9, include_str!("../../../db/migrations/0009_shares.sql")),
];

/// Connection settings, in order of precedence:
///
///   ATLAS_DATABASE_URL   a full postgres:// URL
///   PGHOST / PGPORT / PGDATABASE / PGUSER + POSTGRES_PASSWORD
///   ATLAS_DB_ENV_FILE    file with a POSTGRES_PASSWORD= line
///                        (default ~/atlas/db/.env, the compose secrets file)
pub fn config() -> Result<tokio_postgres::Config> {
    if let Some(url) = env("ATLAS_DATABASE_URL") {
        return url.parse().context("ATLAS_DATABASE_URL is not a valid postgres URL");
    }
    let password = match env("POSTGRES_PASSWORD") {
        Some(p) => p,
        None => {
            let file = env("ATLAS_DB_ENV_FILE").unwrap_or_else(|| format!("{}/atlas/db/.env", home()));
            std::fs::read_to_string(&file)
                .ok()
                .and_then(|s| {
                    s.lines()
                        .find_map(|l| l.strip_prefix("POSTGRES_PASSWORD=").map(|v| v.trim().to_string()))
                })
                .with_context(|| {
                    format!("no database password: set ATLAS_DATABASE_URL, POSTGRES_PASSWORD, or a POSTGRES_PASSWORD= line in {file}")
                })?
        }
    };
    let mut cfg = tokio_postgres::Config::new();
    cfg.host(env("PGHOST").as_deref().unwrap_or("127.0.0.1"))
        .port(env("PGPORT").and_then(|p| p.parse().ok()).unwrap_or(5432))
        .dbname(env("PGDATABASE").as_deref().unwrap_or("atlas"))
        .user(env("PGUSER").as_deref().unwrap_or("atlas"))
        .password(password)
        .application_name("atlas");
    Ok(cfg)
}

pub fn pool(max_size: usize) -> Result<Pool> {
    let manager = Manager::from_config(
        config()?,
        NoTls,
        ManagerConfig { recycling_method: RecyclingMethod::Fast },
    );
    Ok(Pool::builder(manager).max_size(max_size).build()?)
}

/// Bring the schema up to date. Serialized across processes by an advisory
/// lock, and each version commits together with its row in
/// `schema_migrations`, so an interrupted run resumes cleanly.
pub async fn migrate(pool: &Pool) -> Result<()> {
    let mut c = pool.get().await.context("database unreachable")?;
    // IF NOT EXISTS / DROP IF EXISTS are chatty by design; only real
    // warnings are worth a log line
    c.batch_execute("SET client_min_messages = warning").await?;
    c.batch_execute(
        "CREATE TABLE IF NOT EXISTS schema_migrations (
             version    INTEGER PRIMARY KEY,
             applied_at TIMESTAMPTZ DEFAULT now())",
    )
    .await?;
    c.batch_execute("SELECT pg_advisory_lock(748219)").await?;
    let result = async {
        let current: i32 = c
            .query_one("SELECT coalesce(max(version), 0) FROM schema_migrations", &[])
            .await?
            .get(0);
        for (version, sql) in MIGRATIONS.iter().filter(|(v, _)| *v > current) {
            let tx = c.transaction().await?;
            tx.batch_execute(sql).await.with_context(|| format!("migration {version}"))?;
            tx.execute("INSERT INTO schema_migrations (version) VALUES ($1)", &[version]).await?;
            tx.commit().await?;
            tracing::info!("schema migrated to version {version}");
        }
        anyhow::Ok(())
    }
    .await;
    c.batch_execute("SELECT pg_advisory_unlock(748219); RESET client_min_messages").await?;
    result
}

/// LISTEN on `channels` forever, reconnecting when the connection drops.
/// Every notification arrives as its channel name; after a reconnect each
/// channel fires once, because anything may have been missed in between.
pub fn listen(channels: &'static [&'static str]) -> mpsc::UnboundedReceiver<&'static str> {
    let (tx, rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        loop {
            if let Err(e) = listen_once(channels, &tx).await {
                tracing::warn!("listen connection lost: {e:#}");
            }
            if tx.is_closed() {
                return;
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    });
    rx
}

async fn listen_once(
    channels: &'static [&'static str],
    tx: &mpsc::UnboundedSender<&'static str>,
) -> Result<()> {
    let (client, mut connection) = config()?.connect(NoTls).await?;
    let (ntx, mut nrx) = mpsc::unbounded_channel::<String>();
    let driver = tokio::spawn(async move {
        let mut messages = futures_util::stream::poll_fn(move |cx| connection.poll_message(cx));
        while let Some(message) = messages.next().await {
            match message {
                Ok(AsyncMessage::Notification(n)) => {
                    if ntx.send(n.channel().to_string()).is_err() {
                        break;
                    }
                }
                Ok(_) => {}
                Err(_) => break,
            }
        }
    });
    for channel in channels {
        client.batch_execute(&format!("LISTEN {channel}")).await?;
        let _ = tx.send(channel);
    }
    while let Some(name) = nrx.recv().await {
        if let Some(channel) = channels.iter().find(|c| **c == name) {
            if tx.send(channel).is_err() {
                break;
            }
        }
    }
    driver.abort();
    anyhow::bail!("notification stream ended")
}
