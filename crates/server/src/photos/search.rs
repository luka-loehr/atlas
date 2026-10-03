//! Search: what the library knows by name (people, places, albums, tags,
//! filenames, years) plus what the photos look like (semantic).
//!
//! The semantic half embeds the query with the same model the assets were
//! embedded with (atlas-ml, on the GPU) and scans every asset vector exactly.
//! When atlas-ml is not running the response says so in `semantic` instead
//! of quietly returning less.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use axum::Json;
use axum::extract::{Query, State};
use serde::Deserialize;
use serde_json::{Value, json};

use super::library::place_json;
use super::people::person_json;
use super::vectors::{DIM, VectorIndex, normalize};
use super::{COLS, Columns, Item, VISIBLE};
use crate::{ApiResult, AppState, Config, util};

/// The best semantic hit must stand out this far (in standard deviations
/// above the library mean) for the query to count as matching anything.
/// Measured on a 24k library: real queries top out at 4.3 to 6.9, nonsense
/// strings at 3.3 to 3.8.
const CONFIDENT_TOP_Z: f32 = 4.0;
/// ... and every further hit this far. At 3.0 a concrete query ("Hund",
/// "Strand") returns a few hundred assets with the relevant ones in front.
const MIN_Z: f32 = 3.0;
const SEMANTIC_LIMIT: usize = 300;
const STRUCTURED_LIMIT: i64 = 2000;

/// The atlas-ml client: query embeddings with a small LRU in front.
pub struct Ml {
    http: reqwest::Client,
    url: String,
    cache: Mutex<QueryCache>,
    pub vectors: Arc<VectorIndex>,
}

#[derive(Default)]
struct QueryCache {
    vectors: HashMap<String, Arc<Vec<f32>>>,
    order: VecDeque<String>,
}

impl Ml {
    pub fn new(cfg: &Config) -> Self {
        Ml {
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(60))
                .connect_timeout(Duration::from_secs(2))
                .build()
                .expect("http client"),
            url: cfg.ml_url.trim_end_matches('/').to_string(),
            cache: Mutex::default(),
            vectors: Arc::default(),
        }
    }

    pub async fn embed_text(&self, text: &str) -> Result<Arc<Vec<f32>>> {
        let key = text.to_lowercase();
        if let Some(hit) = self.cache.lock().unwrap().vectors.get(&key) {
            return Ok(hit.clone());
        }
        #[derive(Deserialize)]
        struct Embedding {
            vec: Vec<f32>,
        }
        let mut embedding: Embedding = self
            .http
            .post(format!("{}/embed", self.url))
            .json(&json!({ "text": text }))
            .send()
            .await
            .context("atlas-ml unreachable")?
            .error_for_status()?
            .json()
            .await?;
        anyhow::ensure!(embedding.vec.len() == DIM, "atlas-ml returned {} dimensions", embedding.vec.len());
        normalize(&mut embedding.vec);
        let vec = Arc::new(embedding.vec);
        let mut cache = self.cache.lock().unwrap();
        if cache.vectors.insert(key.clone(), vec.clone()).is_none() {
            cache.order.push_back(key);
            if cache.order.len() > 512
                && let Some(oldest) = cache.order.pop_front()
            {
                cache.vectors.remove(&oldest);
            }
        }
        Ok(vec)
    }

    /// atlas-ml's own status report, None when it does not answer.
    pub async fn health(&self) -> Option<Value> {
        let response = self
            .http
            .get(format!("{}/health", self.url))
            .timeout(Duration::from_secs(2))
            .send()
            .await
            .ok()?;
        response.json().await.ok()
    }

    pub async fn warm(&self) -> bool {
        self.http.post(format!("{}/warm", self.url)).send().await.is_ok_and(|r| r.status().is_success())
    }
}

/// The search screen opened: load the model now, so the first query does not
/// wait for it, and bring the vector matrix up to date.
pub async fn warm(State(app): State<AppState>) -> Json<Value> {
    let ready = app.ml.warm().await;
    let vectors = app.ml.vectors.clone();
    let pool = app.pool.clone();
    tokio::spawn(async move {
        let probe = Arc::new(vec![0f32; DIM]);
        let _ = vectors.search(&pool, probe, 1).await;
    });
    Json(json!({ "semantic": ready }))
}

#[derive(Deserialize)]
pub struct SearchQuery {
    q: String,
}

