//! Reading a search: which words name someone, somewhere, some time, and
//! which are left to describe what the photo shows.
//!
//!   "alex and sam"            two people: photos with both
//!   "alex and rex"            a person and a pet
//!   "alex in spain"           a person and a country
//!   "sam summer 2024"         a person and a season of a year
//!   "videos of rex"           a pet, videos only
//!   "alex at the beach"       a person, ranked by how much it looks like a beach
//!   "timetable"               nothing named: the text in images and the look
//!
//! Names are matched longest first ("Anna Maria" before "Anna"), case and
//! accents ignored; a first name finds the person whose name starts with it
//! (the most photographed one if several do). "me", "ich" and "mich" are the
//! owner. Words joining the parts ("and", "with", "in", "und", "mit", ...)
//! are dropped.

use chrono::NaiveDate;

use super::dates::{When, date};

/// A person or pet that can be named.
pub struct Person {
    pub id: i64,
    pub name: String,
    pub kind: String,
    pub photos: i64,
    pub me: bool,
}

/// A name of a place, and every place it covers (a country covers all of
/// its places).
pub struct PlaceName {
    pub name: String,
    pub places: Vec<i64>,
}

pub struct Album {
    pub id: i64,
    pub title: String,
}

/// Everything a search can name.
#[derive(Default)]
pub struct Lexicon {
    pub people: Vec<Person>,
    pub places: Vec<PlaceName>,
    pub albums: Vec<Album>,
}

#[derive(Debug, Default, PartialEq)]
pub struct Parsed {
    /// people and pets that must all be in a photo: (id, name, kind)
    pub people: Vec<(i64, String, String)>,
    /// place names, each a set of places, any of which will do: (name, ids)
    pub places: Vec<(String, Vec<i64>)>,
    pub albums: Vec<(i64, String)>,
    pub when: Option<When>,
    pub videos: bool,
    /// what is left: the look, and text in the image
    pub text: Option<String>,
}

impl Parsed {
    pub fn has_filters(&self) -> bool {
        !self.people.is_empty()
            || !self.places.is_empty()
            || !self.albums.is_empty()
            || self.when.is_some()
            || self.videos
    }
}

const JOINERS: &[&str] = &[
    "and", "und", "&", "+", "with", "mit", "in", "im", "at", "am", "an", "on", "auf", "of", "von",
    "the", "a", "der", "die", "das", "den", "dem", "ein", "eine", "from", "aus", "bei", "beim",
    "during", "while", "together", "zusammen", "photos", "photo", "pictures", "picture", "pics",
    "pic", "images", "image", "fotos", "foto", "bilder", "bild", "all", "alle",
];
const ME: &[&str] = &["me", "myself", "ich", "mich", "mir"];
const VIDEOS: &[&str] = &["video", "videos", "clip", "clips", "film", "filme"];

/// Lowercase, accents kept but compared loosely, punctuation as spaces.
pub fn fold(text: &str) -> String {
    text.chars()
        .map(|c| match c {
            'á' | 'à' | 'â' => 'a',
            'é' | 'è' | 'ê' | 'ë' => 'e',
            'í' | 'ì' | 'î' | 'ï' => 'i',
            'ó' | 'ò' | 'ô' => 'o',
            'ú' | 'ù' | 'û' => 'u',
            'č' | 'ć' => 'c',
            'š' => 's',
            'ž' => 'z',
            'đ' => 'd',
            c if c.is_alphanumeric() || c == '&' || c == '+' => c,
            _ => ' ',
        })
        .collect::<String>()
        .to_lowercase()
}

fn words(text: &str) -> Vec<String> {
    fold(text).split_whitespace().map(str::to_string).collect()
}

