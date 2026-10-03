//! Metadata: when and where an asset was taken, and with what.
//!
//! Sources, best first: EXIF (photos) or the container's tags (videos), then
//! a date embedded in the filename. Chat apps strip EXIF but keep names like
//! `IMG-20220513-WA0011.jpg`, which is the only date such a file still has.
//! Every column is fill-NULL: a value that is already there (from a Takeout
//! sidecar or the uploading phone) is never overwritten.

use std::path::Path;
use std::sync::LazyLock;

use anyhow::{Context, Result};
use atlas_core::queue;
use chrono::{DateTime, NaiveDate, NaiveDateTime, Offset, TimeZone, Utc};
use chrono_tz::Tz;
use exif::{In, Tag, Value as ExifValue};
use regex::Regex;
use serde_json::{Map, Value, json};

use super::{preview, video};
use crate::{AppState, util};

#[derive(Default)]
struct Meta {
    taken: Option<DateTime<Utc>>,
    tz_offset_s: Option<i32>,
    source: Option<&'static str>,
    /// EXIF wall-clock time whose UTC offset the camera did not record
    wall_clock: Option<NaiveDateTime>,
    width: Option<i32>,
    height: Option<i32>,
    duration: Option<f64>,
    camera: Option<String>,
    lat: Option<f64>,
    lon: Option<f64>,
    exif: Option<Value>,
    wants_preview: bool,
}

pub async fn run(app: &AppState, id: &str) -> Result<()> {
    let c = app.pool.get().await?;
    let row = c
        .query_opt("SELECT orig_path, type, orig_name, taken_at FROM assets WHERE id = $1", &[&id])
        .await?
        .context("asset is gone")?;
    let original: String = row.get(0);
    let is_video = row.get::<_, &str>(1) == "video";
    let name: String = row.get::<_, Option<String>>(2).unwrap_or_default();
    let known: Option<DateTime<Utc>> = row.get(3);
    drop(c);

    let path = util::confine(&app.cfg.photos_dir, Path::new(&original))
        .await
        .with_context(|| format!("original missing: {original}"))?;
    let tz = app.cfg.tz;
    let mut meta = tokio::task::spawn_blocking(move || if is_video { video_meta(&path) } else { photo_meta(&path) }).await?;
    if let Some(wall_clock) = meta.wall_clock {
        match known {
            // The instant is already known (a Takeout sidecar, the uploading
            // phone): the camera's wall clock then tells which offset it was
            // taken at, so a photo from a trip shows its local time.
            Some(instant) => meta.tz_offset_s = offset_between(wall_clock, instant),
            None => {
                if let Some((taken, offset)) = resolve_local(wall_clock, None, tz) {
                    meta.taken = Some(taken);
                    meta.tz_offset_s = Some(offset);
                    meta.source = Some("exif");
                }
            }
        }
    }
    if meta.taken.is_none()
        && known.is_none()
        && let Some((taken, offset)) = date_from_name(&name, tz)
    {
        meta.taken = Some(taken);
        meta.tz_offset_s = Some(offset);
        meta.source = Some("filename");
    }

    let c = app.pool.get().await?;
    c.execute(
        "UPDATE assets
            SET taken_src   = CASE WHEN taken_at IS NULL AND $2::timestamptz IS NOT NULL THEN $4 ELSE taken_src END,
                tz_offset_s = COALESCE(tz_offset_s, $3),
                taken_at    = COALESCE(taken_at, $2),
                width       = COALESCE(width, $5),
                height      = COALESCE(height, $6),
                duration_s  = COALESCE(duration_s, $7),
                camera      = COALESCE(camera, $8),
                lat         = COALESCE(lat, $9),
                lon         = COALESCE(lon, $10),
                exif        = COALESCE(exif, $11)
          WHERE id = $1",
        &[
            &id, &meta.taken, &meta.tz_offset_s, &meta.source, &meta.width, &meta.height, &meta.duration,
            &meta.camera, &meta.lat, &meta.lon, &meta.exif,
        ],
    )
    .await?;

    let located = c.query_one("SELECT lat IS NOT NULL AND lon IS NOT NULL FROM assets WHERE id = $1", &[&id]).await?;
    if located.get::<_, bool>(0) {
        queue::enqueue(&c, queue::GEOCODE, "asset", id, queue::PRIORITY_DEFAULT).await?;
    }
    if meta.wants_preview && app.cfg.video_previews {
        queue::enqueue(&c, queue::PREVIEW, "asset", id, queue::PRIORITY_BACKGROUND).await?;
    }
    Ok(())
}

