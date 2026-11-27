//! Legacy bearer-token check helpers retained for unit tests; live `/v1` and `/s3`
//! routing now authenticates through [`crate::iam`].

use axum::extract::Request;
use axum::http::header;

pub fn presents_token(req: &Request, expected: &str) -> bool {
    let from_header = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .is_some_and(|t| ct_eq(t.trim().as_bytes(), expected.as_bytes()));
    // compared raw, never percent-decoded: tokens are URL-safe by convention
    from_header
        || req.uri().query().is_some_and(|q| {
            q.split('&')
                .filter_map(|kv| kv.strip_prefix("token="))
                .any(|t| ct_eq(t.as_bytes(), expected.as_bytes()))
        })
}

/// Constant-time comparison, so the token cannot be probed byte by byte
/// through response timing.
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;

    fn request(uri: &str, bearer: Option<&str>) -> Request {
        let mut b = Request::builder().uri(uri);
        if let Some(t) = bearer {
            b = b.header(header::AUTHORIZATION, format!("Bearer {t}"));
        }
        b.body(Body::empty()).unwrap()
    }

    #[test]
    fn accepts_the_token_in_header_or_query() {
        assert!(presents_token(
            &request("/v1/stats", Some("sesame")),
            "sesame"
        ));
        assert!(presents_token(
            &request("/v1/a?x=1&token=sesame", None),
            "sesame"
        ));
    }

    #[test]
    fn rejects_everything_else() {
        assert!(!presents_token(&request("/v1/stats", None), "sesame"));
        assert!(!presents_token(
            &request("/v1/stats", Some("sesam")),
            "sesame"
        ));
        assert!(!presents_token(
            &request("/v1/stats?token=", None),
            "sesame"
        ));
        assert!(!presents_token(
            &request("/v1/stats?tokens=sesame", None),
            "sesame"
        ));
    }
}
