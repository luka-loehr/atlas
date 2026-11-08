//! A search that names people, places, albums or times: all of them must
//! hold, and the text that is left ranks within them.

use std::collections::{HashMap, HashSet};

use super::dates::When;
use super::parse::Parsed;
use super::text::text_pattern;
use super::{Embedding, RELATIVE_Z};
use crate::photos::{COLS, Columns, Item, VISIBLE};
use crate::{ApiResult, AppState};

/// Within what a search names ("alex at the beach"), an asset matches the
/// text when it stands out this far for it (z within its kind) ...
const FILTERED_TEXT_Z: f32 = 2.1;
/// ... and when none does, the closest few are shown.
const FILTERED_TEXT_FALLBACK: usize = 24;

/// What the search names, as people, places, albums and times, all of which
/// must hold; the text that is left ranks within them.
pub(super) async fn filtered(
    app: &AppState,
    c: &deadpool_postgres::Object,
    parsed: &Parsed,
    embedding: Embedding,
    debug_scores: &mut Vec<f32>,
) -> ApiResult<(Columns, &'static str)> {
    use tokio_postgres::types::ToSql;
    let mut conditions: Vec<String> = vec![VISIBLE.to_string()];
    let mut params: Vec<Box<dyn ToSql + Sync + Send>> = Vec::new();
    let param = |value: Box<dyn ToSql + Sync + Send>,
                 params: &mut Vec<Box<dyn ToSql + Sync + Send>>| {
        params.push(value);
        format!("${}", params.len())
    };
    let people: Vec<i64> = parsed.people.iter().map(|p| p.0).collect();
    for id in &people {
        let p = param(Box::new(*id), &mut params);
        conditions.push(format!(
            "EXISTS (SELECT 1 FROM faces f WHERE f.asset_id = assets.id AND f.person_id = {p})"
        ));
    }
    for (_, places) in &parsed.places {
        let ids: Vec<String> = places.iter().map(i64::to_string).collect();
        let p = param(Box::new(ids), &mut params);
        conditions.push(format!(
            "EXISTS (SELECT 1 FROM edges e WHERE e.src_type = 'asset' AND e.src_id = assets.id
                     AND e.rel = 'taken_at' AND e.dst_type = 'place' AND e.dst_id = ANY({p}))"
        ));
    }
    for (id, _) in &parsed.albums {
        let p = param(Box::new(*id), &mut params);
        conditions.push(format!("EXISTS (SELECT 1 FROM album_assets aa WHERE aa.asset_id = assets.id AND aa.album_id = {p})"));
    }
    // local time: the capture time where it was taken
    let local = "(assets.taken_at + make_interval(secs => coalesce(assets.tz_offset_s, 0)))";
    match &parsed.when {
        Some(When::Range { from, to, .. }) => {
            let (f, t) = (
                param(Box::new(*from), &mut params),
                param(Box::new(*to), &mut params),
            );
            conditions.push(format!("{local}::date >= {f} AND {local}::date < {t}"));
        }
        Some(When::Months { months, .. }) => {
            let months: Vec<i32> = months.iter().map(|m| *m as i32).collect();
            let p = param(Box::new(months), &mut params);
            conditions.push(format!("extract(month FROM {local})::int = ANY({p})"));
        }
        None => {}
    }
    if parsed.videos {
        conditions.push("assets.type = 'video'".into());
    }
    // how prominent the people asked for are: the smallest of their faces
    // (as a share of the frame's width), less for every stranger beside them
    let prominence = if people.is_empty() {
        "0::real".to_string()
    } else {
        let p = param(Box::new(people.clone()), &mut params);
        format!(
            "(SELECT min(w) FROM (SELECT max(f.bbox[3] - f.bbox[1]) AS w FROM faces f
                                   WHERE f.asset_id = assets.id AND f.person_id = ANY({p}) GROUP BY f.person_id) x)
             / (1 + 0.15 * greatest(0, (SELECT count(*) FROM faces f JOIN persons q ON q.id = f.person_id
                                       WHERE f.asset_id = assets.id AND f.kind = 'person' AND NOT q.hidden) - {n}))",
            n = people.len()
        )
    };
    let sql = format!(
        "SELECT {COLS}, {prominence}::real FROM assets WHERE {} ORDER BY assets.taken_at DESC NULLS LAST LIMIT 20000",
        conditions.join(" AND ")
    );
    let refs: Vec<&(dyn ToSql + Sync)> = params
        .iter()
        .map(|p| p.as_ref() as &(dyn ToSql + Sync))
        .collect();
    let rows = c.query(&sql, &refs).await?;
    let mut items: Vec<(Item, f32)> = rows
        .iter()
        .map(|r| {
            (
                Item::from_row(r, app.cfg.tz),
                r.get::<_, Option<f32>>(9).unwrap_or(0.0),
            )
        })
        .collect();

    let mut semantic = "skipped";
    if let (Some(text), Some(embedding)) = (&parsed.text, embedding) {
        // what the text says it shows: text in the image first, then the look
        let ids: Vec<String> = items.iter().map(|(i, _)| i.id.clone()).collect();
        let pattern = text_pattern(text);
        let reads: HashSet<String> = c
            .query(
                "SELECT asset_id FROM asset_text WHERE asset_id = ANY($1) AND lower(text) ~ $2",
                &[&ids, &pattern],
            )
            .await?
            .iter()
            .map(|r| r.get(0))
            .collect();
        let scores = match embedding.await {
            Ok(Ok(vector)) => {
                semantic = "ok";
                app.ml.vectors.scores(&app.pool, vector, ids).await?
            }
            Ok(Err(e)) => {
                tracing::warn!("semantic search unavailable: {e:#}");
                semantic = "unavailable";
                HashMap::new()
            }
            Err(_) => {
                semantic = "unavailable";
                HashMap::new()
            }
        };
        let z = |id: &str| scores.get(id).copied().unwrap_or(f32::MIN);
        let best = items.iter().map(|(i, _)| z(&i.id)).fold(f32::MIN, f32::max);
        let bar = FILTERED_TEXT_Z.max(best * RELATIVE_Z);
        let matching = items
            .iter()
            .filter(|(i, _)| reads.contains(&i.id) || z(&i.id) >= bar)
            .count();
        items.sort_by(|a, b| {
            let (ra, rb) = (reads.contains(&a.0.id), reads.contains(&b.0.id));
            rb.cmp(&ra).then(z(&b.0.id).total_cmp(&z(&a.0.id)))
        });
        // what matches; when nothing does, the closest few
        items.truncate(if matching > 0 {
            matching
        } else {
            FILTERED_TEXT_FALLBACK.min(items.len())
        });
        *debug_scores = items
            .iter()
            .map(|(i, _)| {
                if reads.contains(&i.id) {
                    99.0
                } else {
                    z(&i.id)
                }
            })
            .collect();
    } else if !people.is_empty() {
        // the people asked for, the clearest photos of them first
        items.sort_by(|a, b| b.1.total_cmp(&a.1));
        *debug_scores = items.iter().map(|(_, p)| *p).collect();
    }
    let mut assets = Columns::default();
    for (item, _) in items {
        assets.push(item);
    }
    Ok((assets, semantic))
}
