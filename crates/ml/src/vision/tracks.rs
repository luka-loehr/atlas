//! A video's detections, one per person and per animal.

use super::engines::Found;

/// Two faces of one video this similar are the same person's track.
const SAME_TRACK: f32 = 0.45;
const SAME_ANIMAL_TRACK: f32 = 0.5;

/// How much a detection is worth keeping as the face of its track: large
/// and sure.
pub(super) fn worth(f: &Found) -> f32 {
    f.width_px * f.score
}

fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

/// A video's detections, one per person and per animal: the same face in
/// many frames is one track, kept at its best frame. A track takes the
/// person any of its detections inherited.
pub(super) fn tracks(found: Vec<Found>) -> Vec<Found> {
    let mut sorted = found;
    sorted.sort_by(|a, b| worth(b).total_cmp(&worth(a)));
    let mut kept: Vec<Found> = Vec::new();
    for f in sorted {
        let same = kept.iter_mut().find(|k| {
            k.kind == f.kind
                && match (&k.embedding, &f.embedding, &k.look, &f.look) {
                    (Some(a), Some(b), _, _) => dot(a, b) >= SAME_TRACK,
                    (_, _, Some(a), Some(b)) => dot(a, b) >= SAME_ANIMAL_TRACK,
                    // animals too small to identify: one per species
                    (None, None, None, None) => f.kind != "person",
                    _ => false,
                }
        });
        match same {
            Some(track) => {
                if track.person.is_none() {
                    track.person = f.person;
                }
                if track.replaces.is_none() {
                    track.replaces = f.replaces;
                }
                for p in f.vetoed {
                    if !track.vetoed.contains(&p) {
                        track.vetoed.push(p);
                    }
                }
            }
            None => kept.push(f),
        }
    }
    kept
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_track_keeps_its_best_detection_and_any_inherited_person() {
        let f = |w: f32, e: [f32; 2], person| Found {
            kind: "person",
            frame: 0,
            bbox: [0.0; 4],
            width_px: w,
            score: 1.0,
            clarity: None,
            embedding: Some(e.to_vec()),
            look: None,
            person,
            replaces: None,
            vetoed: Vec::new(),
        };
        let kept = tracks(vec![
            f(40.0, [1.0, 0.0], Some(7)),
            f(80.0, [0.99, 0.14], None),
            f(50.0, [0.0, 1.0], None),
        ]);
        assert_eq!(kept.len(), 2);
        assert_eq!(kept[0].width_px, 80.0);
        assert_eq!(kept[0].person, Some(7));
    }
}
