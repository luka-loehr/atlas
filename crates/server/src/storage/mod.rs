//! Unified S3-compatible bucket & content-addressed object storage engine.

pub mod bridge;
pub mod buckets;
pub mod handlers;
pub mod multipart;
pub mod objects;

use axum::Router;
use axum::routing::{get, post};

use crate::AppState;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/buckets",
            get(handlers::list_buckets).post(handlers::create_bucket),
        )
        .route(
            "/buckets/{bucket}",
            get(handlers::get_bucket).delete(handlers::delete_bucket),
        )
        .route("/buckets/{bucket}/objects", get(handlers::list_objects))
        .route(
            "/buckets/{bucket}/objects/{*key}",
            get(handlers::get_object)
                .put(handlers::put_object)
                .head(handlers::head_object)
                .delete(handlers::delete_object),
        )
        .route("/buckets/{bucket}/stat/{*key}", get(handlers::stat_object))
        .route("/buckets/{bucket}/copy", post(handlers::copy_object))
        .route("/buckets/{bucket}/delete", post(handlers::batch_delete))
        .route("/buckets/{bucket}/presign", post(handlers::presign))
}
