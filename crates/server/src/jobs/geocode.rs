//! Reverse geocoding, offline: coordinates to the nearest GeoNames city.

use std::sync::LazyLock;

use anyhow::{Context, Result};
use reverse_geocoder::ReverseGeocoder;

use crate::AppState;

/// The city list and its k-d tree, built on first use.
static GEOCODER: LazyLock<ReverseGeocoder> = LazyLock::new(ReverseGeocoder::new);

pub async fn run(app: &AppState, id: &str) -> Result<()> {
    let mut c = app.pool.get().await?;
    let row = c.query_opt("SELECT lat, lon FROM assets WHERE id = $1", &[&id]).await?.context("asset is gone")?;
    let (Some(lat), Some(lon)): (Option<f64>, Option<f64>) = (row.get(0), row.get(1)) else {
        return Ok(());
    };

    let (name, region, country, place_lat, place_lon) = tokio::task::spawn_blocking(move || {
        let record = GEOCODER.search((lat, lon)).record;
        (record.name.clone(), record.admin1.clone(), record.cc.clone(), record.lat, record.lon)
    })
    .await?;

    let place: i64 = c
        .query_one(
            "INSERT INTO places (name, admin1, cc, lat, lon) VALUES ($1, $2, $3, $4, $5)
             ON CONFLICT (name, admin1, cc) DO UPDATE SET name = EXCLUDED.name
             RETURNING id",
            &[&name, &region, &country, &place_lat, &place_lon],
        )
        .await?
        .get(0);

    let tx = c.transaction().await?;
    tx.execute(
        "DELETE FROM edges WHERE src_type = 'asset' AND src_id = $1 AND rel = 'taken_at' AND dst_type = 'place'",
        &[&id],
    )
    .await?;
    tx.execute(
        "INSERT INTO edges (src_type, src_id, rel, dst_type, dst_id, confidence)
         VALUES ('asset', $1, 'taken_at', 'place', $2, 1.0)",
        &[&id, &place.to_string()],
    )
    .await?;
    tx.commit().await?;
    Ok(())
}