fn video_meta(path: &Path) -> Meta {
    let Ok(probe) = video::probe(path) else { return Meta::default() };
    Meta {
        taken: probe.created,
        tz_offset_s: probe.tz_offset_s,
        source: probe.created.map(|_| "exif"),
        width: probe.width,
        height: probe.height,
        duration: probe.duration,
        camera: probe.camera.clone(),
        lat: probe.lat,
        lon: probe.lon,
        wants_preview: preview::wanted(&probe),
        ..Meta::default()
    }
}

/// Unreadable or absent EXIF is not an error: the columns just stay empty.
fn photo_meta(path: &Path) -> Meta {
    let mut meta = Meta::default();
    let Ok(file) = std::fs::File::open(path) else { return meta };
    let Ok(exif) = exif::Reader::new().read_from_container(&mut std::io::BufReader::new(file)) else { return meta };

    let text = |tag: Tag| -> Option<String> {
        match &exif.get_field(tag, In::PRIMARY)?.value {
            ExifValue::Ascii(parts) => {
                let s = String::from_utf8_lossy(parts.first()?).trim().trim_matches('\0').to_string();
                (!s.is_empty()).then_some(s)
            }
            _ => None,
        }
    };
    let number = |tag: Tag| -> Option<f64> {
        match &exif.get_field(tag, In::PRIMARY)?.value {
            ExifValue::Rational(v) => v.first().map(|r| r.to_f64()),
            ExifValue::SRational(v) => v.first().map(|r| r.to_f64()),
            other => other.get_uint(0).map(f64::from),
        }
        .filter(|n| n.is_finite())
    };
    let degrees = |tag: Tag, reference: Tag, negative: &str| -> Option<f64> {
        let ExifValue::Rational(parts) = &exif.get_field(tag, In::PRIMARY)?.value else { return None };
        let value = parts.first()?.to_f64() + parts.get(1).map_or(0.0, |m| m.to_f64() / 60.0) + parts.get(2).map_or(0.0, |s| s.to_f64() / 3600.0);
        let sign = if text(reference).is_some_and(|r| r.eq_ignore_ascii_case(negative)) { -1.0 } else { 1.0 };
        value.is_finite().then_some(sign * value)
    };

    let stamp = [Tag::DateTimeOriginal, Tag::DateTimeDigitized, Tag::DateTime]
        .into_iter()
        .filter_map(text)
        .find_map(|s| NaiveDateTime::parse_from_str(&s, "%Y:%m:%d %H:%M:%S").ok())
        .filter(|t| t.and_utc().timestamp() > 315_532_800); // cameras without a clock say 1970
    if let Some(naive) = stamp {
        let offset = [Tag::OffsetTimeOriginal, Tag::OffsetTimeDigitized, Tag::OffsetTime]
            .into_iter()
            .filter_map(text)
            .find_map(|s| parse_offset(&s));
        match offset {
            Some(offset) => {
                meta.taken = Some(Utc.from_utc_datetime(&(naive - chrono::Duration::seconds(i64::from(offset)))));
                meta.tz_offset_s = Some(offset);
                meta.source = Some("exif");
            }
            None => meta.wall_clock = Some(naive),
        }
    }

    if let (Some(lat), Some(lon)) =
        (degrees(Tag::GPSLatitude, Tag::GPSLatitudeRef, "S"), degrees(Tag::GPSLongitude, Tag::GPSLongitudeRef, "W"))
        && (lat != 0.0 || lon != 0.0) // (0, 0) is a missing fix, not the Gulf of Guinea
        && lat.abs() <= 90.0
        && lon.abs() <= 180.0
    {
        meta.lat = Some(lat);
        meta.lon = Some(lon);
    }
    meta.camera = text(Tag::Model).or_else(|| text(Tag::Make)).map(|s| s.chars().take(120).collect());

    let mut details = Map::new();
    if let Some(iso) = number(Tag::PhotographicSensitivity).filter(|v| *v > 0.0) {
        details.insert("iso".into(), json!(iso as i64));
    }
    if let Some(f) = number(Tag::FNumber).filter(|v| *v > 0.0) {
        details.insert("f_number".into(), json!((f * 10.0).round() / 10.0));
    }
    if let Some(t) = number(Tag::ExposureTime).filter(|v| *v > 0.0) {
        let shown = if t < 1.0 { format!("1/{}", (1.0 / t).round() as i64) } else { format!("{t}") };
        details.insert("exposure_time".into(), json!(shown));
    }
    if let Some(mm) = number(Tag::FocalLength).filter(|v| *v > 0.0) {
        details.insert("focal_len".into(), json!((mm * 10.0).round() / 10.0));
    }
    if let Some(lens) = text(Tag::LensModel) {
        details.insert("lens".into(), json!(lens.chars().take(120).collect::<String>()));
    }
    if !details.is_empty() {
        meta.exif = Some(Value::Object(details));
    }
    meta
}

