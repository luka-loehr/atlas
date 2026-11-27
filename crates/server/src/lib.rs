#![recursion_limit = "512"]
//! The Atlas backend library, exposing the application state, router builder,
//! and subsystems for both the `atlas-server` binary and full integration tests.

pub mod auth;
pub mod config;
pub mod drive;
pub mod error;
pub mod iam;
pub mod imaging;
pub mod import;
pub mod jobs;
pub mod media;
pub mod openapi;
pub mod photos;
pub mod s3;
pub mod share;
pub mod storage;
pub mod system;
pub mod upload;
pub mod util;

use std::sync::Arc;

use axum::Router;
use axum::http::{Extensions, HeaderMap, StatusCode, Version, header};
use axum::middleware;
use axum::routing::get;
use deadpool_postgres::Pool;
use tower_http::compression::CompressionLayer;

pub use config::Config;
pub use error::{ApiError, ApiResult};

/// Shared state of every handler and worker.
pub struct App {
    pub cfg: Config,
    pub pool: Pool,
    pub iam: iam::IamState,
    pub timeline: photos::timeline::Cache,
    pub ml: photos::search::Ml,
    pub metrics: system::metrics::Sampler,
    /// Poked whenever jobs are enqueued, so idle workers start at once.
    pub jobs_wake: tokio::sync::Notify,
}

pub type AppState = Arc<App>;

/// Compress JSON and nothing else: media is already compressed, and a
/// recompressed Range response would no longer be the bytes that were asked for.
pub fn json_only(_: StatusCode, _: Version, headers: &HeaderMap, _: &Extensions) -> bool {
    headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|content_type| content_type.starts_with("application/json"))
}

pub fn build_router(app: AppState) -> Router {
    let v1 = photos::routes()
        .merge(drive::routes())
        .merge(storage::routes())
        .merge(system::routes())
        .merge(share::routes())
        .merge(iam::routes())
        .route("/openapi.json", get(openapi::serve_openapi));

    let authed_v1 = Router::new()
        .nest("/v1", v1)
        .layer(middleware::from_fn_with_state(
            app.clone(),
            iam::require_v1_auth,
        ));

    let authed_s3 = s3::routes().layer(middleware::from_fn_with_state(
        app.clone(),
        s3::handlers::require_s3_auth,
    ));

    Router::new()
        .merge(authed_v1)
        .merge(authed_s3)
        .route("/health", get(|| async { "ok" }))
        .route("/openapi.json", get(openapi::serve_openapi))
        .layer(CompressionLayer::new().compress_when(json_only))
        .with_state(app)
}
