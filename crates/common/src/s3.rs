//! AWS Signature Version 4 (SigV4) signing, verification, presigned URLs,
//! and `STREAMING-AWS4-HMAC-SHA256-PAYLOAD` (`aws-chunked`) decoding.

use std::collections::BTreeMap;

use chrono::{DateTime, NaiveDateTime, TimeZone, Utc};

use crate::crypto::{ct_eq, hex_decode, hex_encode, hmac_sha256, sha256_hex};
use crate::validate::{parse_query_pairs, percent_decode_utf8, uri_encode};

pub const UNSIGNED_PAYLOAD: &str = "UNSIGNED-PAYLOAD";
pub const STREAMING_SHA256_PAYLOAD: &str = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD";
pub const STREAMING_UNSIGNED_PAYLOAD_TRAILER: &str = "STREAMING-UNSIGNED-PAYLOAD-TRAILER";
pub const EMPTY_SHA256: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/// Maximum allowed clock skew for SigV4 header signatures (15 minutes).
pub const MAX_CLOCK_SKEW_SECS: i64 = 15 * 60;
/// Maximum allowed presigned URL lifetime (7 days, matching S3).
pub const MAX_PRESIGN_EXPIRES_SECS: u64 = 7 * 24 * 3600;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SigV4Error {
    MalformedAuthorization,
    MalformedCredentialScope,
    MalformedTimestamp,
    RequestExpired,
    ClockSkewed,
    MissingSignedHeader(String),
    SignatureMismatch,
    UnsupportedAlgorithm,
    ChunkFramingError,
}

impl std::fmt::Display for SigV4Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MalformedAuthorization => write!(f, "malformed AWS4-HMAC-SHA256 authorization"),
            Self::MalformedCredentialScope => write!(f, "malformed credential scope"),
            Self::MalformedTimestamp => write!(f, "malformed X-Amz-Date timestamp"),
            Self::RequestExpired => write!(f, "presigned request has expired"),
            Self::ClockSkewed => write!(f, "request timestamp outside allowed 15m window"),
            Self::MissingSignedHeader(h) => write!(f, "missing signed header: {h}"),
            Self::SignatureMismatch => write!(f, "signature does not match"),
            Self::UnsupportedAlgorithm => write!(f, "unsupported signing algorithm"),
            Self::ChunkFramingError => write!(f, "invalid aws-chunked payload framing"),
        }
    }
}

impl std::error::Error for SigV4Error {}

#[derive(Debug, Clone)]
pub struct CredentialScope {
    pub access_key_id: String,
    pub date: String,
    pub region: String,
    pub service: String,
}

#[derive(Debug, Clone)]
pub struct ParsedHeaderAuth {
    pub scope: CredentialScope,
    pub signed_headers: Vec<String>,
    pub signature: String,
}

#[derive(Debug, Clone)]
pub struct ParsedPresign {
    pub scope: CredentialScope,
    pub amz_date: String,
    pub expires_secs: u64,
    pub signed_headers: Vec<String>,
    pub signature: String,
}

pub fn parse_credential(cred: &str) -> Result<CredentialScope, SigV4Error> {
    let parts: Vec<&str> = cred.split('/').collect();
    if parts.len() != 5 || parts[4] != "aws4_request" {
        return Err(SigV4Error::MalformedCredentialScope);
    }
    if parts[0].is_empty() || parts[1].len() != 8 || parts[2].is_empty() || parts[3].is_empty() {
        return Err(SigV4Error::MalformedCredentialScope);
    }
    Ok(CredentialScope {
        access_key_id: parts[0].to_string(),
        date: parts[1].to_string(),
        region: parts[2].to_string(),
        service: parts[3].to_string(),
    })
}

