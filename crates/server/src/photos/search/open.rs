//! A search naming nothing the library knows by name: its words against
//! filenames, years and the text in images, then what the photos look like.

use std::collections::{HashMap, HashSet};

use super::parse::Parsed;
use super::text::text_pattern;
use super::vectors::Hit;
use super::{Embedding, RELATIVE_Z};
use crate::photos::{COLS, Columns, Item, VISIBLE};
use crate::{ApiResult, AppState, util};

/// A query counts as matching anything when one of its hits is at least
/// this similar to it ...
const CONFIDENT_SIMILARITY: f32 = 0.34;
/// ... and either its best hit stands out this far beyond what chance gives
/// the best of its kind ...
const CONFIDENT_MARGIN: f32 = 0.6;
/// ... or this many hits beat what about two unrelated assets of their kind
/// reach (`chance_tail`): a concept a large share of the library shows
/// ("selfie") has a wide spread and no single outlier, but many hits. Those
/// hits are what is then shown. Measured 2026-10-21 on a 2,100-asset sample
/// and on the first 3,300 assets of the library: 49 and 50 of 50 everyday
/// queries find results, 4 and 6 of 16 gibberish strings do too.
const CONFIDENT_COUNT: usize = 10;
const SEMANTIC_LIMIT: usize = 300;
const STRUCTURED_LIMIT: i64 = 2000;

/// A search naming nothing the library knows by name: its words against
/// names, filenames and the text in images, then what the photos look like.
pub(super) async fn open_search(
    app: &AppState,
    c: &deadpool_postgres::Object,
    term: &str,
    parsed: &Parsed,
    embedding: Embedding,
    debug_scores: &mut Vec<f32>,
) -> ApiResult<(Columns, &'static str)> {
    let like = format!("%{}%", util::like_escape(term));
    let text_like = text_pattern(&parsed.text.clone().unwrap_or_else(|| term.to_string()));
    let year = (term.len() == 4 && term.chars().all(|ch| ch.is_ascii_digit())).then(|| term.to_string());
    // ranked: person, place, album, text in the image, then filename / year
    let rows = c
        .query(
            &format!(
                "WITH hits AS (
                     -- whole names, places and albums are filters (query.rs);
                     -- a word that only begins one ('car' of Carla) is offered
                     -- as a suggestion above the results, not as its photos
                     SELECT t.asset_id AS id, 3 AS rank FROM asset_text t WHERE lower(t.text) ~ $2
                   UNION ALL
                     SELECT a.id, 4 FROM assets a
                     WHERE a.orig_name ILIKE $1 OR ($3::text IS NOT NULL AND to_char(a.taken_at, 'YYYY') = $3)
                 ), best AS (
                     SELECT id, min(rank) AS rank FROM hits GROUP BY id
                 )
                 SELECT {COLS}, best.rank FROM assets JOIN best ON best.id = assets.id
                 WHERE {VISIBLE}
                 ORDER BY best.rank, assets.taken_at DESC NULLS LAST
                 LIMIT {STRUCTURED_LIMIT}"
            ),
            &[&like, &text_like, &year],
        )
        .await?;

    let mut assets = Columns::default();
    let mut seen = HashSet::with_capacity(rows.len());
    let mut named_hits = 0;
    for row in &rows {
        if row.get::<_, i32>(9) <= 2 {
            named_hits += 1;
        }
        let item = Item::from_row(row, app.cfg.tz);
        seen.insert(item.id.clone());
        assets.push(item);
        debug_scores.push(99.0);
    }

    // a query that names a person, place, album or year outright is answered
    // by those; what the photos look like only adds noise behind hundreds of
    // exact matches
    let semantic = match embedding {
        None => "skipped",
        Some(embedding) if named_hits >= 60 || year.is_some() => {
            embedding.abort();
            "skipped"
        }
        Some(embedding) => match embedding.await {
            Ok(Ok(vector)) => {
                let hits = app.ml.vectors.search(&app.pool, vector, SEMANTIC_LIMIT).await?;
                let confident = confident(&hits);
                // the best of each kind (stills and clips have their own scale)
                let mut best: Vec<(f32, f32)> = Vec::new();
                for h in &hits {
                    match best.iter_mut().find(|(kind, _)| *kind == h.chance_tail) {
                        Some((_, z)) => *z = z.max(h.z),
                        None => best.push((h.chance_tail, h.z)),
                    }
                }
                let bar = |h: &Hit| {
                    best.iter().find(|(kind, _)| *kind == h.chance_tail).map_or(f32::MAX, |(_, z)| z * RELATIVE_Z)
                };
                let wanted: Vec<&String> = hits
                    .iter()
                    .filter(|h| confident && h.z >= h.chance_tail && h.z >= bar(h) && !seen.contains(&h.id))
                    .map(|h| &h.id)
                    .collect();
                if !wanted.is_empty() {
                    let ids: Vec<&str> = wanted.iter().map(|id| id.as_str()).collect();
                    let found = c
                        .query(&format!("SELECT {COLS} FROM assets WHERE id = ANY($1) AND {VISIBLE}"), &[&ids])
                        .await?;
                    let mut by_id: HashMap<String, Item> =
                        found.iter().map(|r| Item::from_row(r, app.cfg.tz)).map(|i| (i.id.clone(), i)).collect();
                    let z: HashMap<&String, f32> = hits.iter().map(|h| (&h.id, h.z)).collect();
                    for id in wanted {
                        if let Some(item) = by_id.remove(id) {
                            assets.push(item);
                            debug_scores.push(z.get(id).copied().unwrap_or(0.0));
                        }
                    }
                }
                "ok"
            }
            Ok(Err(e)) => {
                tracing::warn!("semantic search unavailable: {e:#}");
                "unavailable"
            }
            Err(_) => "unavailable",
        },
    };
    Ok((assets, semantic))
}

/// Whether a search's hits (best first) show it matches anything at all.
fn confident(hits: &[Hit]) -> bool {
    let outlier = hits.first().is_some_and(|best| best.z >= best.chance_best + CONFIDENT_MARGIN);
    let many = hits.iter().filter(|h| h.z >= h.chance_tail).count() >= CONFIDENT_COUNT;
    hits.iter().any(|h| h.similarity >= CONFIDENT_SIMILARITY) && (outlier || many)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hit(z: f32, similarity: f32) -> Hit {
        Hit { id: String::new(), similarity, z, chance_best: 4.0, chance_tail: 3.5 }
    }

    #[test]
    fn a_match_is_an_outlier_or_many_hits_and_similar_enough() {
        // one clear outlier
        assert!(confident(&[hit(6.0, 0.45), hit(3.0, 0.3)]));
        // a broad concept: no outlier, but a dozen hits beyond chance
        assert!(confident(&(0..12).map(|_| hit(3.8, 0.44)).collect::<Vec<_>>()));
        // a few hits beyond chance and no outlier: noise
        assert!(!confident(&(0..3).map(|_| hit(3.8, 0.44)).collect::<Vec<_>>()));
        // an outlier nothing like the query
        assert!(!confident(&[hit(6.0, 0.30)]));
        assert!(!confident(&[]));
    }
}
