//! Who a face (or an animal) is: the person whose known faces it resembles
//! most, when that is clear. The thresholds here decide it for the vision
//! stage and for the grouping pass alike.

use std::collections::HashMap;

use anyhow::{Context, Result};
use pgvector::Vector;
use tokio_postgres::Transaction;

use super::MODEL;

/// Who a face is, from the faces already known: the mean of its closest
/// faces of a person must reach this ...
pub const ASSIGN_FACE: f32 = 0.38;
/// ... this for a face narrower than `SMALL_FACE` pixels ...
pub const ASSIGN_SMALL_FACE: f32 = 0.42;
pub const SMALL_FACE: f32 = 32.0;
/// ... and a face that is no [`founder`] (small, blurred or unsure) needs
/// this much, against the person's clear faces only: such faces carry little
/// of who it is, and at 0.38 cartoons, memes and motion blur joined named
/// people (2026-11-08). Genuine pairs have a median of 0.57.
pub const ASSIGN_POOR_FACE: f32 = 0.50;
/// ... and beat the runner-up person by this much. Calibrated on the owner's
/// named faces with AdaFace (2026-11-07): two strangers' faces reach 0.26 in
/// one pair of a thousand and 0.40 in one of ten thousand; half of all pairs
/// of one person's faces are above 0.57.
pub const ASSIGN_MARGIN: f32 = 0.05;
/// The same for animals with pet-recognition-large: one individual's photos
/// sit at about 0.6-0.7, different animals at about 0-0.2.
pub const ASSIGN_ANIMAL: f32 = 0.45;
/// A face is named by resemblance only when AdaFace can make it out at
/// least this well ...
pub const MIN_CLARITY_ASSIGN: f32 = 17.0;
/// ... and a new person is gathered only from faces this clear and this
/// surely detected. Measured 2026-11-07: faces of named people 19-24 (scores
/// 0.75-0.89); a junk cluster the first grouping made of concert crowds,
/// walls and toys 13-22, median 17 (scores 0.5-0.7).
pub const MIN_CLARITY_GROUP: f32 = 20.0;
pub const MIN_SCORE_GROUP: f32 = 0.7;
pub const MIN_WIDTH_GROUP: f32 = 40.0;

/// Whether a face is clear enough to found a person or join one nobody has
/// named. Other faces can only join someone named: small, blurred and
/// face-like things resemble each other more than anyone, and grouped among
/// themselves they grew into "people" of thousands of faces (2026-11-08:
/// 7% of such a group's faces passed this test, 79% of named people's).
pub fn founder(width_px: f32, clarity: f32, score: f32) -> bool {
    width_px >= MIN_WIDTH_GROUP && clarity >= MIN_CLARITY_GROUP && score >= MIN_SCORE_GROUP
}

/// The person whose known faces this face resembles clearly most.
/// The person a face belongs to, if certain; a face that is not a
/// [`founder`] is only matched against people someone named.
pub async fn assign_face(
    tx: &Transaction<'_>,
    embedding: &[f32],
    width_px: f32,
    founder: bool,
    vetoed: &[i64],
) -> Result<Option<i64>> {
    let rows = tx
        .query(
            "SELECT f.person_id, 1 - (f.embedding <=> $1) FROM faces f
             JOIN persons p ON p.id = f.person_id AND p.merged_into IS NULL AND p.kind = 'person'
             WHERE f.model = $2 AND f.kind = 'person' AND f.person_id IS NOT NULL
               AND coalesce(f.clarity, 99) >= $3
               AND ($4 OR (p.display_name IS NOT NULL
                           AND f.width_px >= $5 AND f.clarity >= $6 AND f.quality >= $7))
             ORDER BY f.embedding <=> $1 LIMIT 40",
            &[
                &Vector::from(embedding.to_vec()),
                &MODEL,
                &MIN_CLARITY_ASSIGN,
                &founder,
                &MIN_WIDTH_GROUP,
                &MIN_CLARITY_GROUP,
                &MIN_SCORE_GROUP,
            ],
        )
        .await?;
    let neighbors: Vec<(i64, f32)> =
        rows.iter().map(|r| (r.get(0), r.get::<_, f64>(1) as f32)).filter(|(p, _)| !vetoed.contains(p)).collect();
    let threshold = if !founder {
        ASSIGN_POOR_FACE
    } else if width_px < SMALL_FACE {
        ASSIGN_SMALL_FACE
    } else {
        ASSIGN_FACE
    };
    Ok(decide(&neighbors, threshold, ASSIGN_MARGIN))
}

