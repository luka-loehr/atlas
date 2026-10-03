//! Small helpers shared across the API areas.

use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

pub const VIDEO_EXTS: &[&str] = &["mp4", "mov", "m4v", "3gp", "avi", "mkv", "webm", "mts"];
pub const IMAGE_EXTS: &[&str] =
    &["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tif", "tiff", "dng", "avif"];

/// A content id: lowercase-hex SHA-256, nothing else. Ids go into paths.
pub fn is_content_id(id: &str) -> bool {
    id.len() == 64 && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(DIGITS[(b >> 4) as usize] as char);
        s.push(DIGITS[(b & 15) as usize] as char);
    }
    s
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

/// A short strong validator for a response body.
pub fn etag(bytes: &[u8]) -> String {
    format!("\"{}\"", &sha256_hex(bytes)[..20])
}

pub fn lower_ext(name: &str) -> String {
    Path::new(name).extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase()
}

/// The extension an upload is stored under: a known media type or "bin".
/// Never the client's own choice, so nothing script-capable (.html, .svg)
/// can be planted for the file server to hand back with an active type.
pub fn media_ext(name: &str) -> &'static str {
    let ext = lower_ext(name);
    IMAGE_EXTS.iter().chain(VIDEO_EXTS).find(|known| **known == ext).copied().unwrap_or("bin")
}

pub fn is_video_ext(ext: &str) -> bool {
    VIDEO_EXTS.contains(&ext)
}

/// Escape LIKE metacharacters so user input matches literally.
pub fn like_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
}

/// Escape POSIX-regex metacharacters so user input matches literally.
pub fn regex_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        if "\\^$.[]|()*+?{}-".contains(ch) {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

/// The last path component of a client-supplied name, percent-decoded.
pub fn client_filename(raw: Option<&str>) -> String {
    raw.map(percent_decode)
        .and_then(|s| s.rsplit(['/', '\\']).next().map(str::to_string))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && s != "." && s != "..")
        .unwrap_or_else(|| "upload".into())
}

/// Header values are latin-1 on the wire, so clients percent-encode names.
pub fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && let (Some(h), Some(l)) = (
                bytes.get(i + 1).and_then(|b| (*b as char).to_digit(16)),
                bytes.get(i + 2).and_then(|b| (*b as char).to_digit(16)),
            )
        {
            out.push((h * 16 + l) as u8);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Canonicalize `p` and require it to live under `root`: a symlink or a
/// tampered path column cannot lead outside the library.
pub async fn confine(root: &Path, p: &Path) -> Option<PathBuf> {
    let canon = tokio::fs::canonicalize(p).await.ok()?;
    let root = tokio::fs::canonicalize(root).await.ok()?;
    canon.starts_with(&root).then_some(canon)
}

/// A name for a temporary file that no concurrent writer shares.
pub fn temp_name(prefix: &str) -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{prefix}-{}-{nanos}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_ids_are_strict() {
        assert!(is_content_id(&"a1".repeat(32)));
        assert!(!is_content_id(&"A1".repeat(32)));
        assert!(!is_content_id("../etc/passwd"));
        assert!(!is_content_id(&"a".repeat(63)));
    }

    #[test]
    fn uploads_never_keep_a_script_extension() {
        assert_eq!(media_ext("IMG_0001.HEIC"), "heic");
        assert_eq!(media_ext("clip.MOV"), "mov");
        assert_eq!(media_ext("page.html"), "bin");
        assert_eq!(media_ext("logo.svg"), "bin");
        assert_eq!(media_ext("noext"), "bin");
    }

    #[test]
    fn client_filenames_lose_their_directories() {
        assert_eq!(client_filename(Some("../../etc/passwd")), "passwd");
        assert_eq!(client_filename(Some("Urlaub%20%C3%96sterreich.pdf")), "Urlaub Österreich.pdf");
        assert_eq!(client_filename(Some("..")), "upload");
        assert_eq!(client_filename(None), "upload");
    }
}
