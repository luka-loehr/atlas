//! Validation and canonicalization rules for buckets, object keys, content IDs,
//! and RFC 3986 URI encoding.

/// S3-compatible bucket naming rules:
/// - 3..=63 characters
/// - lowercase ASCII letters, digits, and hyphens
/// - must begin and end with a letter or digit
/// - must not look like an IPv4 address or contain consecutive hyphens (`--` is allowed in S3 except `sthree-`/`xn--`, we allow single hyphens cleanly and reject `..`)
pub fn is_valid_bucket_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    if !(3..=63).contains(&bytes.len()) {
        return false;
    }
    let is_alnum = |b: u8| b.is_ascii_lowercase() || b.is_ascii_digit();
    if !is_alnum(bytes[0]) || !is_alnum(bytes[bytes.len() - 1]) {
        return false;
    }
    if !bytes.iter().all(|&b| is_alnum(b) || b == b'-' || b == b'.') {
        return false;
    }
    if name.contains("..") || name.contains(".-") || name.contains("-.") {
        return false;
    }
    // Reject bare IPv4-shaped names like 192.168.1.1
    let parts: Vec<&str> = name.split('.').collect();
    !(parts.len() == 4
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.len() <= 3 && p.bytes().all(|b| b.is_ascii_digit())))
}

/// Normalizes and validates an S3 object key:
/// - Strips leading `/` characters (S3 path-style URLs often start with `/`).
/// - Allows trailing `/` ONLY for zero-byte folder marker objects if desired, or preserves clean keys up to 1024 UTF-8 bytes.
/// - Rejects empty keys, NUL/control characters (`< 0x20` or `0x7F`), backslashes, and `.` / `..` traversal segments.
pub fn normalize_object_key(raw: &str) -> Option<String> {
    let trimmed = raw.trim_start_matches('/');
    if trimmed.is_empty() || trimmed.len() > 1024 {
        return None;
    }
    if trimmed.bytes().any(|b| b < 0x20 || b == 0x7f || b == b'\\') {
        return None;
    }
    for seg in trimmed.split('/') {
        if seg == "." || seg == ".." {
            return None;
        }
    }
    // Collapse accidental double slashes (`a//b` -> `a/b`) while preserving trailing slash if folder marker
    let trailing_slash = trimmed.ends_with('/');
    let mut parts: Vec<&str> = trimmed.split('/').filter(|s| !s.is_empty()).collect();
    if parts.is_empty() {
        return None;
    }
    let mut out = parts.join("/");
    parts.clear();
    if trailing_slash {
        out.push('/');
    }
    Some(out)
}

/// Lowercase 64-character SHA-256 hex digest.
pub fn is_content_id(id: &str) -> bool {
    id.len() == 64
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// AWS SigV4 RFC 3986 URI encoding: unreserved characters `A-Z a-z 0-9 - _ . ~`
/// are kept literally; `/` is kept when `encode_slash` is `false`.
pub fn uri_encode(input: &str, encode_slash: bool) -> String {
    const HEX_UPPER: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(input.len() + 16);
    for &b in input.as_bytes() {
        let unreserved = b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~');
        if unreserved || (!encode_slash && b == b'/') {
            out.push(b as char);
        } else {
            out.push('%');
            out.push(HEX_UPPER[(b >> 4) as usize] as char);
            out.push(HEX_UPPER[(b & 0x0f) as usize] as char);
        }
    }
    out
}

/// Percent-decodes a URI component into UTF-8 (invalid UTF-8 returns `None`).
pub fn percent_decode_utf8(input: &str) -> Option<String> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hi = (*bytes.get(i + 1)? as char).to_digit(16)?;
            let lo = (*bytes.get(i + 2)? as char).to_digit(16)?;
            out.push(((hi << 4) | lo) as u8);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// Decodes query string `a=1&b=2` (preserving `+` as literal `+` per S3 RFC 3986 rules,
/// or `%20` as space) into `(decoded_key, decoded_value)` pairs.
pub fn parse_query_pairs(raw_query: Option<&str>) -> Vec<(String, String)> {
    let Some(q) = raw_query else {
        return Vec::new();
    };
    if q.is_empty() {
        return Vec::new();
    }
    q.split('&')
        .filter(|part| !part.is_empty())
        .filter_map(|part| {
            let (k, v) = match part.split_once('=') {
                Some((k, v)) => (k, v),
                None => (part, ""),
            };
            Some((percent_decode_utf8(k)?, percent_decode_utf8(v)?))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bucket_names_follow_s3_rules() {
        assert!(is_valid_bucket_name("media"));
        assert!(is_valid_bucket_name("files"));
        assert!(is_valid_bucket_name("shared-docs-2026"));
        assert!(!is_valid_bucket_name("ab"));
        assert!(!is_valid_bucket_name("Media"));
        assert!(!is_valid_bucket_name("-bad"));
        assert!(!is_valid_bucket_name("bad-"));
        assert!(!is_valid_bucket_name("192.168.1.1"));
        assert!(!is_valid_bucket_name("a..b"));
    }

    #[test]
    fn object_keys_reject_traversal_and_normalize_slashes() {
        assert_eq!(
            normalize_object_key("/invoices/2026/Familienversicherung.pdf").as_deref(),
            Some("invoices/2026/Familienversicherung.pdf")
        );
        assert_eq!(
            normalize_object_key("docs//nested/report.txt").as_deref(),
            Some("docs/nested/report.txt")
        );
        assert_eq!(normalize_object_key("../etc/passwd"), None);
        assert_eq!(normalize_object_key("a/../../b"), None);
        assert_eq!(normalize_object_key("a/./b"), None);
        assert_eq!(normalize_object_key(""), None);
        assert_eq!(normalize_object_key("/"), None);
        assert_eq!(normalize_object_key("bad\0key"), None);
    }

    #[test]
    fn uri_encode_matches_sigv4_rules() {
        assert_eq!(uri_encode("a/b c+d~1.pdf", false), "a/b%20c%2Bd~1.pdf");
        assert_eq!(uri_encode("a/b c+d~1.pdf", true), "a%2Fb%20c%2Bd~1.pdf");
    }
}