pub fn parse(query: &str, lexicon: &Lexicon, today: NaiveDate) -> Parsed {
    let tokens = words(query);
    let mut parsed = Parsed::default();
    // what each token became: None while unclaimed
    let mut claimed = vec![false; tokens.len()];

    // names of people, places and albums: longest spans first
    let person_names: Vec<(Vec<String>, usize)> = lexicon
        .people
        .iter()
        .enumerate()
        .map(|(i, p)| (words(&p.name), i))
        .filter(|(w, _)| !w.is_empty())
        .collect();
    for len in (1..=4).rev() {
        let mut at = 0;
        while at + len <= tokens.len() {
            if claimed[at..at + len].iter().any(|c| *c) {
                at += 1;
                continue;
            }
            let span = &tokens[at..at + len];
            if let Some(person) = find_person(span, &person_names, lexicon) {
                if !parsed.people.iter().any(|(id, _, _)| *id == person.id) {
                    parsed
                        .people
                        .push((person.id, person.name.clone(), person.kind.clone()));
                }
            } else if let Some(place) = lexicon.places.iter().find(|p| words(&p.name) == span) {
                if !parsed.places.iter().any(|(name, _)| *name == place.name) {
                    parsed
                        .places
                        .push((place.name.clone(), place.places.clone()));
                }
            } else if let Some(album) = lexicon
                .albums
                .iter()
                .find(|a| len >= 1 && words(&a.title) == span && !is_common(span))
            {
                parsed.albums.push((album.id, album.title.clone()));
            } else {
                at += 1;
                continue;
            }
            claimed[at..at + len].iter_mut().for_each(|c| *c = true);
            at += len;
        }
    }

    // the owner, dates, videos
    let mut i = 0;
    while i < tokens.len() {
        if claimed[i] {
            i += 1;
            continue;
        }
        let t = tokens[i].as_str();
        if ME.contains(&t) {
            if let Some(me) = lexicon.people.iter().find(|p| p.me)
                && !parsed.people.iter().any(|(id, _, _)| *id == me.id)
            {
                parsed
                    .people
                    .push((me.id, me.name.clone(), me.kind.clone()));
            }
            claimed[i] = true;
        } else if VIDEOS.contains(&t) {
            parsed.videos = true;
            claimed[i] = true;
        } else if parsed.when.is_none()
            && let Some((when, used)) = date(&tokens[i..], today)
        {
            parsed.when = Some(when);
            claimed[i..i + used].iter_mut().for_each(|c| *c = true);
            i += used;
            continue;
        }
        i += 1;
    }

    // the rest describes the photo; joining words at its ends say nothing
    let rest: Vec<&str> = tokens
        .iter()
        .zip(&claimed)
        .filter(|(_, c)| !**c)
        .map(|(t, _)| t.as_str())
        .collect();
    let start = rest.iter().position(|t| !JOINERS.contains(t));
    let end = rest.iter().rposition(|t| !JOINERS.contains(t));
    if let (Some(start), Some(end)) = (start, end) {
        // between named parts the joining words go too ("alex and sam at the
        // beach" leaves "beach")
        let text: Vec<&str> = rest[start..=end]
            .iter()
            .copied()
            .filter(|t| !JOINERS.contains(t))
            .collect();
        if !text.is_empty() {
            parsed.text = Some(text.join(" "));
        }
    }
    parsed
}

/// Words too common to be taken as an album's name on their own.
fn is_common(span: &[String]) -> bool {
    span.len() == 1 && (JOINERS.contains(&span[0].as_str()) || span[0].len() < 3)
}

