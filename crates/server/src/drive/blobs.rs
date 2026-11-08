//! The bytes: content-addressed blobs served by hash, their previews, and
//! removing blobs nothing references any more.

use axum::extract::{Path, State};
use axum::http::{HeaderMap, HeaderValue, header};
use axum::response::{IntoResponse, Response};

use super::blob_path;
use crate::{ApiError, ApiResult, App, AppState, imaging, media, util};

/// Content type from the display name: the blob path itself has no extension.
pub fn mime_for(name: &str) -> &'static str {
    match util::lower_ext(name).as_str() {
        "pdf" => "application/pdf",
        "txt" | "md" | "log" => "text/plain; charset=utf-8",
        "html" | "htm" => "text/html; charset=utf-8",
        "csv" => "text/csv",
        "json" => "application/json",
        "xml" => "application/xml",
        "zip" => "application/zip",
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "heic" => "image/heic",
        "svg" => "image/svg+xml",
        "mp3" => "audio/mpeg",
        "m4a" | "aac" => "audio/mp4",
        "wav" => "audio/wav",
        "ogg" | "oga" => "audio/ogg",
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        "webm" => "video/webm",
        "doc" => "application/msword",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" => "application/vnd.ms-excel",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" => "application/vnd.ms-powerpoint",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        _ => "application/octet-stream",
    }
}

/// Types a browser may render inline. Everything that can run script on
/// this origin (HTML, SVG, XML) is forced to download instead.
fn inline_safe(mime: &str) -> bool {
    (mime.starts_with("image/") && mime != "image/svg+xml")
        || mime.starts_with("video/")
        || mime.starts_with("audio/")
        || matches!(
            mime,
            "application/pdf" | "text/plain; charset=utf-8" | "text/csv" | "application/json"
        )
}

/// The name in the URL only decides the content type and the download name;
/// the content is addressed by hash alone.
pub(super) async fn blob(
    State(app): State<AppState>,
    Path((hash, name)): Path<(String, String)>,
    headers: HeaderMap,
) -> Response {
    if !util::is_content_id(&hash) {
        return ApiError::NotFound.into_response();
    }
    let mut resp = media::immutable_file(blob_path(&app, &hash), headers).await;
    if !resp.status().is_success() {
        return resp;
    }
    let mime = mime_for(&name);
    resp.headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static(mime));
    let disposition = if inline_safe(mime) {
        "inline"
    } else {
        "attachment"
    };
    // RFC 5987 filename* keeps umlauts; the plain one is the ASCII fallback
    let ascii: String = name
        .chars()
        .map(|ch| {
            if ch.is_ascii() && ch != '"' && ch != '\\' {
                ch
            } else {
                '_'
            }
        })
        .collect();
    let encoded: String = name
        .bytes()
        .map(|b| match b {
            b'0'..=b'9' | b'a'..=b'z' | b'A'..=b'Z' | b'.' | b'-' | b'_' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect();
    if let Ok(v) = HeaderValue::from_str(&format!(
        "{disposition}; filename=\"{ascii}\"; filename*=UTF-8''{encoded}"
    )) {
        resp.headers_mut().insert(header::CONTENT_DISPOSITION, v);
    }
    resp
}

/// A 512px WebP of an image or of a PDF's first page, made on first request
/// and kept next to the blobs. Keyed by content, so it is immutable.
pub(super) async fn thumb(
    State(app): State<AppState>,
    Path(id): Path<i64>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    let c = app.pool.get().await?;
    let row = c
        .query_opt("SELECT hash, name FROM drive_files WHERE id = $1", &[&id])
        .await?
        .ok_or(ApiError::NotFound)?;
    drop(c);
    let (hash, name): (String, String) = (row.get(0), row.get(1));
    if !util::is_content_id(&hash) {
        return Err(ApiError::NotFound);
    }
    let dest = app.cfg.drive_thumbs_dir().join(format!("{hash}.webp"));
    if !tokio::fs::try_exists(&dest).await.unwrap_or(false) {
        let source = blob_path(&app, &hash);
        let ext = util::lower_ext(&name);
        let out = dest.clone();
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let decoded = if ext == "pdf" {
                imaging::decode_bytes(&first_pdf_page(&source)?)?
            } else if util::IMAGE_EXTS.contains(&ext.as_str()) {
                imaging::decode(&source)?
            } else {
                anyhow::bail!("no preview for .{ext}");
            };
            let small = imaging::fit(&decoded.rgb, imaging::GRID)?;
            imaging::write_atomic(
                &out,
                &imaging::encode_webp(&small, 80.0, decoded.icc.as_deref()),
            )
        })
        .await?
        .map_err(|_| ApiError::NotFound)?;
    }
    Ok(media::immutable_file(dest, headers).await)
}

fn first_pdf_page(pdf: &std::path::Path) -> anyhow::Result<Vec<u8>> {
    let out = atlas_core::process::output(
        std::process::Command::new("pdftoppm")
            .args([
                "-png",
                "-singlefile",
                "-f",
                "1",
                "-l",
                "1",
                "-scale-to",
                "1024",
            ])
            .arg(pdf), // no output root: the page goes to stdout
        std::time::Duration::from_secs(60),
    )?;
    anyhow::ensure!(
        out.status.success() && !out.stdout.is_empty(),
        "pdftoppm failed"
    );
    Ok(out.stdout)
}

/// Remove blobs (and their previews) that no row references any more.
pub(super) async fn collect_blobs(app: &App, hashes: &[String]) -> ApiResult<()> {
    if hashes.is_empty() {
        return Ok(());
    }
    let c = app.pool.get().await?;
    let referenced: Vec<String> = c
        .query(
            "SELECT DISTINCT hash FROM drive_files WHERE hash = ANY($1)",
            &[&hashes],
        )
        .await?
        .iter()
        .map(|r| r.get(0))
        .collect();
    for hash in hashes
        .iter()
        .filter(|h| !referenced.contains(h) && util::is_content_id(h))
    {
        let _ = tokio::fs::remove_file(blob_path(app, hash)).await;
        let _ =
            tokio::fs::remove_file(app.cfg.drive_thumbs_dir().join(format!("{hash}.webp"))).await;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn script_capable_types_never_render_inline() {
        assert!(inline_safe(mime_for("scan.pdf")));
        assert!(inline_safe(mime_for("photo.JPG")));
        assert!(!inline_safe(mime_for("page.html")));
        assert!(!inline_safe(mime_for("logo.svg")));
        assert!(!inline_safe(mime_for("feed.xml")));
    }
}
