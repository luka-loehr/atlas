//! Covers for the places, countries and years: the photo of each that the
//! image model finds the most beautiful, not simply the newest.
//!
//! Every candidate is scored against an English description of a good
//! cover, minus one of a bad one (a screenshot, a document, a blurry or
//! dark shot), as z-scores on the scale of the whole library. Only real
//! camera photos compete: stills with a camera, at least 1000 pixels on the
//! short side, and for places and countries only photos whose own GPS put
//! them there. The prompts do not name the place: which photos compete
//! decides where, the prompt only says what a cover looks like, so the
//! whole library is scored three times, not once per place.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use serde_json::{Value, json};
use tokio::sync::Mutex;

use super::VISIBLE;
use crate::{ApiResult, App, AppState, media};

/// What a place's or a country's cover shows.
const TRAVEL: &str = "a beautiful scenic travel photograph, a landscape, the sea, mountains, \
                      a beach or an old town in warm golden light";
/// What a year's cover shows.
const MOMENT: &str = "a beautiful memorable photograph, a happy moment with friends or family, \
                      or a stunning landscape";
/// What no cover should be.
const BAD: &str = "a screenshot of a phone screen, a document, text on paper, a receipt, \
                   a blurry dark photo, the inside of a car, a toilet or a bathroom";
/// How much the bad description counts against a photo.
const BAD_WEIGHT: f32 = 0.7;
/// A favorite is a little likelier to be the cover.
const FAVORITE_BONUS: f32 = 0.4;
/// The least score a cover needs (z of the good description, less the
/// weighted bad one).
const MIN_SCORE: f32 = 0.0;
/// Covers are worked out at most this often.
const FRESH: Duration = Duration::from_secs(6 * 3600);

fn cache() -> &'static Mutex<Option<(Instant, Arc<Value>)>> {
    static CACHE: OnceLock<Mutex<Option<(Instant, Arc<Value>)>>> = OnceLock::new();
    CACHE.get_or_init(Mutex::default)
}

/// `{ "places": {id: asset}, "countries": {cc: asset}, "years": {year: asset} }`
pub async fn list(State(app): State<AppState>, headers: HeaderMap) -> ApiResult<Response> {
    let mut slot = cache().lock().await;
    if let Some((at, covers)) = slot.as_ref()
        && at.elapsed() < FRESH
    {
        return Ok(media::json_validated(&headers, covers.as_ref()));
    }
    let covers = Arc::new(pick(&app).await?);
    *slot = Some((Instant::now(), covers.clone()));
    Ok(media::json_validated(&headers, covers.as_ref()))
}

struct Candidate {
    id: String,
    favorite: bool,
    year: Option<i32>,
    place: Option<String>,
    country: Option<String>,
}

async fn pick(app: &App) -> anyhow::Result<Value> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!(
                "SELECT assets.id, assets.favorite,
                        extract(year FROM assets.taken_at + make_interval(secs => coalesce(assets.tz_offset_s, 0)))::int,
                        e.dst_id, p.cc, assets.lat IS NOT NULL
                 FROM assets
                 LEFT JOIN edges e ON e.src_type = 'asset' AND e.src_id = assets.id
                                  AND e.rel = 'taken_at' AND e.dst_type = 'place'
                 LEFT JOIN places p ON p.id::text = e.dst_id
                 WHERE {VISIBLE} AND assets.type = 'photo' AND assets.camera IS NOT NULL
                   AND least(assets.width, assets.height) >= 1000"
            ),
            &[],
        )
        .await?;
    let candidates: Vec<Candidate> = rows
        .iter()
        .map(|r| {
            // a place borrowed from a neighbor (no GPS of its own) does not
            // make a photo a candidate for that place
            let located: bool = r.get(5);
            Candidate {
                id: r.get(0),
                favorite: r.get::<_, Option<bool>>(1).unwrap_or(false),
                year: r.get(2),
                place: if located { r.get(3) } else { None },
                country: if located { r.get(4) } else { None },
            }
        })
        .collect();
    let ids: Vec<String> = candidates.iter().map(|c| c.id.clone()).collect();
    let (travel, moment, bad) = tokio::try_join!(
        app.ml.embed_text(TRAVEL),
        app.ml.embed_text(MOMENT),
        app.ml.embed_text(BAD)
    )?;
    let vectors = &app.ml.vectors;
    let travel = vectors.scores(&app.pool, travel, ids.clone()).await?;
    let moment = vectors.scores(&app.pool, moment, ids.clone()).await?;
    let bad = vectors.scores(&app.pool, bad, ids).await?;

    let score = |c: &Candidate, good: &HashMap<String, f32>| -> Option<f32> {
        let g = *good.get(&c.id)?;
        let b = bad.get(&c.id).copied().unwrap_or(0.0);
        Some(g - BAD_WEIGHT * b + if c.favorite { FAVORITE_BONUS } else { 0.0 })
    };
    /// The best scored candidate of each group, leaving out `taken`.
    fn best<'a, K: std::hash::Hash + Eq + Clone>(
        candidates: &'a [Candidate],
        key: impl Fn(&'a Candidate) -> Option<K>,
        score: impl Fn(&Candidate) -> Option<f32>,
        taken: &HashSet<String>,
    ) -> HashMap<K, (f32, String)> {
        let mut top: HashMap<K, (f32, &str)> = HashMap::new();
        for c in candidates {
            let (Some(k), Some(s)) = (key(c), score(c)) else { continue };
            if taken.contains(&c.id) {
                continue;
            }
            let e = top.entry(k).or_insert((f32::MIN, &c.id));
            if s > e.0 {
                *e = (s, &c.id);
            }
        }
        top.into_iter().map(|(k, (s, id))| (k, (s, id.to_string()))).collect()
    }

    let none = HashSet::new();
    let years = best(&candidates, |c| c.year, |c| score(c, &moment), &none);
    // the years and the countries share a screen: never the same photo twice
    let shown: HashSet<String> = years.values().map(|(_, id)| id.clone()).collect();
    let countries = best(&candidates, |c| c.country.clone(), |c| score(c, &travel), &shown);
    let places = best(&candidates, |c| c.place.clone(), |c| score(c, &travel), &none);
    for (cc, (s, _)) in &countries {
        tracing::info!(country = %cc, score = s, "cover");
    }
    let mut ps: Vec<f32> = places.values().map(|(s, _)| *s).collect();
    ps.sort_by(f32::total_cmp);
    tracing::info!(places = places.len(), countries = countries.len(), years = years.len(),
                   place_scores = ?ps.iter().step_by((ps.len() / 10).max(1)).collect::<Vec<_>>(), "covers picked");
    // a group whose best photo is still not good gets no cover: its card
    // shows its name on a plain ground rather than a toilet or a receipt
    let keep = |m: HashMap<String, (f32, String)>| -> HashMap<String, String> {
        m.into_iter().filter(|(_, (s, _))| *s >= MIN_SCORE).map(|(k, (_, id))| (k, id)).collect()
    };
    Ok(json!({
        "places": keep(places),
        "countries": keep(countries),
        "years": keep(years.into_iter().map(|(y, v)| (y.to_string(), v)).collect()),
    }))
}
