//! Times a search names: years, months, seasons, Christmas, "last summer",
//! "this year", today and yesterday, in English and German.

use chrono::{Datelike, NaiveDate};

/// A span of local time, inclusive start, exclusive end.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum When {
    Range { from: NaiveDate, to: NaiveDate, label: String },
    /// these months of any year
    Months { months: Vec<u32>, label: String },
}

impl When {
    pub fn label(&self) -> &str {
        match self {
            When::Range { label, .. } | When::Months { label, .. } => label,
        }
    }
}

const MONTHS: [(&[&str], u32); 12] = [
    (&["january", "januar", "jan", "jänner"], 1),
    (&["february", "februar", "feb"], 2),
    (&["march", "märz", "marz", "mar"], 3),
    (&["april", "apr"], 4),
    (&["may", "mai"], 5),
    (&["june", "juni", "jun"], 6),
    (&["july", "juli", "jul"], 7),
    (&["august", "aug"], 8),
    (&["september", "sept", "sep"], 9),
    (&["october", "oktober", "oct", "okt"], 10),
    (&["november", "nov"], 11),
    (&["december", "dezember", "dec", "dez"], 12),
];

/// A date at the start of `tokens`, and how many tokens it took.
pub(super) fn date(tokens: &[String], today: NaiveDate) -> Option<(When, usize)> {
    let year = |t: &str| t.parse::<i32>().ok().filter(|y| (1900..=2100).contains(y));
    let first = tokens[0].as_str();
    let next_year = tokens.get(1).and_then(|t| year(t));
    let ymd = |y: i32, m: u32| NaiveDate::from_ymd_opt(y, m, 1);
    let range = |from: NaiveDate, to: NaiveDate, label: String| When::Range { from, to, label };

    if let Some(y) = year(first) {
        return Some((range(ymd(y, 1)?, ymd(y + 1, 1)?, y.to_string()), 1));
    }
    if let Some(&(_, m)) = MONTHS.iter().find(|(names, _)| names.contains(&first)) {
        let label = |y: Option<i32>| {
            let name = month_name(m);
            y.map_or(name.to_string(), |y| format!("{name} {y}"))
        };
        return Some(match next_year {
            Some(y) => {
                let end = if m == 12 { ymd(y + 1, 1)? } else { ymd(y, m + 1)? };
                (range(ymd(y, m)?, end, label(Some(y))), 2)
            }
            None => (When::Months { months: vec![m], label: label(None) }, 1),
        });
    }
    let season: Option<(&str, [u32; 3])> = match first {
        "summer" | "sommer" => Some(("Summer", [6, 7, 8])),
        "winter" => Some(("Winter", [12, 1, 2])),
        "spring" | "frühling" | "fruhling" => Some(("Spring", [3, 4, 5])),
        "autumn" | "fall" | "herbst" => Some(("Autumn", [9, 10, 11])),
        _ => None,
    };
    if let Some((name, months)) = season {
        return Some(match next_year {
            // winter 2023: December 2023 to February 2024
            Some(y) if months[0] == 12 => (range(ymd(y, 12)?, ymd(y + 1, 3)?, format!("{name} {y}")), 2),
            Some(y) => (range(ymd(y, months[0])?, ymd(y, months[2] + 1)?, format!("{name} {y}")), 2),
            None => (When::Months { months: months.to_vec(), label: name.to_string() }, 1),
        });
    }
    if matches!(first, "christmas" | "weihnachten" | "xmas") {
        return Some(match next_year {
            Some(y) => (
                range(NaiveDate::from_ymd_opt(y, 12, 20)?, NaiveDate::from_ymd_opt(y, 12, 27)?, format!("Christmas {y}")),
                2,
            ),
            None => (When::Months { months: vec![12], label: "December".into() }, 1),
        });
    }
    let second = tokens.get(1).map(String::as_str);
    let y = today.year();
    // "last summer", "this august", "letzten sommer": the season or month
    // of a particular year. "last" is the latest one that is over (in
    // November, last summer is this year's), "this" the one of this year.
    let last = matches!(first, "last" | "letztes" | "letzten" | "letzter");
    let this = matches!(first, "this" | "dieses" | "diesem" | "diesen");
    if (last || this)
        && tokens.len() > 1
        && let Some((When::Months { months, label }, 1)) = date(&tokens[1..], today)
    {
        let span = |y: i32| -> Option<(NaiveDate, NaiveDate)> {
            let (m0, m1) = (months[0], *months.last()?);
            let from = ymd(y, m0)?;
            let to_year = if m1 < m0 { y + 1 } else { y };
            let to = if m1 == 12 { ymd(to_year + 1, 1)? } else { ymd(to_year, m1 + 1)? };
            Some((from, to))
        };
        let mut year = y;
        if last {
            // not one that is still going on or yet to come
            while span(year).is_some_and(|(_, to)| to > today) {
                year -= 1;
            }
        } else if months[0] == 12 && today.month() <= 2 {
            // in January, this winter began last December
            year -= 1;
        }
        let (from, to) = span(year)?;
        return Some((range(from, to, format!("{label} {year}")), 2));
    }
    match (first, second) {
        ("last" | "letztes" | "letzten", Some("year" | "jahr")) => Some((range(ymd(y - 1, 1)?, ymd(y, 1)?, (y - 1).to_string()), 2)),
        ("this" | "dieses" | "diesem", Some("year" | "jahr")) => Some((range(ymd(y, 1)?, ymd(y + 1, 1)?, y.to_string()), 2)),
        ("today" | "heute", _) => Some((range(today, today.succ_opt()?, "Today".into()), 1)),
        ("yesterday" | "gestern", _) => Some((range(today.pred_opt()?, today, "Yesterday".into()), 1)),
        _ => None,
    }
}

fn month_name(m: u32) -> &'static str {
    [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
    ][(m - 1) as usize]
}
