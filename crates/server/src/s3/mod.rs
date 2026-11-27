//! S3-compatible wire protocol router (`/s3` and `/s3/{bucket}/{*key}`).

pub mod handlers;
pub mod xml;

use axum::Router;
use axum::routing::get;

use crate::AppState;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/s3", get(handlers::list_buckets))
        .route("/s3/", get(handlers::list_buckets))
        .route(
            "/s3/{bucket}",
            get(handlers::get_bucket)
                .put(handlers::create_bucket)
                .delete(handlers::delete_bucket)
                .head(handlers::head_bucket)
                .post(handlers::post_bucket),
        )
        .route(
            "/s3/{bucket}/",
            get(handlers::get_bucket)
                .put(handlers::create_bucket)
                .delete(handlers::delete_bucket)
                .head(handlers::head_bucket)
                .post(handlers::post_bucket),
        )
        .route(
            "/s3/{bucket}/{*key}",
            get(handlers::get_object)
                .put(handlers::put_object)
                .head(handlers::head_object)
                .post(handlers::post_object)
                .delete(handlers::delete_object),
        )
}
