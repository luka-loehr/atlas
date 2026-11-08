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
pub(super) async fn list(State(app): State<AppState>, Path(folder): Path<String>, headers: HeaderMap) -> ApiResult<Response> {
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
            rows.iter().map(|r| json!({ "id": r.get::<_, i64>(0), "name": r.get::<_, String>(1) })).collect()
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

    Ok(media::json_validated(&headers, &json!({ "path": path, "folders": folders, "files": files })))
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

/// Up to 60 characters either side of the first case-insensitive match.
fn snippet(text: &str, term: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let fold = |c: &char| c.to_lowercase().next().unwrap_or(*c);
    let lowered: Vec<char> = chars.iter().map(fold).collect();
    let needle: Vec<char> = term.chars().map(|c| fold(&c)).collect();
    if needle.is_empty() || needle.len() > lowered.len() {
        return String::new();
    }
    let Some(at) = lowered.windows(needle.len()).position(|w| w == needle.as_slice()) else {
        return String::new();
    };
    let start = at.saturating_sub(60);
    let end = (at + needle.len() + 60).min(chars.len());
    let body: String = chars[start..end].iter().collect();
    format!(
        "{}{}{}",
        if start > 0 { "…" } else { "" },
        body.split_whitespace().collect::<Vec<_>>().join(" "),
        if end < chars.len() { "…" } else { "" },
    )
}

/// Folders and files by name first, then files whose extracted text matches,
/// each with the passage that matched.
pub(super) async fn search(State(app): State<AppState>, Query(q): Query<SearchQuery>) -> ApiResult<Json<Value>> {
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
        let text = format!("{} Die Rechnung vom März ist bezahlt. {}", "x ".repeat(80), "y ".repeat(80));
        let s = snippet(&text, "rechnung");
        assert!(s.starts_with('…') && s.ends_with('…'));
        assert!(s.contains("Die Rechnung vom März"));
        assert_eq!(snippet("short", "absent"), "");
    }
}
