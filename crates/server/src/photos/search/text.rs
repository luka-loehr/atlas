//! Matching the text read off photos.

/// What text read off a photo must contain to match `text` (a Postgres
/// regex on the lowercased text): short words whole ("dog" is not in the
/// Croatian "događaji", but is in "dog's"), longer ones anywhere, so a word
/// is found inside a German compound ("vertretungsplan" in
/// "vertretungsplanänderung"). Spaces match any run of whitespace.
pub(super) fn text_pattern(text: &str) -> String {
    const WHOLE_BELOW: usize = 6;
    let words: Vec<String> = text
        .to_lowercase()
        .split_whitespace()
        .map(regex_escape)
        .collect();
    let body = words.join(r"\s+");
    let short = text.chars().filter(|c| !c.is_whitespace()).count() < WHOLE_BELOW;
    if short { format!(r"\m{body}\M") } else { body }
}

pub(super) fn regex_escape(s: &str) -> String {
    s.chars()
        .flat_map(|c| {
            let special = r"\.+*?()|[]{}^$".contains(c);
            special
                .then_some('\\')
                .into_iter()
                .chain(std::iter::once(c))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_words_match_whole() {
        assert_eq!(text_pattern("Dog"), r"\mdog\M");
        assert_eq!(text_pattern("Vertretungsplan"), "vertretungsplan");
        assert_eq!(text_pattern("bus  stop"), r"bus\s+stop");
        assert_eq!(text_pattern("c++"), r"\mc\+\+\M");
    }
}