pub async fn search(State(app): State<AppState>, Query(query): Query<SearchQuery>) -> ApiResult<Json<Value>> {
    let term = query.q.trim().to_string();
    if term.is_empty() {
        return Ok(Json(json!({
            "assets": Columns::default(), "people": [], "places": [], "albums": [], "semantic": "skipped",
        })));
    }
    // the query embedding runs alongside the database work
    let embedding = {
        let app = app.clone();
        let term = term.clone();
        tokio::spawn(async move { app.ml.embed_text(&term).await })
    };

    let c = app.pool.get().await?;
    let like = format!("%{}%", util::like_escape(&term));
    // tags are phrases ("black cat"): match at a word start, so "cat" finds
    // "black cat" and "cats" but not "authentication"
    let tag_word = format!("\\m{}", util::regex_escape(&term));
    let country = country_code(&term);
    let year = (term.len() == 4 && term.chars().all(|ch| ch.is_ascii_digit())).then(|| term.clone());

    let people_rows = c
        .query(
            &format!(
                "SELECT p.id, p.display_name, p.cover_face_id, count(DISTINCT f.asset_id) AS photos
                 FROM persons p JOIN faces f ON f.person_id = p.id JOIN assets ON assets.id = f.asset_id
                 WHERE p.merged_into IS NULL AND p.display_name ILIKE $1 AND {VISIBLE}
                 GROUP BY p.id ORDER BY photos DESC LIMIT 8"
            ),
            &[&like],
        )
        .await?;
    let person_ids: Vec<i64> = people_rows.iter().map(|r| r.get(0)).collect();

    let place_rows = c
        .query(
            &format!(
                "SELECT p.id, p.name, p.admin1, p.cc, count(*),
                        (array_agg(assets.id ORDER BY assets.taken_at DESC NULLS LAST))[1]
                 FROM places p
                 JOIN edges e ON e.dst_type = 'place' AND e.dst_id = p.id::text
                             AND e.rel = 'taken_at' AND e.src_type = 'asset'
                 JOIN assets ON assets.id = e.src_id
                 WHERE (p.name ILIKE $1 OR p.admin1 ILIKE $1 OR ($2::text IS NOT NULL AND p.cc = $2)) AND {VISIBLE}
                 GROUP BY p.id ORDER BY count(*) DESC LIMIT 8"
            ),
            &[&like, &country],
        )
        .await?;
    let place_ids: Vec<String> = place_rows.iter().map(|r| r.get::<_, i64>(0).to_string()).collect();

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
    let album_ids: Vec<i64> = album_rows.iter().map(|r| r.get(0)).collect();

    // ranked: person, place, album, tag, then filename / year
    let rows = c
        .query(
            &format!(
                "WITH hits AS (
                     SELECT f.asset_id AS id, 0 AS rank FROM faces f WHERE f.person_id = ANY($1)
                   UNION ALL
                     SELECT e.src_id, 1 FROM edges e
                     WHERE e.rel = 'taken_at' AND e.dst_type = 'place' AND e.src_type = 'asset' AND e.dst_id = ANY($2)
                   UNION ALL
                     SELECT aa.asset_id, 2 FROM album_assets aa WHERE aa.album_id = ANY($3)
                   UNION ALL
                     SELECT t.asset_id, 3 FROM tags t WHERE t.tag ~* $4
                   UNION ALL
                     SELECT a.id, 4 FROM assets a
                     WHERE a.orig_name ILIKE $5 OR ($6::text IS NOT NULL AND to_char(a.taken_at, 'YYYY') = $6)
                 ), best AS (
                     SELECT id, min(rank) AS rank FROM hits GROUP BY id
                 )
                 SELECT {COLS}, best.rank FROM assets JOIN best ON best.id = assets.id
                 WHERE {VISIBLE}
                 ORDER BY best.rank, assets.taken_at DESC NULLS LAST
                 LIMIT {STRUCTURED_LIMIT}"
            ),
            &[&person_ids, &place_ids, &album_ids, &tag_word, &like, &year],
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
    }

    // A query that names a person, place, album or year outright is answered
    // by those; what the photos look like only adds noise behind hundreds of
    // exact matches.
    let semantic = if named_hits >= 60 || year.is_some() {
        embedding.abort();
        "skipped"
    } else {
        match embedding.await {
            Ok(Ok(vector)) => {
                let hits = app.ml.vectors.search(&app.pool, vector, SEMANTIC_LIMIT).await?;
                let confident = hits.first().is_some_and(|best| best.1 >= CONFIDENT_TOP_Z);
                let wanted: Vec<&(String, f32)> = hits
                    .iter()
                    .take_while(|(_, z)| confident && *z >= MIN_Z)
                    .filter(|(id, _)| !seen.contains(id))
                    .collect();
                if !wanted.is_empty() {
                    let ids: Vec<&str> = wanted.iter().map(|(id, _)| id.as_str()).collect();
                    let found = c
                        .query(&format!("SELECT {COLS} FROM assets WHERE id = ANY($1) AND {VISIBLE}"), &[&ids])
                        .await?;
                    let mut by_id: HashMap<String, Item> =
                        found.iter().map(|r| Item::from_row(r, app.cfg.tz)).map(|i| (i.id.clone(), i)).collect();
                    for (id, _) in wanted {
                        if let Some(item) = by_id.remove(id) {
                            assets.push(item);
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
        }
    };

    Ok(Json(json!({
        "assets": assets,
        "people": people_rows.iter().map(person_json).collect::<Vec<_>>(),
        "places": place_rows.iter().map(place_json).collect::<Vec<_>>(),
        "albums": album_rows.iter().map(|r| json!({
            "id": r.get::<_, i64>(0), "title": r.get::<_, String>(1),
            "count": r.get::<_, i64>(2), "cover": r.get::<_, Option<String>>(3),
        })).collect::<Vec<_>>(),
        "semantic": semantic,
    })))
}

/// ISO 3166 alpha-2 code for a country named in German or English, so
/// "Kroatien" and "Croatia" both find places stored with cc = 'HR'.
pub fn country_code(term: &str) -> Option<&'static str> {
    const COUNTRIES: &[(&str, &[&str])] = &[
        ("AT", &["österreich", "austria"]),
        ("AU", &["australien", "australia"]),
        ("BE", &["belgien", "belgium"]),
        ("BG", &["bulgarien", "bulgaria"]),
        ("BR", &["brasilien", "brazil"]),
        ("CA", &["kanada", "canada"]),
        ("CH", &["schweiz", "switzerland"]),
        ("CN", &["china"]),
        ("CY", &["zypern", "cyprus"]),
        ("CZ", &["tschechien", "czechia", "czech republic"]),
        ("DE", &["deutschland", "germany"]),
        ("DK", &["dänemark", "denmark"]),
        ("EG", &["ägypten", "egypt"]),
        ("ES", &["spanien", "spain"]),
        ("FI", &["finnland", "finland"]),
        ("FR", &["frankreich", "france"]),
        ("GB", &["großbritannien", "england", "vereinigtes königreich", "united kingdom", "uk", "schottland", "scotland"]),
        ("GR", &["griechenland", "greece"]),
        ("HR", &["kroatien", "croatia"]),
        ("HU", &["ungarn", "hungary"]),
        ("IE", &["irland", "ireland"]),
        ("IN", &["indien", "india"]),
        ("IS", &["island", "iceland"]),
        ("IT", &["italien", "italy"]),
        ("JP", &["japan"]),
        ("LI", &["liechtenstein"]),
        ("LU", &["luxemburg", "luxembourg"]),
        ("MA", &["marokko", "morocco"]),
        ("MT", &["malta"]),
        ("MX", &["mexiko", "mexico"]),
        ("NL", &["niederlande", "holland", "netherlands"]),
        ("NO", &["norwegen", "norway"]),
        ("PL", &["polen", "poland"]),
        ("PT", &["portugal"]),
        ("RO", &["rumänien", "romania"]),
        ("RS", &["serbien", "serbia"]),
        ("SE", &["schweden", "sweden"]),
        ("SI", &["slowenien", "slovenia"]),
        ("SK", &["slowakei", "slovakia"]),
        ("TH", &["thailand"]),
        ("TR", &["türkei", "turkey", "türkiye"]),
        ("US", &["usa", "vereinigte staaten", "united states", "amerika", "america"]),
    ];
    let needle = term.trim().to_lowercase();
    COUNTRIES.iter().find(|(_, names)| names.contains(&needle.as_str())).map(|(code, _)| *code)
}

#[cfg(test)]
mod tests {
    use super::country_code;

    #[test]
    fn countries_resolve_in_both_languages() {
        assert_eq!(country_code("Kroatien"), Some("HR"));
        assert_eq!(country_code(" croatia "), Some("HR"));
        assert_eq!(country_code("Österreich"), Some("AT"));
        assert_eq!(country_code("Atlantis"), None);
    }
}
