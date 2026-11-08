//! Everything a search can name: people and pets (not hidden), places with
//! their regions and countries (in German and English), albums.

use std::collections::HashMap;

use super::parse::{Album, Lexicon, Person, PlaceName, fold};
use crate::ApiResult;

/// The lexicon as the library holds it now.
pub(super) async fn lexicon(c: &deadpool_postgres::Object) -> ApiResult<Lexicon> {
    let people = c
        .query(
            "SELECT p.id, p.display_name, p.kind, p.face_count, coalesce(p.is_me, false) FROM persons p
             WHERE p.merged_into IS NULL AND NOT p.hidden AND p.display_name IS NOT NULL",
            &[],
        )
        .await?
        .iter()
        .map(|r| Person {
            id: r.get(0),
            name: r.get(1),
            kind: r.get(2),
            photos: i64::from(r.get::<_, i32>(3)),
            me: r.get(4),
        })
        .collect();
    let rows = c
        .query("SELECT id, name, admin1, cc FROM places", &[])
        .await?;
    let mut by_name: HashMap<String, (String, Vec<i64>)> = HashMap::new();
    let mut add = |name: &str, id: i64| {
        let key = fold(name);
        if key.trim().is_empty() {
            return;
        }
        by_name
            .entry(key)
            .or_insert_with(|| (name.to_string(), Vec::new()))
            .1
            .push(id);
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
            PlaceName { name, places }
        })
        .collect();
    let albums = c
        .query("SELECT id, title FROM albums", &[])
        .await?
        .iter()
        .map(|r| Album {
            id: r.get(0),
            title: r.get(1),
        })
        .collect();
    Ok(Lexicon {
        people,
        places,
        albums,
    })
}

fn capitalized(name: &str) -> String {
    name.split(' ')
        .map(|w| {
            let mut c = w.chars();
            c.next()
                .map(|f| f.to_uppercase().collect::<String>() + c.as_str())
                .unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// ISO 3166 alpha-2 code for a country named in German or English, so
/// "Kroatien" and "Croatia" both find places stored with cc = 'HR'.
pub(super) fn country_code(term: &str) -> Option<&'static str> {
    let needle = term.trim().to_lowercase();
    COUNTRIES
        .iter()
        .find(|(_, names)| names.contains(&needle.as_str()))
        .map(|(code, _)| *code)
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
    (
        "GB",
        &[
            "großbritannien",
            "england",
            "vereinigtes königreich",
            "united kingdom",
            "uk",
            "schottland",
            "scotland",
        ],
    ),
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
    (
        "US",
        &[
            "usa",
            "vereinigte staaten",
            "united states",
            "amerika",
            "america",
        ],
    ),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn countries_resolve_in_both_languages() {
        assert_eq!(country_code("Kroatien"), Some("HR"));
        assert_eq!(country_code(" croatia "), Some("HR"));
        assert_eq!(country_code("Österreich"), Some("AT"));
        assert_eq!(country_code("Atlantis"), None);
    }
}
