//! The photo library API.
//!
//!   GET  /v1/server                       who am I talking to
//!   GET  /v1/stats                        library and storage totals
//!   GET  /v1/timeline                     bucket index (month, count, etag)
//!   GET  /v1/timeline/{month}             one month, columnar
//!   PUT  /v1/assets                       streaming upload
//!   POST /v1/assets/exists                which hashes the library has
//!   GET  /v1/assets/{id}                  everything for the info sheet
//!   GET  /v1/assets/{id}/thumb/{size}     WebP, immutable (512 | 2048)
//!   GET  /v1/assets/{id}/original         the exact bytes, Range-capable
//!   GET  /v1/assets/{id}/video            streaming rendition, else original
//!   POST /v1/assets/{favorite,archive,lock,trash,restore,delete}
//!   GET  /v1/library/{favorites,videos,archive,locked,trash}
//!   POST /v1/library/trash/empty
//!   GET/POST /v1/albums, GET/PATCH/DELETE /v1/albums/{id},
//!   POST/DELETE /v1/albums/{id}/assets
//!   GET  /v1/people, GET/PATCH /v1/people/{id}, POST /v1/people/{id}/merge
//!   GET  /v1/faces/{id}/crop
//!   GET  /v1/places, GET /v1/places/{id}
//!   GET  /v1/search?q=                    people, places, albums + semantic

pub mod albums;
pub mod assets;
pub mod library;
pub mod people;
pub mod search;
pub mod timeline;
pub mod vectors;

use axum::Router;
use axum::routing::{get, post, put};
use chrono::{DateTime, Utc};
use chrono_tz::Tz;
use serde::{Deserialize, Serialize};
use tokio_postgres::Row;

use crate::AppState;

/// Archived, trashed and locked assets live in their own views and stay out
/// of the timeline, search and every browse list.
pub const VISIBLE: &str = "NOT assets.archived AND assets.trashed_at IS NULL AND NOT assets.locked";

/// The columns every asset list is built from. Always in this order.
pub const COLS: &str = "assets.id, assets.type, assets.taken_at, assets.tz_offset_s, assets.width, \
                        assets.height, assets.duration_s, assets.favorite, assets.thumbhash";

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/server", get(library::server))
        .route("/stats", get(library::stats))
        .route("/timeline", get(timeline::index))
        .route("/timeline/{bucket}", get(timeline::bucket))
        .route("/assets", put(assets::upload))
        .route("/assets/exists", post(assets::exists))
        .route("/assets/favorite", post(assets::favorite))
        .route("/assets/archive", post(assets::archive))
        .route("/assets/lock", post(assets::lock))
        .route("/assets/trash", post(assets::trash))
        .route("/assets/restore", post(assets::restore))
        .route("/assets/delete", post(assets::delete))
        .route("/assets/{id}", get(assets::info))
        .route("/assets/{id}/thumb/{size}", get(assets::thumb))
        .route("/assets/{id}/original", get(assets::original))
        .route("/assets/{id}/video", get(assets::video))
        .route("/library/trash/empty", post(assets::empty_trash))
        .route("/library/{view}", get(library::view))
        .route("/albums", get(albums::list).post(albums::create))
        .route("/albums/{id}", get(albums::assets).patch(albums::rename).delete(albums::remove))
        .route("/albums/{id}/assets", post(albums::add_assets).delete(albums::remove_assets))
        .route("/people", get(people::list))
        .route("/people/{id}", get(people::assets).patch(people::update))
        .route("/people/{id}/merge", post(people::merge))
        .route("/faces/{id}/crop", get(people::face_crop))
        .route("/places", get(library::places))
        .route("/places/{id}", get(library::place_assets))
        .route("/search", get(search::search))
        .route("/search/warm", post(search::warm))
}