fn find_person<'a>(
    span: &[String],
    names: &[(Vec<String>, usize)],
    lexicon: &'a Lexicon,
) -> Option<&'a Person> {
    // the whole name
    if let Some((_, i)) = names.iter().find(|(w, _)| w.as_slice() == span) {
        return Some(&lexicon.people[*i]);
    }
    // a first name (or the first words of a longer name)
    if span.len() == 1 && span[0].len() < 2 {
        return None;
    }
    names
        .iter()
        .filter(|(w, _)| w.len() > span.len() && w[..span.len()] == *span)
        .map(|(_, i)| &lexicon.people[*i])
        .max_by_key(|p| p.photos)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lexicon() -> Lexicon {
        let p = |id, name: &str, kind: &str, photos, me| Person {
            id,
            name: name.into(),
            kind: kind.into(),
            photos,
            me,
        };
        Lexicon {
            people: vec![
                p(1, "Alex", "person", 3000, true),
                p(2, "Sam Weber", "person", 120, false),
                p(3, "Rex", "dog", 300, false),
                p(4, "Anna Maria", "person", 40, false),
                p(5, "Anna", "person", 10, false),
                p(6, "Sam Klein", "person", 5, false),
            ],
            places: vec![
                PlaceName {
                    name: "Spain".into(),
                    places: vec![10, 11],
                },
                PlaceName {
                    name: "Spanien".into(),
                    places: vec![10, 11],
                },
                PlaceName {
                    name: "Port Vela".into(),
                    places: vec![11],
                },
                PlaceName {
                    name: "Lyon".into(),
                    places: vec![20],
                },
            ],
            albums: vec![Album {
                id: 7,
                title: "Canyon Rafting".into(),
            }],
        }
    }

    fn today() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 11, 7).unwrap()
    }

    fn ids(p: &Parsed) -> Vec<i64> {
        p.people.iter().map(|(id, _, _)| *id).collect()
    }

    #[test]
    fn two_people() {
        let p = parse("alex and sam", &lexicon(), today());
        assert_eq!(ids(&p), vec![1, 2]); // the Sam with more photos
        assert_eq!(p.text, None);
        assert!(p.has_filters());
    }

    #[test]
    fn a_person_and_a_pet() {
        let p = parse("Alex und Rex", &lexicon(), today());
        assert_eq!(ids(&p), vec![1, 3]);
        assert_eq!(p.people[1].2, "dog");
    }

    #[test]
    fn a_person_in_a_country_and_a_town() {
        let p = parse("alex in spain", &lexicon(), today());
        assert_eq!(ids(&p), vec![1]);
        assert_eq!(p.places, vec![("Spain".to_string(), vec![10, 11])]);
        let p = parse("me in port vela", &lexicon(), today());
        assert_eq!(ids(&p), vec![1]);
        assert_eq!(p.places[0].1, vec![11]);
    }

    #[test]
    fn full_names_win_over_first_names() {
        let p = parse("anna maria", &lexicon(), today());
        assert_eq!(ids(&p), vec![4]);
        let p = parse("sam klein", &lexicon(), today());
        assert_eq!(ids(&p), vec![6]);
        let p = parse("anna", &lexicon(), today());
        assert_eq!(ids(&p), vec![5]);
    }

    #[test]
    fn seasons_months_and_years() {
        let p = parse("sam summer 2024", &lexicon(), today());
        assert_eq!(ids(&p), vec![2]);
        assert_eq!(
            p.when,
            Some(When::Range {
                from: NaiveDate::from_ymd_opt(2024, 6, 1).unwrap(),
                to: NaiveDate::from_ymd_opt(2024, 9, 1).unwrap(),
                label: "Summer 2024".into()
            })
        );
        let p = parse("winter 2023", &lexicon(), today());
        assert!(
            matches!(p.when, Some(When::Range { to, .. }) if to == NaiveDate::from_ymd_opt(2024, 3, 1).unwrap())
        );
        let p = parse("alex im august", &lexicon(), today());
        assert_eq!(
            p.when,
            Some(When::Months {
                months: vec![8],
                label: "August".into()
            })
        );
        let p = parse("letztes jahr", &lexicon(), today());
        assert_eq!(p.when.as_ref().map(When::label), Some("2025"));
        // today() is in the test's year; last summer is the latest one over
        let p = parse(
            "alex last summer",
            &lexicon(),
            NaiveDate::from_ymd_opt(2026, 11, 7).unwrap(),
        );
        assert_eq!(ids(&p), vec![1]);
        assert_eq!(p.when.as_ref().map(When::label), Some("Summer 2026"));
        assert_eq!(p.text, None);
        let p = parse(
            "last summer",
            &lexicon(),
            NaiveDate::from_ymd_opt(2026, 7, 10).unwrap(),
        );
        assert_eq!(p.when.as_ref().map(When::label), Some("Summer 2025"));
        let p = parse(
            "letzten winter",
            &lexicon(),
            NaiveDate::from_ymd_opt(2026, 11, 7).unwrap(),
        );
        assert!(
            matches!(p.when, Some(When::Range { from, .. }) if from == NaiveDate::from_ymd_opt(2025, 12, 1).unwrap())
        );
        let p = parse(
            "this august",
            &lexicon(),
            NaiveDate::from_ymd_opt(2026, 11, 7).unwrap(),
        );
        assert_eq!(p.when.as_ref().map(When::label), Some("August 2026"));
    }

    #[test]
    fn videos_and_what_is_left() {
        let p = parse("videos of rex", &lexicon(), today());
        assert!(p.videos);
        assert_eq!(ids(&p), vec![3]);
        assert_eq!(p.text, None);
        let p = parse("alex and sam at the beach", &lexicon(), today());
        assert_eq!(ids(&p), vec![1, 2]);
        assert_eq!(p.text.as_deref(), Some("beach"));
        let p = parse("sunset over the sea", &lexicon(), today());
        assert!(!p.has_filters());
        assert_eq!(p.text.as_deref(), Some("sunset over sea"));
    }

    #[test]
    fn albums_by_their_title() {
        let p = parse("canyon rafting", &lexicon(), today());
        assert_eq!(p.albums, vec![(7, "Canyon Rafting".to_string())]);
    }

    #[test]
    fn a_word_that_names_nothing_stays_text() {
        let p = parse("timetable", &lexicon(), today());
        assert!(!p.has_filters());
        assert_eq!(p.text.as_deref(), Some("timetable"));
    }
}