/// "+02:00" / "-0530" / "Z" -> seconds east of UTC
fn parse_offset(s: &str) -> Option<i32> {
    let s = s.trim();
    if s == "Z" {
        return Some(0);
    }
    let sign = match s.as_bytes().first()? {
        b'+' => 1,
        b'-' => -1,
        _ => return None,
    };
    let digits: String = s[1..].chars().filter(char::is_ascii_digit).collect();
    if digits.len() != 4 {
        return None;
    }
    let (hours, minutes): (i32, i32) = (digits[..2].parse().ok()?, digits[2..].parse().ok()?);
    (hours <= 14 && minutes < 60).then_some(sign * (hours * 3600 + minutes * 60))
}

/// The UTC offset a wall-clock reading implies for a known instant. Real
/// offsets are multiples of 15 minutes within +-14 h; anything else means
/// the camera clock was simply wrong, and no offset is claimed.
fn offset_between(wall_clock: NaiveDateTime, instant: DateTime<Utc>) -> Option<i32> {
    let diff = wall_clock.and_utc().timestamp() - instant.timestamp();
    let rounded = (diff as f64 / 900.0).round() as i64 * 900;
    ((diff - rounded).abs() <= 120 && rounded.abs() <= 14 * 3600).then_some(rounded as i32)
}

/// A wall-clock time to an instant: with the camera's own offset when it
/// recorded one, else read in the library timezone.
fn resolve_local(naive: NaiveDateTime, offset: Option<i32>, tz: Tz) -> Option<(DateTime<Utc>, i32)> {
    match offset {
        Some(offset) => Some((Utc.from_utc_datetime(&(naive - chrono::Duration::seconds(i64::from(offset)))), offset)),
        None => {
            let local = tz.from_local_datetime(&naive).earliest()?;
            Some((local.with_timezone(&Utc), local.offset().fix().local_minus_utc()))
        }
    }
}

static NAME_DATETIME: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:^|[^0-9])((?:19|20)\d{2})[-_.]?(\d{2})[-_.]?(\d{2})(?:[-_ T]| at )?(\d{2})[-_.:h]?(\d{2})[-_.:m]?(\d{2})(?:\d{3})?(?:[^0-9]|$)").unwrap()
});
static NAME_DATE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:^|[^0-9])((?:19|20)\d{2})[-_.]?(\d{2})[-_.]?(\d{2})(?:[^0-9]|$)").unwrap());
static NAME_MILLIS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?:^|[^0-9])(1\d{12})(?:[^0-9]|$)").unwrap());

