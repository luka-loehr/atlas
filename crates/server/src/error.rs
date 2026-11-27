//! One error type for every handler. Details are logged, never sent: paths,
//! SQL and pool errors stay on the server.

use axum::Json;
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};

pub enum ApiError {
    NotFound,
    BadRequest(&'static str),
    Unauthorized,
    Forbidden(&'static str),
    Conflict(&'static str),
    RateLimited { retry_after: u64, limit: u32 },
    Unavailable(&'static str),
    TooLarge,
    Internal(anyhow::Error),
}

pub type ApiResult<T> = Result<T, ApiError>;

impl ApiError {
    /// One line for the log.
    pub fn message(&self) -> String {
        match self {
            ApiError::NotFound => "not found".into(),
            ApiError::BadRequest(m)
            | ApiError::Forbidden(m)
            | ApiError::Conflict(m)
            | ApiError::Unavailable(m) => (*m).into(),
            ApiError::Unauthorized => "unauthorized".into(),
            ApiError::RateLimited { retry_after, .. } => {
                format!("rate limit exceeded (retry after {retry_after}s)")
            }
            ApiError::TooLarge => "too large".into(),
            ApiError::Internal(e) => format!("{e:#}"),
        }
    }
}

impl<E: Into<anyhow::Error>> From<E> for ApiError {
    fn from(e: E) -> Self {
        ApiError::Internal(e.into())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut retry_headers: Option<(u64, u32)> = None;
        let (status, message) = match self {
            ApiError::NotFound => (StatusCode::NOT_FOUND, "not found"),
            ApiError::BadRequest(m) => (StatusCode::BAD_REQUEST, m),
            ApiError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            ApiError::Forbidden(m) => (StatusCode::FORBIDDEN, m),
            ApiError::Conflict(m) => (StatusCode::CONFLICT, m),
            ApiError::RateLimited { retry_after, limit } => {
                retry_headers = Some((retry_after.max(1), limit));
                (StatusCode::TOO_MANY_REQUESTS, "rate limit exceeded")
            }
            ApiError::Unavailable(m) => (StatusCode::SERVICE_UNAVAILABLE, m),
            ApiError::TooLarge => (StatusCode::PAYLOAD_TOO_LARGE, "upload too large"),
            ApiError::Internal(e) => {
                tracing::error!("internal error: {e:#}");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error")
            }
        };
        let mut resp = (status, Json(serde_json::json!({ "error": message }))).into_response();
        if let Some((retry_after, limit)) = retry_headers {
            if let Ok(v) = HeaderValue::from_str(&retry_after.to_string()) {
                resp.headers_mut().insert(header::RETRY_AFTER, v);
            }
            if let Ok(v) = HeaderValue::from_str(&limit.to_string()) {
                resp.headers_mut().insert("x-ratelimit-limit", v);
            }
            resp.headers_mut()
                .insert("x-ratelimit-remaining", HeaderValue::from_static("0"));
        }
        resp
    }
}
