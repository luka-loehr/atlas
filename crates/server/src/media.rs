//! Serving files and JSON the way a media service should: content-addressed
//! files are immutable and Range-capable, JSON bodies carry a validator so an
//! unchanged list costs one 304.

use std::path::PathBuf;

use axum::body::Body;
use axum::http::{HeaderMap, HeaderValue, Request, StatusCode, header};
use axum::response::{IntoResponse, Response};
use bytes::Bytes;
use serde::Serialize;
use tower::ServiceExt;
use tower_http::services::ServeFile;

use crate::util;

const IMMUTABLE: HeaderValue = HeaderValue::from_static("private, max-age=31536000, immutable");

/// A file whose URL names its content: cache forever, never sniff the type.
/// ServeFile answers Range and conditional requests.
pub async fn immutable_file(path: PathBuf, headers: HeaderMap) -> Response {
    let mut req = Request::new(Body::empty());
    *req.headers_mut() = headers;
    match ServeFile::new(path).oneshot(req).await {
        Ok(mut resp) if resp.status() != StatusCode::NOT_FOUND => {
            resp.headers_mut().insert(header::CACHE_CONTROL, IMMUTABLE);
            resp.headers_mut().insert(header::X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
            resp.into_response()
        }
        _ => StatusCode::NOT_FOUND.into_response(),
    }
}

/// Serialize once, hash the bytes, and answer 304 when the client already
/// holds exactly this body.
pub fn json_validated<T: Serialize>(headers: &HeaderMap, value: &T) -> Response {
    match serde_json::to_vec(value) {
        Ok(body) => {
            let etag = util::etag(&body);
            validated(headers, &etag, || Bytes::from(body), false)
        }
        Err(e) => crate::ApiError::from(e).into_response(),
    }
}

/// `body` is only produced when the validator did not match.
pub fn validated(headers: &HeaderMap, etag: &str, body: impl FnOnce() -> Bytes, gzipped: bool) -> Response {
    let matches = headers
        .get(header::IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.split(',').any(|candidate| candidate.trim() == etag));
    let mut resp = if matches {
        StatusCode::NOT_MODIFIED.into_response()
    } else {
        let mut resp = body().into_response();
        resp.headers_mut().insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
        if gzipped {
            resp.headers_mut().insert(header::CONTENT_ENCODING, HeaderValue::from_static("gzip"));
        }
        resp
    };
    if let Ok(v) = HeaderValue::from_str(etag) {
        resp.headers_mut().insert(header::ETAG, v);
    }
    // revalidate every time: the answer is a cheap 304 when nothing changed
    resp.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("private, no-cache"));
    resp
}

pub fn accepts_gzip(headers: &HeaderMap) -> bool {
    headers
        .get(header::ACCEPT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.contains("gzip"))
}
