//! Covers for the places, countries and years: the photo of each that the
//! image model finds the most beautiful, not simply the newest.
//!
//! Every candidate is scored against an English description of a good
//! cover, minus one of a bad one (a screenshot, a document, a blurry or
//! dark shot), as z-scores on the scale of the whole library. Every photo
//! and video of a group can be its cover, so none goes without one, but
//! real camera photos (a camera, 1000 pixels on the short side, their own
//! GPS) come first: anything else carries a penalty. The prompts do not name the place: which photos compete
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
                   a blurry dark photo, a black or very dark image, the inside of a car, \
                   a selfie inside a car, a toilet or a bathroom, a map, an illustration, digital art";
/// How much the bad description counts against a photo.
const BAD_WEIGHT: f32 = 1.0;
/// A favorite is a little likelier to be the cover.
const FAVORITE_BONUS: f32 = 0.4;
/// The least score a place's or a country's cover needs (good less bad,
/// less the penalty); below it the app shows a map of the place.
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
    /// Counts against photos that are less likely to be good covers.
    penalty: f32,
}

async fn pick(app: &App) -> anyhow::Result<Value> {
    let c = app.pool.get().await?;
    let rows = c
        .query(
            &format!(
                "SELECT assets.id, assets.favorite,
                        extract(year FROM assets.taken_at + make_interval(secs => coalesce(assets.tz_offset_s, 0)))::int,
                        e.dst_id, p.cc, assets.lat IS NOT NULL,
                        assets.type = 'photo' AND assets.camera IS NOT NULL
                            AND least(assets.width, assets.height) >= 1000,
                        assets.type = 'video'
                 FROM assets
                 LEFT JOIN edges e ON e.src_type = 'asset' AND e.src_id = assets.id
                                  AND e.rel = 'taken_at' AND e.dst_type = 'place'
                 LEFT JOIN places p ON p.id::text = e.dst_id
                 WHERE {VISIBLE}"
            ),
            &[],
        )
        .await?;
    let candidates: Vec<Candidate> = rows
        .iter()
        .map(|r| {
            let located: bool = r.get(5);
            let camera: bool = r.get::<_, Option<bool>>(6).unwrap_or(false);
            let video: bool = r.get(7);
            // every photo of a group can be its cover, so none stays without
            // one; a real camera photo whose own GPS put it there comes first
            let penalty = if camera && located {
                0.0
            } else if video {
                2.5
            } else if camera {
                1.0
            } else {
                1.5
            };
            Candidate {
                id: r.get(0),
                favorite: r.get::<_, Option<bool>>(1).unwrap_or(false),
                year: r.get(2),
                place: r.get(3),
                country: r.get(4),
                penalty,
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
        Some(g - BAD_WEIGHT * b - c.penalty + if c.favorite { FAVORITE_BONUS } else { 0.0 })
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
    // the countries first: a small one may have a single good photo, while
    // a year has plenty, and the two share a screen (never one photo twice)
    let countries = best(&candidates, |c| c.country.clone(), |c| score(c, &travel), &none);
    let shown: HashSet<String> = countries.values().map(|(_, id)| id.clone()).collect();
    let years = best(&candidates, |c| c.year, |c| score(c, &moment), &shown);
    let places = best(&candidates, |c| c.place.clone(), |c| score(c, &travel), &none);
    tracing::info!(places = places.len(), countries = countries.len(), years = years.len(), "covers picked");
    // a place or country whose best photo is still a bad one gets none:
    // the app shows a map of it instead; a year always has its best
    let keep = |m: HashMap<String, (f32, String)>, floor: f32| -> HashMap<String, String> {
        m.into_iter().filter(|(_, (s, _))| *s >= floor).map(|(k, (_, id))| (k, id)).collect()
    };
    Ok(json!({
        "places": keep(places, MIN_SCORE),
        "countries": keep(countries, MIN_SCORE),
        "years": keep(years.into_iter().map(|(y, v)| (y.to_string(), v)).collect(), f32::MIN),
    }))
}
