//! The link preview of a share: the first item's large thumbnail (a video's
//! poster frame) with the title and a line about what is shared over it
//! (rendered by og.rs).

use anyhow::{Context, Result};
use chrono::DateTime;
use serde_json::Value;

use super::og;
use crate::{App, imaging};

/// The link preview (og.rs): the first item's large thumbnail (a video's
/// poster frame) with the title over it. A password share's shows no photo.
pub(super) async fn preview(
    app: &App,
    title: &str,
    items: &[Value],
    locked: bool,
) -> Result<Vec<u8>> {
    let first = items
        .first()
        .and_then(|i| i["id"].as_str())
        .context("no items")?;
    let photo = app.cfg.thumb_path(first, imaging::SCREEN);
    let title = if title.trim().is_empty() {
        "Shared photos".to_string()
    } else {
        title.to_string()
    };
    let meta = if locked {
        vec!["Password protected".to_string()]
    } else {
        preview_meta(items)
    };
    tokio::task::spawn_blocking(move || {
        let photo = if locked {
            None
        } else {
            Some(imaging::decode(&photo)?)
        };
        og::render(&og::Card {
            title: &title,
            meta: &meta,
            photo: photo.as_ref(),
        })
    })
    .await?
}

/// "48 photos" and "Oct 1 – 3, 2026", worded as on the share page.
fn preview_meta(items: &[Value]) -> Vec<String> {
    let videos = items.iter().filter(|i| i["kind"] == "video").count();
    let photos = items.len() - videos;
    let part =
        |n: usize, one: &str| format!("{} {one}{}", thousands(n), if n == 1 { "" } else { "s" });
    let count = match (photos, videos) {
        (_, 0) => part(photos, "photo"),
        (0, _) => part(videos, "video"),
        _ => format!("{}, {}", part(photos, "photo"), part(videos, "video")),
    };
    let taken: Vec<i64> = items.iter().filter_map(|i| i["taken"].as_i64()).collect();
    match (taken.iter().min(), taken.iter().max()) {
        (Some(&from), Some(&to)) => vec![count, day_range(from, to)],
        _ => vec![count],
    }
}

fn thousands(n: usize) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// "Oct 1 – 3, 2026", "Sep 30 – Oct 2, 2026", "Dec 30, 2025 – Jan 2, 2026",
/// from wall-time seconds read as UTC (as `taken` is stored).
fn day_range(from: i64, to: i64) -> String {
    let day = |t: i64| DateTime::from_timestamp(t, 0).unwrap_or_default();
    let (a, b) = (day(from), day(to));
    if a.date_naive() == b.date_naive() {
        a.format("%b %-d, %Y").to_string()
    } else if a.format("%Y%m").to_string() == b.format("%Y%m").to_string() {
        format!("{} – {}", a.format("%b %-d"), b.format("%-d, %Y"))
    } else if a.format("%Y").to_string() == b.format("%Y").to_string() {
        format!("{} – {}", a.format("%b %-d"), b.format("%b %-d, %Y"))
    } else {
        format!("{} – {}", a.format("%b %-d, %Y"), b.format("%b %-d, %Y"))
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn previews_word_counts_and_days_as_the_page_does() {
        let item = |kind: &str, taken: Option<i64>| json!({ "kind": kind, "taken": taken });
        // 2026-10-01 10:00 and 2026-10-03 18:00
        let (oct1, oct3) = (1_790_848_800, 1_791_050_400);
        assert_eq!(
            preview_meta(&[item("photo", Some(oct1)), item("photo", Some(oct3))]),
            ["2 photos", "Oct 1 – 3, 2026"]
        );
        assert_eq!(preview_meta(&[item("video", None)]), ["1 video"]);
        let many: Vec<Value> = (0..1234)
            .map(|_| item("photo", None))
            .chain([item("video", Some(oct1))])
            .collect();
        assert_eq!(
            preview_meta(&many),
            ["1,234 photos, 1 video", "Oct 1, 2026"]
        );
        assert_eq!(day_range(1_790_762_400, oct1), "Sep 30 – Oct 1, 2026");
        assert_eq!(
            day_range(1_767_096_000, 1_767_355_200),
            "Dec 30, 2025 – Jan 2, 2026"
        );
    }
}