/// Parses `Authorization: AWS4-HMAC-SHA256 Credential=..., SignedHeaders=..., Signature=...`.
pub fn parse_authorization_header(header_val: &str) -> Result<ParsedHeaderAuth, SigV4Error> {
    let rest = header_val
        .trim()
        .strip_prefix("AWS4-HMAC-SHA256")
        .ok_or(SigV4Error::MalformedAuthorization)?
        .trim();
    let mut credential = None;
    let mut signed_headers = None;
    let mut signature = None;

    for part in rest.split(',') {
        let part = part.trim();
        if let Some(v) = part.strip_prefix("Credential=") {
            credential = Some(parse_credential(v.trim())?);
        } else if let Some(v) = part.strip_prefix("SignedHeaders=") {
            let list: Vec<String> = v
                .trim()
                .split(';')
                .map(|s| s.trim().to_ascii_lowercase())
                .filter(|s| !s.is_empty())
                .collect();
            if list.is_empty() {
                return Err(SigV4Error::MalformedAuthorization);
            }
            signed_headers = Some(list);
        } else if let Some(v) = part.strip_prefix("Signature=") {
            let sig = v.trim();
            if sig.len() != 64 || hex_decode(sig).is_none() {
                return Err(SigV4Error::MalformedAuthorization);
            }
            signature = Some(sig.to_ascii_lowercase());
        }
    }

    Ok(ParsedHeaderAuth {
        scope: credential.ok_or(SigV4Error::MalformedAuthorization)?,
        signed_headers: signed_headers.ok_or(SigV4Error::MalformedAuthorization)?,
        signature: signature.ok_or(SigV4Error::MalformedAuthorization)?,
    })
}

/// Parses query-string presigned SigV4 parameters (`X-Amz-Algorithm=AWS4-HMAC-SHA256...`),
/// returning `None` if this query string is not a SigV4 presigned URL.
pub fn parse_presigned_query(raw_query: Option<&str>) -> Option<Result<ParsedPresign, SigV4Error>> {
    let pairs = parse_query_pairs(raw_query);
    let get_ci = |target: &str| -> Option<String> {
        pairs
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(target))
            .map(|(_, v)| v.clone())
    };
    let alg = get_ci("X-Amz-Algorithm")?;
    if alg != "AWS4-HMAC-SHA256" {
        return Some(Err(SigV4Error::UnsupportedAlgorithm));
    }
    let parse = || -> Result<ParsedPresign, SigV4Error> {
        let cred_raw = get_ci("X-Amz-Credential").ok_or(SigV4Error::MalformedAuthorization)?;
        let scope = parse_credential(&cred_raw)?;
        let amz_date = get_ci("X-Amz-Date").ok_or(SigV4Error::MalformedTimestamp)?;
        let expires_raw = get_ci("X-Amz-Expires").ok_or(SigV4Error::MalformedAuthorization)?;
        let expires_secs: u64 = expires_raw
            .parse()
            .map_err(|_| SigV4Error::MalformedAuthorization)?;
        if !(1..=MAX_PRESIGN_EXPIRES_SECS).contains(&expires_secs) {
            return Err(SigV4Error::MalformedAuthorization);
        }
        let sh_raw = get_ci("X-Amz-SignedHeaders").ok_or(SigV4Error::MalformedAuthorization)?;
        let signed_headers: Vec<String> = sh_raw
            .split(';')
            .map(|s| s.trim().to_ascii_lowercase())
            .filter(|s| !s.is_empty())
            .collect();
        if signed_headers.is_empty() {
            return Err(SigV4Error::MalformedAuthorization);
        }
        let sig = get_ci("X-Amz-Signature").ok_or(SigV4Error::MalformedAuthorization)?;
        if sig.len() != 64 || hex_decode(&sig).is_none() {
            return Err(SigV4Error::MalformedAuthorization);
        }
        Ok(ParsedPresign {
            scope,
            amz_date,
            expires_secs,
            signed_headers,
            signature: sig.to_ascii_lowercase(),
        })
    };
    Some(parse())
}

/// Parses `YYYYMMDDTHHMMSSZ` into `DateTime<Utc>`.
pub fn parse_amz_date(raw: &str) -> Result<DateTime<Utc>, SigV4Error> {
    if raw.len() != 16 || !raw.ends_with('Z') {
        return Err(SigV4Error::MalformedTimestamp);
    }
    let naive = NaiveDateTime::parse_from_str(raw, "%Y%m%dT%H%M%SZ")
        .map_err(|_| SigV4Error::MalformedTimestamp)?;
    Ok(Utc.from_utc_datetime(&naive))
}

