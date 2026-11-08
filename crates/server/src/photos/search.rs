//! Search: what the library knows by name (people, places, albums,
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
use super::query;
use super::vectors::{DIM, Hit, Questions, VectorIndex, normalize};
use super::{COLS, Columns, Item, VISIBLE};
use crate::{ApiResult, AppState, Config, util};

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
/// Within what a search names ("alex at the beach"), an asset matches the
/// text when it stands out this far for it (z within its kind) ...
const FILTERED_TEXT_Z: f32 = 2.1;
/// ... and when none does, the closest few are shown.
const FILTERED_TEXT_FALLBACK: usize = 24;
/// Results are shown in time, not by score, so what is shown must all be
/// good: a hit is kept when it reaches this share of the best hit's z (of its
/// kind). Embedding scores have heavy tails: the chance threshold alone let
/// every everyday query fill all 300 places, and in time order the weak
/// ones (a beach without a dog for "dog on the beach") came first.
const RELATIVE_Z: f32 = 0.65;
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
    vectors: HashMap<String, Arc<Questions>>,
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

    /// The search as atlas-ml embeds it: the question for stills and the one
    /// for clips.
    pub async fn embed_text(&self, text: &str) -> Result<Arc<Questions>> {
        let key = text.to_lowercase();
        if let Some(hit) = self.cache.lock().unwrap().vectors.get(&key) {
            return Ok(hit.clone());
        }
        #[derive(Deserialize)]
        struct Embedding {
            still: Vec<f32>,
            clip: Vec<f32>,
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
        for v in [&mut embedding.still, &mut embedding.clip] {
            anyhow::ensure!(v.len() == DIM, "atlas-ml returned {} dimensions", v.len());
            normalize(v);
        }
        let vec = Arc::new(Questions { still: embedding.still, clip: embedding.clip });
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
        let probe = Arc::new(Questions { still: vec![0f32; DIM], clip: vec![0f32; DIM] });
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

pub async fn search(State(app): State<AppState>, Query(query): Query<SearchQuery>) -> ApiResult<Json<Value>> {
    let term = query.q.trim().to_string();
    if term.is_empty() {
        return Ok(Json(json!({
            "assets": Columns::default(), "people": [], "places": [], "albums": [], "semantic": "skipped",
            "understood": [],
        })));
    }
    let c = app.pool.get().await?;
    let lexicon = lexicon(&c).await?;
    let today = chrono::Utc::now().with_timezone(&app.cfg.tz).date_naive();
    let parsed = query::parse(&term, &lexicon, today);

    // the text's embedding runs alongside the database work
    let embedding = parsed.text.clone().map(|text| {
        let app = app.clone();
        tokio::spawn(async move { app.ml.embed_text(&text).await })
    });

    // suggestions: whoever and wherever the words begin to name
    let like = format!("%{}%", util::like_escape(&term));
    let country = country_code(&term);
    let people_rows = c
        .query(
            &format!(
                "SELECT p.id, p.display_name, p.cover_face_id, count(DISTINCT f.asset_id) AS photos, p.kind
                 FROM persons p JOIN faces f ON f.person_id = p.id JOIN assets ON assets.id = f.asset_id
                 WHERE p.merged_into IS NULL AND NOT p.hidden AND (p.display_name ~* $1 OR p.id = ANY($2)) AND {VISIBLE}
                 GROUP BY p.id ORDER BY photos DESC LIMIT 8"
            ),
            &[&format!(r"\m{}", regex_escape(&term.to_lowercase())), &parsed.people.iter().map(|p| p.0).collect::<Vec<i64>>()],
        )
        .await?;
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
        filtered(&app, &c, &parsed, embedding, &mut scores).await?
    } else {
        open_search(&app, &c, &term, &parsed, embedding, &mut scores).await?
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
fn understood(parsed: &query::Parsed) -> Vec<Value> {
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

/// What the search names, as people, places, albums and times, all of which
/// must hold; the text that is left ranks within them.
async fn filtered(
    app: &AppState,
    c: &deadpool_postgres::Object,
    parsed: &query::Parsed,
    embedding: Embedding,
    debug_scores: &mut Vec<f32>,
) -> ApiResult<(Columns, &'static str)> {
    use tokio_postgres::types::ToSql;
    let mut conditions: Vec<String> = vec![VISIBLE.to_string()];
    let mut params: Vec<Box<dyn ToSql + Sync + Send>> = Vec::new();
    let param = |value: Box<dyn ToSql + Sync + Send>, params: &mut Vec<Box<dyn ToSql + Sync + Send>>| {
        params.push(value);
        format!("${}", params.len())
    };
    let people: Vec<i64> = parsed.people.iter().map(|p| p.0).collect();
    for id in &people {
        let p = param(Box::new(*id), &mut params);
        conditions.push(format!("EXISTS (SELECT 1 FROM faces f WHERE f.asset_id = assets.id AND f.person_id = {p})"));
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
        Some(query::When::Range { from, to, .. }) => {
            let (f, t) = (param(Box::new(*from), &mut params), param(Box::new(*to), &mut params));
            conditions.push(format!("{local}::date >= {f} AND {local}::date < {t}"));
        }
        Some(query::When::Months { months, .. }) => {
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
    let refs: Vec<&(dyn ToSql + Sync)> = params.iter().map(|p| p.as_ref() as &(dyn ToSql + Sync)).collect();
    let rows = c.query(&sql, &refs).await?;
    let mut items: Vec<(Item, f32)> = rows.iter().map(|r| (Item::from_row(r, app.cfg.tz), r.get::<_, Option<f32>>(9).unwrap_or(0.0))).collect();

    let mut semantic = "skipped";
    if let (Some(text), Some(embedding)) = (&parsed.text, embedding) {
        // what the text says it shows: text in the image first, then the look
        let ids: Vec<String> = items.iter().map(|(i, _)| i.id.clone()).collect();
        let pattern = text_pattern(text);
        let reads: HashSet<String> = c
            .query("SELECT asset_id FROM asset_text WHERE asset_id = ANY($1) AND lower(text) ~ $2", &[&ids, &pattern])
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
        let matching = items.iter().filter(|(i, _)| reads.contains(&i.id) || z(&i.id) >= bar).count();
        items.sort_by(|a, b| {
            let (ra, rb) = (reads.contains(&a.0.id), reads.contains(&b.0.id));
            rb.cmp(&ra).then(z(&b.0.id).total_cmp(&z(&a.0.id)))
        });
        // what matches; when nothing does, the closest few
        items.truncate(if matching > 0 { matching } else { FILTERED_TEXT_FALLBACK.min(items.len()) });
        *debug_scores = items.iter().map(|(i, _)| if reads.contains(&i.id) { 99.0 } else { z(&i.id) }).collect();
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

/// A search naming nothing the library knows by name: its words against
/// names, filenames and the text in images, then what the photos look like.
async fn open_search(
    app: &AppState,
    c: &deadpool_postgres::Object,
    term: &str,
    parsed: &query::Parsed,
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
                let bar = |h: &super::vectors::Hit| {
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

/// Everything a search can name: people and pets (not hidden), places with
/// their regions and countries (in German and English), albums.
async fn lexicon(c: &deadpool_postgres::Object) -> ApiResult<query::Lexicon> {
    let people = c
        .query(
            "SELECT p.id, p.display_name, p.kind, p.face_count, coalesce(p.is_me, false) FROM persons p
             WHERE p.merged_into IS NULL AND NOT p.hidden AND p.display_name IS NOT NULL",
            &[],
        )
        .await?
        .iter()
        .map(|r| query::Person {
            id: r.get(0),
            name: r.get(1),
            kind: r.get(2),
            photos: i64::from(r.get::<_, i32>(3)),
            me: r.get(4),
        })
        .collect();
    let rows = c.query("SELECT id, name, admin1, cc FROM places", &[]).await?;
    let mut by_name: HashMap<String, (String, Vec<i64>)> = HashMap::new();
    let mut add = |name: &str, id: i64| {
        let key = query::fold(name);
        if key.trim().is_empty() {
            return;
        }
        by_name.entry(key).or_insert_with(|| (name.to_string(), Vec::new())).1.push(id);
    };
    for r in &rows {
        let id: i64 = r.get(0);
        if let Some(name) = r.get::<_, Option<String>>(1) {
            add(&name, id);
        }
        if let Some(region) = r.get::<_, Option<String>>(2) {
            add(&region, id);
        }
        if let Some(cc) = r.get::<_, Option<String>>(3)
            && let Some((_, names)) = COUNTRIES.iter().find(|(code, _)| *code == cc)
        {
            for name in *names {
                add(&capitalized(name), id);
            }
        }
    }
    let places = by_name
        .into_values()
        .map(|(name, mut places)| {
            places.sort_unstable();
            places.dedup();
            query::PlaceName { name, places }
        })
        .collect();
    let albums = c
        .query("SELECT id, title FROM albums", &[])
        .await?
        .iter()
        .map(|r| query::Album { id: r.get(0), title: r.get(1) })
        .collect();
    Ok(query::Lexicon { people, places, albums })
}

fn capitalized(name: &str) -> String {
    name.split(' ')
        .map(|w| {
            let mut c = w.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// ISO 3166 alpha-2 code for a country named in German or English, so
/// "Kroatien" and "Croatia" both find places stored with cc = 'HR'.
pub fn country_code(term: &str) -> Option<&'static str> {
    let needle = term.trim().to_lowercase();
    COUNTRIES.iter().find(|(_, names)| names.contains(&needle.as_str())).map(|(code, _)| *code)
}

/// Countries by ISO code, named in German and English.
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

/// Whether a search's hits (best first) show it matches anything at all.
fn confident(hits: &[Hit]) -> bool {
    let outlier = hits.first().is_some_and(|best| best.z >= best.chance_best + CONFIDENT_MARGIN);
    let many = hits.iter().filter(|h| h.z >= h.chance_tail).count() >= CONFIDENT_COUNT;
    hits.iter().any(|h| h.similarity >= CONFIDENT_SIMILARITY) && (outlier || many)
}

/// What text read off a photo must contain to match `text` (a Postgres
/// regex on the lowercased text): short words whole ("dog" is not in the
/// Croatian "događaji", but is in "dog's"), longer ones anywhere, so a word
/// is found inside a German compound ("vertretungsplan" in
/// "vertretungsplanänderung"). Spaces match any run of whitespace.
fn text_pattern(text: &str) -> String {
    const WHOLE_BELOW: usize = 6;
    let words: Vec<String> = text.to_lowercase().split_whitespace().map(regex_escape).collect();
    let body = words.join(r"\s+");
    let short = text.chars().filter(|c| !c.is_whitespace()).count() < WHOLE_BELOW;
    if short { format!(r"\m{body}\M") } else { body }
}

fn regex_escape(s: &str) -> String {
    s.chars()
        .flat_map(|c| {
            let special = r"\.+*?()|[]{}^$".contains(c);
            special.then_some('\\').into_iter().chain(std::iter::once(c))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{Hit, confident, country_code, text_pattern};

    #[test]
    fn short_words_match_whole() {
        assert_eq!(text_pattern("Dog"), r"\mdog\M");
        assert_eq!(text_pattern("Vertretungsplan"), "vertretungsplan");
        assert_eq!(text_pattern("bus  stop"), r"bus\s+stop");
        assert_eq!(text_pattern("c++"), r"\mc\+\+\M");
    }

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

    #[test]
    fn countries_resolve_in_both_languages() {
        assert_eq!(country_code("Kroatien"), Some("HR"));
        assert_eq!(country_code(" croatia "), Some("HR"));
        assert_eq!(country_code("Österreich"), Some("AT"));
        assert_eq!(country_code("Atlantis"), None);
    }
}
