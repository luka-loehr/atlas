//! Reading the tree: one folder level, the newest files, and search.

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio_postgres::Row;

use super::{FILE_COLS, file_json, folder_ref};
use crate::{ApiError, ApiResult, AppState, media, util};

/// One folder level: the path down from the root, child folders with their
/// recursive totals, and the files.
pub(super) async fn list(
    State(app): State<AppState>,
    Path(folder): Path<String>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    let folder = folder_ref(&folder)?;
    let c = app.pool.get().await?;

    let path: Vec<Value> = match folder {
        None => vec![],
        Some(id) => {
            let rows = c
                .query(
                    "WITH RECURSIVE up AS (
                         SELECT id, parent_id, name, 0 AS depth FROM drive_folders WHERE id = $1
                       UNION ALL
                         SELECT f.id, f.parent_id, f.name, up.depth + 1
                         FROM drive_folders f JOIN up ON f.id = up.parent_id
                     )
                     SELECT id, name FROM up ORDER BY depth DESC",
                    &[&id],
                )
                .await?;
            if rows.is_empty() {
                return Err(ApiError::NotFound);
            }
            rows.iter()
                .map(|r| json!({ "id": r.get::<_, i64>(0), "name": r.get::<_, String>(1) }))
                .collect()
        }
    };

    let folders: Vec<Value> = c
        .query(
            "WITH RECURSIVE tree AS (
                 SELECT id, id AS top FROM drive_folders WHERE parent_id IS NOT DISTINCT FROM $1
               UNION ALL
                 SELECT c.id, t.top FROM drive_folders c JOIN tree t ON c.parent_id = t.id
             ), totals AS (
                 SELECT t.top, count(fl.id) AS items, coalesce(sum(fl.size_bytes), 0)::bigint AS bytes
                 FROM tree t LEFT JOIN drive_files fl ON fl.folder_id = t.id AND fl.trashed_at IS NULL
                 GROUP BY t.top
             )
             SELECT d.id, d.name, totals.items, totals.bytes, d.created_at
             FROM drive_folders d JOIN totals ON totals.top = d.id
             ORDER BY lower(d.name)",
            &[&folder],
        )
        .await?
        .iter()
        .map(|r| {
            json!({
                "id": r.get::<_, i64>(0), "name": r.get::<_, String>(1),
                "items": r.get::<_, i64>(2), "bytes": r.get::<_, i64>(3),
                "created_at": r.get::<_, Option<DateTime<Utc>>>(4),
            })
        })
        .collect();

    let files: Vec<Value> = c
        .query(
            &format!(
                "SELECT {FILE_COLS} FROM drive_files df
                 WHERE df.folder_id IS NOT DISTINCT FROM $1 AND df.trashed_at IS NULL
                 ORDER BY lower(df.name)"
            ),
            &[&folder],
        )
        .await?
        .iter()
        .map(file_json)
        .collect();

    Ok(media::json_validated(
        &headers,
        &json!({ "path": path, "folders": folders, "files": files }),
    ))
}

pub(super) async fn recent(State(app): State<AppState>, headers: HeaderMap) -> ApiResult<Response> {
    let c = app.pool.get().await?;
    let files: Vec<Value> = c
        .query(
            &format!(
                "SELECT {FILE_COLS} FROM drive_files df
                 WHERE df.trashed_at IS NULL ORDER BY df.modified_at DESC NULLS LAST LIMIT 40"
            ),
            &[],
        )
        .await?
        .iter()
        .map(file_json)
        .collect();
    Ok(media::json_validated(&headers, &json!({ "files": files })))
}

#[derive(Deserialize)]
pub(super) struct SearchQuery {
    q: String,
}