pub fn format_amz_date(dt: DateTime<Utc>) -> String {
    dt.format("%Y%m%dT%H%M%SZ").to_string()
}

pub fn derive_signing_key(
    secret_key: &str,
    date_yyyymmdd: &str,
    region: &str,
    service: &str,
) -> [u8; 32] {
    let mut k_secret = Vec::with_capacity(4 + secret_key.len());
    k_secret.extend_from_slice(b"AWS4");
    k_secret.extend_from_slice(secret_key.as_bytes());
    let k_date = hmac_sha256(&k_secret, date_yyyymmdd.as_bytes());
    let k_region = hmac_sha256(&k_date, region.as_bytes());
    let k_service = hmac_sha256(&k_region, service.as_bytes());
    hmac_sha256(&k_service, b"aws4_request")
}

/// Canonicalizes a URI path per S3 SigV4 rules (single URI-encode of decoded segments, preserving `/`).
pub fn canonical_uri(raw_path: &str) -> String {
    if raw_path.is_empty() {
        return "/".to_string();
    }
    let decoded: Vec<String> = raw_path
        .split('/')
        .map(|seg| {
            let dec = percent_decode_utf8(seg).unwrap_or_else(|| seg.to_string());
            uri_encode(&dec, true)
        })
        .collect();
    let joined = decoded.join("/");
    if joined.starts_with('/') {
        joined
    } else {
        format!("/{joined}")
    }
}

/// Canonicalizes query string parameters (excluding `X-Amz-Signature` when `exclude_amz_sig` is true),
/// sorted lexicographically by encoded key then encoded value.
pub fn canonical_query_string(raw_query: Option<&str>, exclude_amz_sig: bool) -> String {
    let mut encoded_pairs: Vec<(String, String)> = parse_query_pairs(raw_query)
        .into_iter()
        .filter(|(k, _)| !(exclude_amz_sig && k.eq_ignore_ascii_case("X-Amz-Signature")))
        .map(|(k, v)| (uri_encode(&k, true), uri_encode(&v, true)))
        .collect();
    encoded_pairs.sort();
    encoded_pairs
        .into_iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("&")
}

fn trim_header_val(val: &str) -> String {
    let mut out = String::with_capacity(val.len());
    let mut in_space = false;
    for ch in val.trim().chars() {
        if ch == ' ' || ch == '\t' {
            if !in_space {
                out.push(' ');
                in_space = true;
            }
        } else {
            out.push(ch);
            in_space = false;
        }
    }
    out
}

/// Builds the SigV4 Canonical Request string.
pub fn canonical_request(
    method: &str,
    raw_path: &str,
    raw_query: Option<&str>,
    exclude_amz_sig_from_query: bool,
    headers_lc: &BTreeMap<String, String>,
    signed_headers: &[String],
    payload_hash: &str,
) -> Result<String, SigV4Error> {
    let mut sorted_sh = signed_headers.to_vec();
    sorted_sh.sort();
    sorted_sh.dedup();

    let mut canon_headers = String::new();
    for h in &sorted_sh {
        let val = headers_lc
            .get(h)
            .ok_or_else(|| SigV4Error::MissingSignedHeader(h.clone()))?;
        canon_headers.push_str(h);
        canon_headers.push(':');
        canon_headers.push_str(&trim_header_val(val));
        canon_headers.push('\n');
    }

    let sh_joined = sorted_sh.join(";");
    Ok(format!(
        "{}\n{}\n{}\n{}\n{}\n{}",
        method.to_ascii_uppercase(),
        canonical_uri(raw_path),
        canonical_query_string(raw_query, exclude_amz_sig_from_query),
        canon_headers,
        sh_joined,
        payload_hash
    ))
}

