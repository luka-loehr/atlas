//! Searchable text of drive files: plain text as is, PDFs through pdftotext,
//! Office documents by stripping the XML inside the container. Everything
//! else stores '' so it is not looked at again.

use std::io::Read;
use std::path::Path;
use std::process::Command;
use std::sync::LazyLock;

use anyhow::{Context, Result};
use regex::Regex;

use crate::{AppState, util};

/// Characters kept per file: plenty for search, small enough for a row.
const CAP: usize = 200_000;
/// Office members larger than this once decompressed are skipped: a crafted
/// document can hide gigabytes behind a few kilobytes.
const MAX_MEMBER: u64 = 50 << 20;

const TEXT_EXTS: &[&str] = &[
    "txt", "md", "csv", "log", "json", "xml", "html", "htm", "js", "ts", "py", "swift", "rs", "c", "cpp", "h",
    "sh", "yml", "yaml", "toml", "ini", "tex", "srt", "vtt",
];

static TAGS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"<[^>]+>").unwrap());
static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());

pub async fn run(app: &AppState, file_id: &str) -> Result<()> {
    let id: i64 = file_id.parse().context("drive_text owner is a file id")?;
    let c = app.pool.get().await?;
    let Some(row) = c.query_opt("SELECT name, hash FROM drive_files WHERE id = $1", &[&id]).await? else {
        return Ok(()); // deleted in the meantime
    };
    let (name, hash): (String, String) = (row.get(0), row.get(1));
    drop(c);
    anyhow::ensure!(util::is_content_id(&hash), "malformed blob hash");

    let blob = app.cfg.blobs_dir().join(&hash);
    let text = tokio::task::spawn_blocking(move || {
        let raw = extract(&blob, &name).unwrap_or_default();
        let collapsed = SPACES.replace_all(&raw, " ");
        collapsed.trim().chars().take(CAP).collect::<String>()
    })
    .await?;

    let c = app.pool.get().await?;
    c.execute("UPDATE drive_files SET text = $2 WHERE id = $1 AND hash = $3", &[&id, &text, &hash]).await?;
    Ok(())
}

fn extract(path: &Path, name: &str) -> Result<String> {
    let ext = util::lower_ext(name);
    Ok(match ext.as_str() {
        e if TEXT_EXTS.contains(&e) => {
            let mut buf = Vec::new();
            std::fs::File::open(path)?.take((CAP * 4) as u64).read_to_end(&mut buf)?;
            String::from_utf8_lossy(&buf).into_owned()
        }
        "pdf" => {
            let out = Command::new("pdftotext").arg(path).arg("-").output().context("pdftotext is not installed")?;
            String::from_utf8_lossy(&out.stdout).into_owned()
        }
        "docx" => office(path, |member| member == "word/document.xml")?,
        "pptx" => office(path, |member| member.starts_with("ppt/slides/slide") && member.ends_with(".xml"))?,
        "xlsx" => office(path, |member| member == "xl/sharedStrings.xml")?,
        _ => String::new(),
    })
}

/// The text of the matching XML members, tags replaced by spaces so words
/// from adjacent runs do not glue together.
fn office(path: &Path, wanted: impl Fn(&str) -> bool) -> Result<String> {
    let mut archive = zip::ZipArchive::new(std::fs::File::open(path)?)?;
    let mut members: Vec<String> = archive.file_names().filter(|n| wanted(n)).map(str::to_string).collect();
    members.sort();
    let mut out = String::new();
    for member in members {
        let mut entry = archive.by_name(&member)?;
        if entry.size() > MAX_MEMBER {
            continue;
        }
        let mut xml = String::new();
        entry.read_to_string(&mut xml)?;
        out.push_str(&TAGS.replace_all(&xml, " "));
        out.push(' ');
        if out.len() > CAP * 4 {
            break;
        }
    }
    Ok(out)
}
