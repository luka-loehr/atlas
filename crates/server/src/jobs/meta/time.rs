//! Capture times: offsets, wall clocks read in a timezone, and the dates
//! filenames carry.

use std::sync::LazyLock;

use chrono::{DateTime, NaiveDate, NaiveDateTime, Offset, TimeZone, Utc};
use chrono_tz::Tz;
use regex::Regex;

/// The UTC offset a wall-clock reading implies for a known instant. Real
/// offsets are multiples of 15 minutes within +-14 h; anything else means
/// the camera clock was simply wrong, and no offset is claimed.
pub(super) fn offset_between(wall_clock: NaiveDateTime, instant: DateTime<Utc>) -> Option<i32> {
    let diff = wall_clock.and_utc().timestamp() - instant.timestamp();
    let rounded = (diff as f64 / 900.0).round() as i64 * 900;
    ((diff - rounded).abs() <= 120 && rounded.abs() <= 14 * 3600).then_some(rounded as i32)
}

/// A wall-clock time whose offset the camera did not record, read in the
/// library timezone: the instant and the offset it was at.
pub(super) fn resolve_local(naive: NaiveDateTime, tz: Tz) -> Option<(DateTime<Utc>, i32)> {
    let local = tz.from_local_datetime(&naive).earliest()?;
    Some((
        local.with_timezone(&Utc),
        local.offset().fix().local_minus_utc(),
    ))
}

static NAME_DATETIME: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:^|[^0-9])((?:19|20)\d{2})[-_.]?(\d{2})[-_.]?(\d{2})(?:[-_ T]| at )?(\d{2})[-_.:h]?(\d{2})[-_.:m]?(\d{2})(?:\d{3})?(?:[^0-9]|$)").unwrap()
});
static NAME_DATE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:^|[^0-9])((?:19|20)\d{2})[-_.]?(\d{2})[-_.]?(\d{2})(?:[^0-9]|$)").unwrap()
});
static NAME_MILLIS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?:^|[^0-9])(1\d{12})(?:[^0-9]|$)").unwrap());

/// The capture time a filename states, read in the library timezone:
///
///   IMG_20190812_123456.jpg, PXL_20210101_123456789.jpg, DJI_20210618_201649_199.jpg
///   Screenshot 2021-03-04 at 10.11.12.png, WhatsApp Image 2021-03-04 at 10.11.12.jpeg
///   IMG-20220513-WA0011.jpg (date only: noon)
///   FaceApp_1632594440518.jpg (unix milliseconds)
pub(super) fn date_from_name(name: &str, tz: Tz) -> Option<(DateTime<Utc>, i32)> {
    let plausible = |date: NaiveDate| {
        let latest = Utc::now().date_naive() + chrono::Duration::days(1);
        (NaiveDate::from_ymd_opt(1995, 1, 1).unwrap()..=latest).contains(&date)
    };
    let field = |caps: &regex::Captures, i: usize| caps[i].parse::<u32>().ok();

    if let Some(caps) = NAME_DATETIME.captures(name)
        && let Some(date) =
            NaiveDate::from_ymd_opt(caps[1].parse().ok()?, field(&caps, 2)?, field(&caps, 3)?)
        && let Some(time) = date.and_hms_opt(field(&caps, 4)?, field(&caps, 5)?, field(&caps, 6)?)
        && plausible(date)
    {
        return resolve_local(time, tz);
    }
    if let Some(caps) = NAME_DATE.captures(name)
        && let Some(date) =
            NaiveDate::from_ymd_opt(caps[1].parse().ok()?, field(&caps, 2)?, field(&caps, 3)?)
        && plausible(date)
    {
        return resolve_local(date.and_hms_opt(12, 0, 0)?, tz);
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

/// The instant a wall-clock reading is at a known UTC offset.
pub(super) fn at_offset(naive: NaiveDateTime, offset: i32) -> DateTime<Utc> {
    Utc.from_utc_datetime(&(naive - chrono::Duration::seconds(i64::from(offset))))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn berlin() -> Tz {
        "Europe/Berlin".parse().unwrap()
    }

    fn local(name: &str) -> Option<String> {
        date_from_name(name, berlin()).map(|(utc, offset)| {
            (utc + chrono::Duration::seconds(i64::from(offset)))
                .format("%Y-%m-%d %H:%M:%S")
                .to_string()
        })
    }

    #[test]
    fn camera_and_screenshot_names_carry_a_full_timestamp() {
        assert_eq!(
            local("IMG_20190812_123456.jpg").as_deref(),
            Some("2019-08-12 12:34:56")
        );
        assert_eq!(
            local("DJI_20210618_201649_199.jpg").as_deref(),
            Some("2021-06-18 20:16:49")
        );
        assert_eq!(
            local("PXL_20210101_123456789.jpg").as_deref(),
            Some("2021-01-01 12:34:56")
        );
        assert_eq!(
            local("lv_7148036206683524358_20230101122755.mp4").as_deref(),
            Some("2023-01-01 12:27:55")
        );
        assert_eq!(
            local("Screenshot 2021-03-04 at 10.11.12.png").as_deref(),
            Some("2021-03-04 10:11:12")
        );
        assert_eq!(
            local("WhatsApp Image 2021-03-04 at 10.11.12.jpeg").as_deref(),
            Some("2021-03-04 10:11:12")
        );
    }

    #[test]
    fn chat_app_names_carry_a_date() {
        assert_eq!(
            local("IMG-20220513-WA0011.jpg").as_deref(),
            Some("2022-05-13 12:00:00")
        );
        assert_eq!(
            local("VID-20200502-WA0026.mp4").as_deref(),
            Some("2020-05-02 12:00:00")
        );
    }

    #[test]
    fn epoch_milliseconds_are_recognized() {
        assert_eq!(
            local("FaceApp_1632594440518.jpg").as_deref(),
            Some("2021-09-25 20:27:20")
        );
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
        let bangkok = NaiveDate::from_ymd_opt(2024, 7, 14)
            .unwrap()
            .and_hms_opt(10, 30, 0)
            .unwrap();
        assert_eq!(offset_between(bangkok, instant), Some(7 * 3600));
        // a clock that is 40 minutes off is not a timezone
        let wrong = NaiveDate::from_ymd_opt(2024, 7, 14)
            .unwrap()
            .and_hms_opt(4, 10, 0)
            .unwrap();
        assert_eq!(offset_between(wrong, instant), None);
    }
}