pub fn compute_sigv4_signature(
    secret_key: &str,
    amz_date: &str,
    scope: &CredentialScope,
    canonical_req: &str,
) -> String {
    let scope_str = format!(
        "{}/{}/{}/aws4_request",
        scope.date, scope.region, scope.service
    );
    let string_to_sign = format!(
        "AWS4-HMAC-SHA256\n{}\n{}\n{}",
        amz_date,
        scope_str,
        sha256_hex(canonical_req.as_bytes())
    );
    let signing_key = derive_signing_key(secret_key, &scope.date, &scope.region, &scope.service);
    hex_encode(&hmac_sha256(&signing_key, string_to_sign.as_bytes()))
}

/// Verifies an `Authorization: AWS4-HMAC-SHA256 ...` request at `now`.
#[allow(clippy::too_many_arguments)]
pub fn verify_header_request(
    parsed: &ParsedHeaderAuth,
    secret_key: &str,
    method: &str,
    raw_path: &str,
    raw_query: Option<&str>,
    headers_lc: &BTreeMap<String, String>,
    payload_hash: &str,
    now: DateTime<Utc>,
) -> Result<(), SigV4Error> {
    let amz_date_str = headers_lc
        .get("x-amz-date")
        .ok_or(SigV4Error::MalformedTimestamp)?;
    let req_time = parse_amz_date(amz_date_str)?;
    if !amz_date_str.starts_with(&parsed.scope.date) {
        return Err(SigV4Error::MalformedCredentialScope);
    }
    if (now - req_time).num_seconds().abs() > MAX_CLOCK_SKEW_SECS {
        return Err(SigV4Error::ClockSkewed);
    }
    let creq = canonical_request(
        method,
        raw_path,
        raw_query,
        false,
        headers_lc,
        &parsed.signed_headers,
        payload_hash,
    )?;
    let expected = compute_sigv4_signature(secret_key, amz_date_str, &parsed.scope, &creq);
    if ct_eq(expected.as_bytes(), parsed.signature.as_bytes()) {
        Ok(())
    } else {
        Err(SigV4Error::SignatureMismatch)
    }
}

/// Verifies a presigned URL (`?X-Amz-Algorithm=AWS4-HMAC-SHA256...`) at `now`.
pub fn verify_presigned_request(
    parsed: &ParsedPresign,
    secret_key: &str,
    method: &str,
    raw_path: &str,
    raw_query: Option<&str>,
    headers_lc: &BTreeMap<String, String>,
    now: DateTime<Utc>,
) -> Result<(), SigV4Error> {
    let signed_at = parse_amz_date(&parsed.amz_date)?;
    if !parsed.amz_date.starts_with(&parsed.scope.date) {
        return Err(SigV4Error::MalformedCredentialScope);
    }
    // Reject signatures from far in the future (> 15m skew)
    if (signed_at - now).num_seconds() > MAX_CLOCK_SKEW_SECS {
        return Err(SigV4Error::ClockSkewed);
    }
    let expires_at = signed_at + chrono::Duration::seconds(parsed.expires_secs as i64);
    if now > expires_at {
        return Err(SigV4Error::RequestExpired);
    }
    let creq = canonical_request(
        method,
        raw_path,
        raw_query,
        true,
        headers_lc,
        &parsed.signed_headers,
        UNSIGNED_PAYLOAD,
    )?;
    let expected = compute_sigv4_signature(secret_key, &parsed.amz_date, &parsed.scope, &creq);
    if ct_eq(expected.as_bytes(), parsed.signature.as_bytes()) {
        Ok(())
    } else {
        Err(SigV4Error::SignatureMismatch)
    }
}

