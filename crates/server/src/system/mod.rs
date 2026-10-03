//! The machine itself: what it is doing, what runs on it, and a way in.
//!
//!   GET  /v1/system                    snapshot: load, memory, GPU, disks, power
//!   GET  /v1/system/live               WebSocket: 10 min of history, then 2 Hz
//!   GET  /v1/system/services           Atlas services, database, job queue
//!   GET  /v1/system/containers         Docker containers
//!   GET  /v1/system/containers/{name}  one container with its recent logs
//!   GET  /v1/system/network            the tailnet: this node and its peers
//!   GET  /v1/system/activity           uptime, boots and commits per day
//!   GET  /v1/system/terminal           WebSocket: a login shell on a PTY
//!   POST /v1/system/power/{action}     shutdown | restart

pub mod host;
pub mod metrics;
pub mod terminal;

use axum::Router;
use axum::routing::{get, post};

use crate::AppState;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/system", get(metrics::snapshot))
        .route("/system/live", get(metrics::live))
        .route("/system/services", get(host::services))
        .route("/system/containers", get(host::containers))
        .route("/system/containers/{name}", get(host::container))
        .route("/system/network", get(host::network))
        .route("/system/activity", get(host::activity))
        .route("/system/terminal", get(terminal::terminal))
        .route("/system/power/{action}", post(host::power))
}
