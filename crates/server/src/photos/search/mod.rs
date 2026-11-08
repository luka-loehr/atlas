//! Search: what the library knows by name (people, places, albums,
//! filenames, years) plus what the photos look like (semantic).
//!
//! The semantic half embeds the query with the same model the assets were
//! embedded with (atlas-ml, on the GPU) and scans every asset vector exactly.
//! When atlas-ml is not running the response says so in `semantic` instead
//! of quietly returning less.
//!
//!   parse.rs     which words name someone, somewhere, some time (dates.rs)
//!   lexicon.rs   everything the library knows by name
//!   filtered.rs  a search that names something: those, ranked by the rest
//!   open.rs      a search that names nothing: words, text in images, look
//!   ml.rs        the query embeddings, from atlas-ml
//!   vectors.rs   every asset vector, scanned exactly

use std::sync::Arc;

use axum::Json;
use axum::extract::{Query, State};
use serde::Deserialize;
use serde_json::{Value, json};

use super::people::{self, person_json};
use super::places::{self, place_json};
use super::{Columns, VISIBLE};
use crate::{ApiResult, AppState, util};

mod dates;
mod filtered;
mod lexicon;
mod ml;
mod open;
mod parse;
mod text;
pub mod vectors;

pub use ml::Ml;
use vectors::{DIM, Questions};

/// Results are shown in time, not by score, so what is shown must all be
/// good: a hit is kept when it reaches this share of the best hit's z (of its
/// kind). Embedding scores have heavy tails: the chance threshold alone let
/// every everyday query fill all 300 places, and in time order the weak
/// ones (a beach without a dog for "dog on the beach") came first.
const RELATIVE_Z: f32 = 0.65;

/// The search screen opened: load the model now, so the first query does not
/// wait for it, and bring the vector matrix up to date.
pub async fn warm(State(app): State<AppState>) -> Json<Value> {
    let ready = app.ml.warm().await;
    let vectors = app.ml.vectors.clone();
    let pool = app.pool.clone();
    tokio::spawn(async move {
        let probe = Arc::new(Questions {
            still: vec![0f32; DIM],
            clip: vec![0f32; DIM],
        });
        let _ = vectors.search(&pool, probe, 1).await;
    });
    Json(json!({ "semantic": ready }))
}

#[derive(Deserialize)]
pub struct SearchQuery {
    q: String,
    /// add each result's score (`scores`): for tuning the thresholds
    #[serde(default)]
    debug: bool,
}

pub async fn search(
    State(app): State<AppState>,
    Query(query): Query<SearchQuery>,
) -> ApiResult<Json<Value>> {
    let term = query.q.trim().to_string();
    if term.is_empty() {
        return Ok(Json(json!({
            "assets": Columns::default(), "people": [], "places": [], "albums": [], "semantic": "skipped",
            "understood": [],
        })));
    }
    let c = app.pool.get().await?;
    let lexicon = lexicon::lexicon(&c).await?;
    let today = chrono::Utc::now().with_timezone(&app.cfg.tz).date_naive();
    let parsed = parse::parse(&term, &lexicon, today);

    // the text's embedding runs alongside the database work
    let embedding = parsed.text.clone().map(|text| {
        let app = app.clone();
        tokio::spawn(async move { app.ml.embed_text(&text).await })
    });

    // suggestions: whoever and wherever the words begin to name
    let like = format!("%{}%", util::like_escape(&term));
    let country = lexicon::country_code(&term);
    let people_rows = c
        .query(
            &format!(
                "{people}
                 WHERE p.merged_into IS NULL AND NOT p.hidden AND (p.display_name ~* $1 OR p.id = ANY($2)) AND {VISIBLE}
                 GROUP BY p.id ORDER BY photos DESC LIMIT 8",
                people = people::SUMMARY
            ),
            &[&format!(r"\m{}", text::regex_escape(&term.to_lowercase())), &parsed.people.iter().map(|p| p.0).collect::<Vec<i64>>()],
        )
        .await?;
    let place_rows = c
        .query(
            &format!(
                "{places}
                 WHERE (p.name ILIKE $1 OR p.admin1 ILIKE $1 OR ($2::text IS NOT NULL AND p.cc = $2)) AND {VISIBLE}
                 GROUP BY p.id ORDER BY count(*) DESC LIMIT 8",
                places = places::SUMMARY
            ),
            &[&like, &country],
        )
        .await?;
    let album_rows = c
        .query(
            &format!(
                "SELECT a.id, a.title, count(assets.id),
                        (array_agg(assets.id ORDER BY assets.taken_at DESC NULLS LAST))[1]
                 FROM albums a
                 LEFT JOIN album_assets aa ON aa.album_id = a.id
                 LEFT JOIN assets ON assets.id = aa.asset_id AND {VISIBLE}
                 WHERE a.title ILIKE $1
                 GROUP BY a.id ORDER BY count(assets.id) DESC LIMIT 8"
            ),
            &[&like],
        )
        .await?;

    let mut scores: Vec<f32> = Vec::new();
    let (mut assets, semantic) = if parsed.has_filters() {
        filtered::filtered(&app, &c, &parsed, embedding, &mut scores).await?
    } else {
        open::open_search(&app, &c, &term, &parsed, embedding, &mut scores).await?
    };
    // relevance decides what is found; it is shown in time, newest first,
    // like the library itself
    let order = assets.sort_newest_first();
    if scores.len() == order.len() {
        scores = order.iter().map(|&i| scores[i]).collect();
    }

    Ok(Json(json!({
        "assets": assets,
        "people": people_rows.iter().map(person_json).collect::<Vec<_>>(),
        "places": place_rows.iter().map(place_json).collect::<Vec<_>>(),
        "albums": album_rows.iter().map(|r| json!({
            "id": r.get::<_, i64>(0), "title": r.get::<_, String>(1),
            "count": r.get::<_, i64>(2), "cover": r.get::<_, Option<String>>(3),
        })).collect::<Vec<_>>(),
        "semantic": semantic,
        "understood": understood(&parsed),
        "scores": if query.debug { json!(scores) } else { Value::Null },
    })))
}

/// How the search was read, part by part, for the apps to show as tokens.
fn understood(parsed: &parse::Parsed) -> Vec<Value> {
    let mut parts = Vec::new();
    for (id, name, kind) in &parsed.people {
        parts.push(json!({ "kind": if kind == "person" { "person" } else { "pet" }, "id": id, "label": name }));
    }
    for (name, _) in &parsed.places {
        parts.push(json!({ "kind": "place", "label": name }));
    }
    for (id, title) in &parsed.albums {
        parts.push(json!({ "kind": "album", "id": id, "label": title }));
    }
    if let Some(when) = &parsed.when {
        parts.push(json!({ "kind": "date", "label": when.label() }));
    }
    if parsed.videos {
        parts.push(json!({ "kind": "media", "label": "Videos" }));
    }
    if let Some(text) = &parsed.text {
        parts.push(json!({ "kind": "text", "label": text }));
    }
    parts
}

type Embedding = Option<tokio::task::JoinHandle<anyhow::Result<Arc<Questions>>>>;