/// Signs an outbound HTTP request with `AWS4-HMAC-SHA256`, returning
/// `(authorization_header, x_amz_date, x_amz_content_sha256)`.
#[allow(clippy::too_many_arguments)]
pub fn sign_request_headers(
    access_key_id: &str,
    secret_key: &str,
    region: &str,
    method: &str,
    raw_path: &str,
    raw_query: Option<&str>,
    host: &str,
    payload_hash: &str,
    now: DateTime<Utc>,
) -> (String, String, String) {
    let amz_date = format_amz_date(now);
    let date_short = amz_date[..8].to_string();
    let scope = CredentialScope {
        access_key_id: access_key_id.to_string(),
        date: date_short.clone(),
        region: region.to_string(),
        service: "s3".to_string(),
    };
    let mut headers = BTreeMap::new();
    headers.insert("host".to_string(), host.to_string());
    headers.insert("x-amz-content-sha256".to_string(), payload_hash.to_string());
    headers.insert("x-amz-date".to_string(), amz_date.clone());
    let signed_headers = vec![
        "host".to_string(),
        "x-amz-content-sha256".to_string(),
        "x-amz-date".to_string(),
    ];
    let creq = canonical_request(
        method,
        raw_path,
        raw_query,
        false,
        &headers,
        &signed_headers,
        payload_hash,
    )
    .expect("fixed headers present");
    let sig = compute_sigv4_signature(secret_key, &amz_date, &scope, &creq);
    let auth = format!(
        "AWS4-HMAC-SHA256 Credential={access_key_id}/{date_short}/{region}/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={sig}"
    );
    (auth, amz_date, payload_hash.to_string())
}

/// Generates a SigV4 presigned URL for `base_url` (e.g. `http://host:8787`) and `raw_path` (e.g. `/s3/files/report.pdf`).
#[allow(clippy::too_many_arguments)]
pub fn presign_url(
    base_url: &str,
    raw_path: &str,
    method: &str,
    access_key_id: &str,
    secret_key: &str,
    region: &str,
    expires_secs: u64,
    now: DateTime<Utc>,
) -> Result<String, SigV4Error> {
    if !(1..=MAX_PRESIGN_EXPIRES_SECS).contains(&expires_secs) {
        return Err(SigV4Error::MalformedAuthorization);
    }
    let trimmed = base_url.trim_end_matches('/');
    let after_scheme = trimmed
        .strip_prefix("https://")
        .or_else(|| trimmed.strip_prefix("http://"))
        .unwrap_or(trimmed);
    let host = after_scheme.split('/').next().unwrap_or(after_scheme);

    let amz_date = format_amz_date(now);
    let date_short = &amz_date[..8];
    let cred = format!("{access_key_id}/{date_short}/{region}/s3/aws4_request");
    let query = format!(
        "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential={}&X-Amz-Date={}&X-Amz-Expires={}&X-Amz-SignedHeaders=host",
        uri_encode(&cred, true),
        amz_date,
        expires_secs
    );
    let scope = CredentialScope {
        access_key_id: access_key_id.to_string(),
        date: date_short.to_string(),
        region: region.to_string(),
        service: "s3".to_string(),
    };
    let mut headers = BTreeMap::new();
    headers.insert("host".to_string(), host.to_string());
    let signed_headers = vec!["host".to_string()];
    let path = if raw_path.starts_with('/') {
        raw_path.to_string()
    } else {
        format!("/{raw_path}")
    };
    let creq = canonical_request(
        method,
        &path,
        Some(&query),
        true,
        &headers,
        &signed_headers,
        UNSIGNED_PAYLOAD,
    )?;
    let sig = compute_sigv4_signature(secret_key, &amz_date, &scope, &creq);
    Ok(format!("{trimmed}{path}?{query}&X-Amz-Signature={sig}"))
}