pub async fn assign_animal(tx: &Transaction<'_>, species: &str, look: &[f32], vetoed: &[i64]) -> Result<Option<i64>> {
    let rows = tx
        .query(
            "SELECT f.person_id, 1 - (f.look <=> $1) FROM faces f
             JOIN persons p ON p.id = f.person_id AND p.merged_into IS NULL
             WHERE f.kind = $2 AND f.look IS NOT NULL AND f.person_id IS NOT NULL
             ORDER BY f.look <=> $1 LIMIT 40",
            &[&Vector::from(look.to_vec()), &species],
        )
        .await?;
    let neighbors: Vec<(i64, f32)> =
        rows.iter().map(|r| (r.get(0), r.get::<_, f64>(1) as f32)).filter(|(p, _)| !vetoed.contains(p)).collect();
    Ok(decide(&neighbors, ASSIGN_ANIMAL, ASSIGN_MARGIN))
}

/// From a face's nearest known faces (person, similarity): the person whose
/// closest three (or fewer) average at least `threshold` and beat every
/// other person's by `margin`. A person with a single face in reach needs
/// that face to clear the bar by a further 0.1: one look-alike is weak
/// evidence.
pub fn decide(neighbors: &[(i64, f32)], threshold: f32, margin: f32) -> Option<i64> {
    let mut by_person: HashMap<i64, Vec<f32>> = HashMap::new();
    for &(person, similarity) in neighbors {
        by_person.entry(person).or_default().push(similarity);
    }
    let mut scores: Vec<(i64, f32)> = by_person
        .into_iter()
        .map(|(person, mut s)| {
            s.sort_by(|a, b| b.total_cmp(a));
            let top = &s[..s.len().min(3)];
            let mean = top.iter().sum::<f32>() / top.len() as f32;
            (person, if top.len() == 1 { mean - 0.1 } else { mean })
        })
        .collect();
    scores.sort_by(|a, b| b.1.total_cmp(&a.1));
    let (best, score) = *scores.first()?;
    let runner_up = scores.get(1).map_or(f32::MIN, |s| s.1);
    (score >= threshold && score - runner_up >= margin).then_some(best)
}

/// Face counts and centroids follow the faces: the centroid of the current
/// recognizer's faces, an animal's mean look.
pub async fn refresh_people(tx: &Transaction<'_>, people: &[i64]) -> Result<()> {
    if people.is_empty() {
        return Ok(());
    }
    tx.execute(
        "UPDATE persons p SET face_count = c.n,
                centroid = coalesce(c.a, p.centroid), look = coalesce(c.l, p.look)
         FROM (SELECT person_id, count(*) AS n,
                      avg(embedding) FILTER (WHERE model = $2) AS a,
                      avg(look) AS l
               FROM faces WHERE person_id = ANY($1) GROUP BY person_id) c
         WHERE p.id = c.person_id",
        &[&people, &MODEL],
    )
    .await
    .context("refreshing people")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_clear_large_sure_faces_found_people() {
        assert!(founder(120.0, 22.0, 0.85));
        assert!(!founder(30.0, 22.0, 0.85)); // tiny
        assert!(!founder(120.0, 18.0, 0.85)); // blurred
        assert!(!founder(120.0, 22.0, 0.55)); // barely a face
    }

    #[test]
    fn a_clear_majority_decides() {
        let n = [(1, 0.6), (1, 0.55), (1, 0.5), (2, 0.45), (2, 0.4)];
        assert_eq!(decide(&n, 0.38, 0.05), Some(1));
    }

    #[test]
    fn a_close_race_or_a_weak_match_decides_nothing() {
        assert_eq!(decide(&[(1, 0.5), (1, 0.5), (2, 0.48), (2, 0.48)], 0.38, 0.05), None);
        assert_eq!(decide(&[(1, 0.3), (1, 0.3)], 0.38, 0.05), None);
        // one look-alike alone is not enough ...
        assert_eq!(decide(&[(1, 0.45)], 0.38, 0.05), None);
        // ... unless it is unmistakable
        assert_eq!(decide(&[(1, 0.6)], 0.38, 0.05), Some(1));
        assert_eq!(decide(&[], 0.38, 0.05), None);
    }
}