/// The capture time a filename states, read in the library timezone:
///
///   IMG_20190812_123456.jpg, PXL_20210101_123456789.jpg, DJI_20210618_201649_199.jpg
///   Screenshot 2021-03-04 at 10.11.12.png, WhatsApp Image 2021-03-04 at 10.11.12.jpeg
///   IMG-20220513-WA0011.jpg (date only: noon)
///   FaceApp_1632594440518.jpg (unix milliseconds)
pub fn date_from_name(name: &str, tz: Tz) -> Option<(DateTime<Utc>, i32)> {
    let plausible = |date: NaiveDate| {
        let latest = Utc::now().date_naive() + chrono::Duration::days(1);
        (NaiveDate::from_ymd_opt(1995, 1, 1).unwrap()..=latest).contains(&date)
    };
    let field = |caps: &regex::Captures, i: usize| caps[i].parse::<u32>().ok();

    if let Some(caps) = NAME_DATETIME.captures(name)
        && let Some(date) = NaiveDate::from_ymd_opt(caps[1].parse().ok()?, field(&caps, 2)?, field(&caps, 3)?)
        && let Some(time) = date.and_hms_opt(field(&caps, 4)?, field(&caps, 5)?, field(&caps, 6)?)
        && plausible(date)
    {
        return resolve_local(time, None, tz);
    }
    if let Some(caps) = NAME_DATE.captures(name)
        && let Some(date) = NaiveDate::from_ymd_opt(caps[1].parse().ok()?, field(&caps, 2)?, field(&caps, 3)?)
        && plausible(date)
    {
        return resolve_local(date.and_hms_opt(12, 0, 0)?, None, tz);
    }
    if let Some(caps) = NAME_MILLIS.captures(name)
        && let Some(instant) = DateTime::from_timestamp_millis(caps[1].parse().ok()?)
        && plausible(instant.date_naive())
    {
        let offset = instant.with_timezone(&tz).offset().fix().local_minus_utc();
        return Some((instant, offset));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn berlin() -> Tz {
        "Europe/Berlin".parse().unwrap()
    }

    fn local(name: &str) -> Option<String> {
        date_from_name(name, berlin())
            .map(|(utc, offset)| (utc + chrono::Duration::seconds(i64::from(offset))).format("%Y-%m-%d %H:%M:%S").to_string())
    }

    #[test]
    fn camera_and_screenshot_names_carry_a_full_timestamp() {
        assert_eq!(local("IMG_20190812_123456.jpg").as_deref(), Some("2019-08-12 12:34:56"));
        assert_eq!(local("DJI_20210618_201649_199.jpg").as_deref(), Some("2021-06-18 20:16:49"));
        assert_eq!(local("PXL_20210101_123456789.jpg").as_deref(), Some("2021-01-01 12:34:56"));
        assert_eq!(local("lv_7148036206683524358_20230101122755.mp4").as_deref(), Some("2023-01-01 12:27:55"));
        assert_eq!(local("Screenshot 2021-03-04 at 10.11.12.png").as_deref(), Some("2021-03-04 10:11:12"));
        assert_eq!(local("WhatsApp Image 2021-03-04 at 10.11.12.jpeg").as_deref(), Some("2021-03-04 10:11:12"));
    }

    #[test]
    fn chat_app_names_carry_a_date() {
        assert_eq!(local("IMG-20220513-WA0011.jpg").as_deref(), Some("2022-05-13 12:00:00"));
        assert_eq!(local("VID-20200502-WA0026.mp4").as_deref(), Some("2020-05-02 12:00:00"));
    }

    #[test]
    fn epoch_milliseconds_are_recognized() {
        assert_eq!(local("FaceApp_1632594440518.jpg").as_deref(), Some("2021-09-25 20:27:20"));
    }

    #[test]
    fn numbers_that_are_not_dates_are_left_alone() {
        assert_eq!(local("Snapchat-826176582.jpg"), None);
        assert_eq!(local("IMG_1501.PNG"), None);
        assert_eq!(local("20231345_999999.jpg"), None);
        assert_eq!(local("photo.jpg"), None);
    }

    #[test]
    fn the_stored_instant_is_utc() {
        // 12:34:56 in Berlin in August is 10:34:56 UTC
        let (utc, offset) = date_from_name("IMG_20190812_123456.jpg", berlin()).unwrap();
        assert_eq!(utc.format("%H:%M:%S").to_string(), "10:34:56");
        assert_eq!(offset, 7200);
    }

    #[test]
    fn a_known_instant_reveals_the_cameras_offset() {
        let instant = Utc.with_ymd_and_hms(2024, 7, 14, 3, 30, 5).unwrap();
        let bangkok = NaiveDate::from_ymd_opt(2024, 7, 14).unwrap().and_hms_opt(10, 30, 0).unwrap();
        assert_eq!(offset_between(bangkok, instant), Some(7 * 3600));
        // a clock that is 40 minutes off is not a timezone
        let wrong = NaiveDate::from_ymd_opt(2024, 7, 14).unwrap().and_hms_opt(4, 10, 0).unwrap();
        assert_eq!(offset_between(wrong, instant), None);
    }

    #[test]
    fn exif_offsets_parse() {
        assert_eq!(parse_offset("+02:00"), Some(7200));
        assert_eq!(parse_offset("-0530"), Some(-19800));
        assert_eq!(parse_offset("Z"), Some(0));
        assert_eq!(parse_offset("nonsense"), None);
    }
}