/// Fast, allocation-bounded UTF-8 context snippet (~60 chars each side of first case-insensitive match)
/// without materializing `Vec<char>` over multi-megabyte PDF text columns.
pub fn fast_snippet(text: &str, term: &str) -> String {
    let term = term.trim();
    if term.is_empty() || text.is_empty() {
        return String::new();
    }
    // Scan at most the first 256 KB of extracted text so huge PDFs stay sub-millisecond
    let capped = if text.len() > 262_144 {
        let mut end = 262_144;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        &text[..end]
    } else {
        text
    };
    let lower_haystack = capped.to_lowercase();
    let lower_needle = term.to_lowercase();
    let Some(byte_pos) = lower_haystack.find(&lower_needle) else {
        return String::new();
    };
    // Map character index in lowercased prefix to original `capped` chars safely
    let char_before = lower_haystack[..byte_pos].chars().count();
    let needle_chars = lower_needle.chars().count();
    let start_char = char_before.saturating_sub(60);
    let take_chars = (char_before - start_char) + needle_chars + 60;

    let mut iter = capped.chars().skip(start_char);
    let raw_slice: String = iter.by_ref().take(take_chars).collect();
    let has_more = iter.next().is_some() || capped.len() < text.len();
    format!(
        "{}{}{}",
        if start_char > 0 { "…" } else { "" },
        raw_slice.split_whitespace().collect::<Vec<_>>().join(" "),
        if has_more { "…" } else { "" },
    )
}

fn snippet(text: &str, term: &str) -> String {
    fast_snippet(text, term)
}

/// Folders and files by name first, then files whose extracted text matches,
/// each with the passage that matched.
pub(super) async fn search(
    State(app): State<AppState>,
    Query(q): Query<SearchQuery>,
) -> ApiResult<Json<Value>> {
    let term = q.q.trim();
    if term.is_empty() {
        return Ok(Json(json!({ "files": [], "folders": [] })));
    }
    let like = format!("%{}%", util::like_escape(term));
    let c = app.pool.get().await?;
    let with_folder = |r: &Row| {
        let mut file = file_json(r);
        file["folder"] = json!(r.get::<_, Option<String>>(7));
        file
    };
    let mut files: Vec<Value> = c
        .query(
            &format!(
                "SELECT {FILE_COLS}, fo.name FROM drive_files df
                 LEFT JOIN drive_folders fo ON fo.id = df.folder_id
                 WHERE df.name ILIKE $1 AND df.trashed_at IS NULL
                 ORDER BY lower(df.name) LIMIT 200"
            ),
            &[&like],
        )
        .await?
        .iter()
        .map(with_folder)
        .collect();
    for r in c
        .query(
            &format!(
                "SELECT {FILE_COLS}, fo.name, df.text FROM drive_files df
                 LEFT JOIN drive_folders fo ON fo.id = df.folder_id
                 WHERE df.text ILIKE $1 AND df.name NOT ILIKE $1 AND df.trashed_at IS NULL
                 ORDER BY df.modified_at DESC NULLS LAST LIMIT 60"
            ),
            &[&like],
        )
        .await?
        .iter()
    {
        let mut file = with_folder(r);
        file["snippet"] = json!(snippet(r.get::<_, &str>(8), term));
        files.push(file);
    }
    let folders: Vec<Value> = c
        .query(
            "SELECT id, name, parent_id FROM drive_folders WHERE name ILIKE $1 ORDER BY lower(name) LIMIT 60",
            &[&like],
        )
        .await?
        .iter()
        .map(|r| json!({ "id": r.get::<_, i64>(0), "name": r.get::<_, String>(1), "parent_id": r.get::<_, Option<i64>>(2) }))
        .collect();
    Ok(Json(json!({ "files": files, "folders": folders })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snippets_show_the_match_in_context() {
        let text = format!(
            "{} Die Rechnung vom März ist bezahlt. {}",
            "x ".repeat(80),
            "y ".repeat(80)
        );
        let s = snippet(&text, "rechnung");
        assert!(s.starts_with('…') && s.ends_with('…'));
        assert!(s.contains("Die Rechnung vom März"));
        assert_eq!(snippet("short", "absent"), "");
    }
}
