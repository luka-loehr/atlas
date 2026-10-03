//! One error type for every handler. Details are logged, never sent: paths,
//! SQL and pool errors stay on the server.

use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};

pub enum ApiError {
    NotFound,
    BadRequest(&'static str),
    Unauthorized,
    Unavailable(&'static str),
    TooLarge,
    Internal(anyhow::Error),
}

pub type ApiResult<T> = Result<T, ApiError>;

impl<E: Into<anyhow::Error>> From<E> for ApiError {
    fn from(e: E) -> Self {
        ApiError::Internal(e.into())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            ApiError::NotFound => (StatusCode::NOT_FOUND, "not found"),
            ApiError::BadRequest(m) => (StatusCode::BAD_REQUEST, m),
            ApiError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            ApiError::Unavailable(m) => (StatusCode::SERVICE_UNAVAILABLE, m),
            ApiError::TooLarge => (StatusCode::PAYLOAD_TOO_LARGE, "upload too large"),
            ApiError::Internal(e) => {
                tracing::error!("internal error: {e:#}");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error")
            }
        };
        (status, Json(serde_json::json!({ "error": message }))).into_response()
    }
}
