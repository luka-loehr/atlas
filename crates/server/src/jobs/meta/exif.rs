//! A photo's EXIF: capture time and offset, location, camera, exposure.

use std::path::Path;

use ::exif::{In, Tag, Value as ExifValue};
use chrono::NaiveDateTime;
use serde_json::{Map, Value, json};

use super::Meta;
use super::time::at_offset;

/// Unreadable or absent EXIF is not an error: the columns just stay empty.
pub(super) fn photo_meta(path: &Path) -> Meta {
    let mut meta = Meta::default();
    let Ok(file) = std::fs::File::open(path) else { return meta };
    let Ok(exif) = ::exif::Reader::new().read_from_container(&mut std::io::BufReader::new(file)) else { return meta };

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
                meta.taken = Some(at_offset(naive, offset));
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exif_offsets_parse() {
        assert_eq!(parse_offset("+02:00"), Some(7200));
        assert_eq!(parse_offset("-0530"), Some(-19800));
        assert_eq!(parse_offset("Z"), Some(0));
        assert_eq!(parse_offset("nonsense"), None);
    }
}
