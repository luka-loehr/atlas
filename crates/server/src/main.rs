//! atlas-server — the whole Atlas backend in one process.
//!
//!   atlas-server                 serve the API and run the ingest workers
//!   atlas-server migrate         apply schema migrations and exit
//!   atlas-server import photos   ingest Google Takeout photo archives
//!   atlas-server import drive    ingest Google Takeout drive archives
//!   atlas-server backfill ...    one-off repair passes over the library
//!
//! The API has three areas, all under /v1 and all behind one bearer token:
//! `photos` (timeline, albums, people, search, upload), `drive` (folders and
//! content-addressed files) and `system` (metrics, services, terminal, power).

mod auth;
mod config;
mod drive;
mod error;
mod imaging;
mod import;
mod jobs;
mod media;
mod photos;
mod share;
mod system;
mod util;

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use axum::Router;
use axum::http::{Extensions, HeaderMap, StatusCode, Version, header};
use axum::middleware;
use axum::routing::get;
use clap::{Parser, Subcommand};
use deadpool_postgres::Pool;
use tower_http::compression::CompressionLayer;

pub use config::Config;
pub use error::{ApiError, ApiResult};

/// Shared state of every handler and worker.
pub struct App {
    pub cfg: Config,
    pub pool: Pool,
    pub timeline: photos::timeline::Cache,
    pub ml: photos::search::Ml,
    pub metrics: system::metrics::Sampler,
    /// Poked whenever jobs are enqueued, so idle workers start at once.
    pub jobs_wake: tokio::sync::Notify,
}

pub type AppState = Arc<App>;

#[derive(Parser)]
#[command(name = "atlas-server", version, about = "The Atlas backend")]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Serve the API and run the ingest workers (the default)
    Serve,
    /// Apply schema migrations and exit
    Migrate,
    /// Ingest a Google Takeout export
    Import {
        #[command(subcommand)]
        what: ImportKind,
    },
    /// Re-derive data for assets that are already in the library
    Backfill {
        #[command(subcommand)]
        what: jobs::backfill::Kind,
    },
}

#[derive(Subcommand)]
enum ImportKind {
    /// Photo and video archives (takeout-*.zip, read in place)
    Photos { archives: Vec<PathBuf> },
    /// Drive archives (the Takeout/Drive/ tree, read in place)
    Drive { archives: Vec<PathBuf> },
}

#[tokio::main]
async fn main() -> Result<()> {
    atlas_core::init_logging();
    let cli = Cli::parse();
    let pool = atlas_core::db::pool(24)?;

    match cli.command.unwrap_or(Command::Serve) {
        Command::Migrate => atlas_core::db::migrate(&pool).await,
        Command::Import { what } => {
            atlas_core::db::migrate(&pool).await?;
            let cfg = Config::from_env(false)?;
            match what {
                ImportKind::Photos { archives } => import::photos::run(&cfg, &pool, &archives).await,
                ImportKind::Drive { archives } => import::drive::run(&cfg, &pool, &archives).await,
            }
        }
        Command::Backfill { what } => {
            atlas_core::db::migrate(&pool).await?;
            let cfg = Config::from_env(false)?;
            jobs::backfill::run(&cfg, &pool, what).await
        }
        Command::Serve => serve(pool).await,
    }
}

/// Compress JSON and nothing else: media is already compressed, and a
/// recompressed Range response would no longer be the bytes that were asked
/// for.
fn json_only(_: StatusCode, _: Version, headers: &HeaderMap, _: &Extensions) -> bool {
    headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|content_type| content_type.starts_with("application/json"))
}

async fn serve(pool: Pool) -> Result<()> {
    let cfg = Config::from_env(true)?;
    atlas_core::db::migrate(&pool).await?;
    for dir in [cfg.thumbs_dir(), cfg.faces_dir(), cfg.incoming_dir(), cfg.blobs_dir(), cfg.previews_dir.clone()] {
        std::fs::create_dir_all(&dir).with_context(|| format!("cannot create {}", dir.display()))?;
    }

    let app: AppState = Arc::new(App {
        ml: photos::search::Ml::new(&cfg),
        metrics: system::metrics::Sampler::start(&cfg),
        timeline: photos::timeline::Cache::default(),
        jobs_wake: tokio::sync::Notify::new(),
        pool,
        cfg,
    });

    // Postgres tells us when the library or the queue changed, whoever wrote.
    let mut notifications = atlas_core::db::listen(&["atlas_assets", "atlas_jobs", "atlas_embeddings"]);
    let listener_app = app.clone();
    tokio::spawn(async move {
        while let Some(channel) = notifications.recv().await {
            match channel {
                "atlas_assets" => listener_app.timeline.invalidate(),
                "atlas_embeddings" => listener_app.ml.vectors.mark_stale(),
                _ => listener_app.jobs_wake.notify_waiters(),
            }
        }
    });

    jobs::worker::spawn(app.clone());
    // links still uploading when atlas stopped carry on
    tokio::spawn(share::resume(app.clone()));

    // the trash keeps things for 30 days, then they go for good
    let trash_app = app.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(std::time::Duration::from_secs(3600));
        loop {
            tick.tick().await;
            match photos::assets::purge_expired(&trash_app).await {
                Ok(0) => {}
                Ok(n) => tracing::info!("trash: removed {n} photos older than {} days", photos::assets::TRASH_DAYS),
                Err(e) => tracing::warn!("trash: photo purge failed: {}", e.message()),
            }
            match drive::purge_expired(&trash_app).await {
                Ok(0) => {}
                Ok(n) => tracing::info!("trash: removed {n} files older than {} days", photos::assets::TRASH_DAYS),
                Err(e) => tracing::warn!("trash: file purge failed: {}", e.message()),
            }
            match share::purge_expired(&trash_app).await {
                Ok(0) => {}
                Ok(n) => tracing::info!("share: removed {n} expired links"),
                Err(e) => tracing::warn!("share: expiry sweep failed: {}", e.message()),
            }
            match photos::people::tidy(&trash_app).await {
                Ok((0, 0)) => {}
                Ok((removed, covers)) => tracing::info!("people: removed {removed} without faces, set {covers} covers"),
                Err(e) => tracing::warn!("people: tidy failed: {}", e.message()),
            }
        }
    });

    let router = Router::new()
        .nest("/v1", photos::routes().merge(drive::routes()).merge(system::routes()).merge(share::routes()))
        .layer(middleware::from_fn_with_state(app.clone(), auth::require_token))
        .route("/health", get(|| async { "ok" }))
        .layer(CompressionLayer::new().compress_when(json_only))
        .with_state(app.clone());

    let listener = tokio::net::TcpListener::bind(&app.cfg.bind)
        .await
        .with_context(|| format!("cannot bind {}", app.cfg.bind))?;
    tracing::info!(
        "atlas-server {} on {} (library {}, {} workers)",
        env!("CARGO_PKG_VERSION"),
        app.cfg.bind,
        app.cfg.photos_dir.display(),
        app.cfg.workers
    );
    axum::serve(listener, router)
        .with_graceful_shutdown(async {
            let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).unwrap();
            tokio::select! {
                _ = term.recv() => {}
                _ = tokio::signal::ctrl_c() => {}
            }
        })
        .await?;
    Ok(())
}