/// Wall-clock seconds at the place the photo was taken, encoded as if they
/// were UTC. The client groups by day and formats with a UTC calendar, so no
/// device timezone can move a photo to another day. Uses the asset's own
/// offset when the camera recorded one, else the library timezone.
pub fn local_seconds(taken: DateTime<Utc>, offset_s: Option<i32>, tz: Tz) -> i64 {
    match offset_s {
        Some(offset) => taken.timestamp() + i64::from(offset),
        None => taken.with_timezone(&tz).naive_local().and_utc().timestamp(),
    }
}

/// One asset as the lists carry it.
pub struct Item {
    pub id: String,
    pub video: bool,
    /// None = no capture date known.
    pub local: Option<i64>,
    pub width: i32,
    pub height: i32,
    pub duration: f64,
    pub favorite: bool,
    pub thumbhash: Option<Vec<u8>>,
}

impl Item {
    /// From a row selected with [`COLS`].
    pub fn from_row(r: &Row, tz: Tz) -> Self {
        let taken: Option<DateTime<Utc>> = r.get(2);
        Item {
            id: r.get(0),
            video: r.get::<_, &str>(1) == "video",
            local: taken.map(|t| local_seconds(t, r.get(3), tz)),
            width: r.get::<_, Option<i32>>(4).unwrap_or(0),
            height: r.get::<_, Option<i32>>(5).unwrap_or(0),
            duration: r.get::<_, Option<f64>>(6).unwrap_or(0.0),
            favorite: r.get::<_, Option<bool>>(7).unwrap_or(false),
            thumbhash: r.get(8),
        }
    }
}

/// An asset list in columnar form: one array per field, index-aligned. A
/// third the size of an array of objects, and it compresses far better.
#[derive(Serialize, Default)]
pub struct Columns {
    pub id: Vec<String>,
    /// local wall-clock seconds, 0 = undated
    pub t: Vec<i64>,
    pub w: Vec<i32>,
    pub h: Vec<i32>,
    /// 1 = video
    pub v: Vec<u8>,
    /// duration in seconds, 0 for photos
    pub d: Vec<f32>,
    /// 1 = favorite
    pub f: Vec<u8>,
    /// thumbhash, base64 ("" until the thumbnail job ran)
    pub p: Vec<String>,
}

impl Columns {
    pub fn push(&mut self, item: Item) {
        use base64::Engine;
        self.t.push(item.local.unwrap_or(0));
        self.w.push(item.width);
        self.h.push(item.height);
        self.v.push(item.video as u8);
        self.d.push(item.duration as f32);
        self.f.push(item.favorite as u8);
        self.p.push(
            item.thumbhash
                .map(|h| base64::engine::general_purpose::STANDARD_NO_PAD.encode(h))
                .unwrap_or_default(),
        );
        self.id.push(item.id);
    }

    pub fn from_rows(rows: &[Row], tz: Tz) -> Self {
        let mut columns = Columns::default();
        for row in rows {
            columns.push(Item::from_row(row, tz));
        }
        columns
    }
}

#[derive(Deserialize)]
pub struct Ids {
    pub ids: Vec<String>,
}

#[derive(Deserialize)]
pub struct IdsValue {
    pub ids: Vec<String>,
    pub value: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn local_time_prefers_the_cameras_own_offset() {
        let berlin: Tz = "Europe/Berlin".parse().unwrap();
        // 2024-07-31 23:30 UTC is already August 1st in Berlin (UTC+2)
        let taken = Utc.with_ymd_and_hms(2024, 7, 31, 23, 30, 0).unwrap();
        let local = local_seconds(taken, None, berlin);
        assert_eq!(DateTime::from_timestamp(local, 0).unwrap().format("%Y-%m-%d %H:%M").to_string(), "2024-08-01 01:30");
        // taken in New York (UTC-4): still July 31st there
        let local = local_seconds(taken, Some(-4 * 3600), berlin);
        assert_eq!(DateTime::from_timestamp(local, 0).unwrap().format("%Y-%m-%d %H:%M").to_string(), "2024-07-31 19:30");
    }
}