/// Decodes an `aws-chunked` body (`<hex-size>[;chunk-signature=...]\r\n<bytes>\r\n...0...\r\n\r\n`).
/// Used when SDKs upload with `x-amz-content-sha256: STREAMING-AWS4-HMAC-SHA256-PAYLOAD`.
pub fn decode_aws_chunked_bytes(input: &[u8]) -> Result<Vec<u8>, SigV4Error> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < input.len() {
        let rel_end = input[pos..]
            .windows(2)
            .position(|w| w == b"\r\n")
            .ok_or(SigV4Error::ChunkFramingError)?;
        let header_line = std::str::from_utf8(&input[pos..pos + rel_end])
            .map_err(|_| SigV4Error::ChunkFramingError)?;
        let size_hex = header_line.split(';').next().unwrap_or("").trim();
        let chunk_size =
            usize::from_str_radix(size_hex, 16).map_err(|_| SigV4Error::ChunkFramingError)?;
        pos += rel_end + 2;
        if chunk_size == 0 {
            return Ok(out);
        }
        if pos + chunk_size + 2 > input.len() {
            return Err(SigV4Error::ChunkFramingError);
        }
        out.extend_from_slice(&input[pos..pos + chunk_size]);
        if &input[pos + chunk_size..pos + chunk_size + 2] != b"\r\n" {
            return Err(SigV4Error::ChunkFramingError);
        }
        pos += chunk_size + 2;
    }
    Err(SigV4Error::ChunkFramingError)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_sign_and_verify_roundtrip() {
        let now = Utc.with_ymd_and_hms(2026, 11, 27, 1, 0, 0).unwrap();
        let ak = "ATLK23456789ABCDEFGHJKLM";
        let sk = "atls_test_secret_key_for_sigv4_verification";
        let (auth, amz_date, sha) = sign_request_headers(
            ak,
            sk,
            "us-east-1",
            "PUT",
            "/s3/files/docs/Familienversicherung%202026.pdf",
            Some("partNumber=1&uploadId=u1"),
            "127.0.0.1:8787",
            EMPTY_SHA256,
            now,
        );
        let parsed = parse_authorization_header(&auth).unwrap();
        let mut headers = BTreeMap::new();
        headers.insert("host".into(), "127.0.0.1:8787".into());
        headers.insert("x-amz-date".into(), amz_date);
        headers.insert("x-amz-content-sha256".into(), sha.clone());

        verify_header_request(
            &parsed,
            sk,
            "PUT",
            "/s3/files/docs/Familienversicherung%202026.pdf",
            Some("partNumber=1&uploadId=u1"),
            &headers,
            &sha,
            now,
        )
        .unwrap();

        // Wrong secret fails
        assert_eq!(
            verify_header_request(
                &parsed,
                "wrong",
                "PUT",
                "/s3/files/docs/Familienversicherung%202026.pdf",
                Some("partNumber=1&uploadId=u1"),
                &headers,
                &sha,
                now,
            ),
            Err(SigV4Error::SignatureMismatch)
        );
    }

    #[test]
    fn presign_and_verify_roundtrip_and_expiry() {
        let now = Utc.with_ymd_and_hms(2026, 11, 27, 1, 0, 0).unwrap();
        let ak = "ATLK23456789ABCDEFGHJKLM";
        let sk = "atls_test_secret_key_for_presign";
        let url = presign_url(
            "http://127.0.0.1:8787",
            "/s3/files/invoices/inv-01.pdf",
            "GET",
            ak,
            sk,
            "us-east-1",
            300,
            now,
        )
        .unwrap();
        let (_, query) = url.split_once('?').unwrap();
        let parsed = parse_presigned_query(Some(query)).unwrap().unwrap();
        let mut headers = BTreeMap::new();
        headers.insert("host".into(), "127.0.0.1:8787".into());

        verify_presigned_request(
            &parsed,
            sk,
            "GET",
            "/s3/files/invoices/inv-01.pdf",
            Some(query),
            &headers,
            now + chrono::Duration::seconds(299),
        )
        .unwrap();

        assert_eq!(
            verify_presigned_request(
                &parsed,
                sk,
                "GET",
                "/s3/files/invoices/inv-01.pdf",
                Some(query),
                &headers,
                now + chrono::Duration::seconds(301),
            ),
            Err(SigV4Error::RequestExpired)
        );
    }

    #[test]
    fn decodes_aws_chunked_payload() {
        let framed = b"5;chunk-signature=aaaa\r\nhello\r\n6;chunk-signature=bbbb\r\n world\r\n0;chunk-signature=cccc\r\n\r\n";
        assert_eq!(decode_aws_chunked_bytes(framed).unwrap(), b"hello world");
    }
}
