//! What the stage looks at: a photo at full resolution (its preview when the
//! original cannot be decoded), or about a frame a second of a clip.

use std::collections::HashSet;
use std::path::Path;

use anyhow::Result;
use image::RgbImage;

use crate::pixels::{self, fit};

/// A photo is analyzed at most this large (long side, pixels).
const MAX_SIDE: u32 = 4096;
/// Video frames are analyzed at most this large.
const MAX_FRAME_SIDE: u32 = 1920;
pub(super) const MAX_FRAMES: usize = 60;
/// Animals are looked for in every this many sampled frames of a video.
const ANIMAL_EVERY: usize = 4;

pub(super) struct Frame {
    pub(super) image: RgbImage,
    /// seconds into the clip; None for a still
    pub(super) at: Option<f32>,
    /// the frame the server's poster was taken from (where the faces of
    /// earlier versions of this stage were found)
    pub(super) poster: bool,
    pub(super) animals: bool,
    pub(super) text: bool,
}

/// The pixels to look at; None when there is nothing to read yet.
pub(super) fn frames(
    original: &Path,
    thumb: Option<&Path>,
    video: bool,
) -> Result<Option<Vec<Frame>>> {
    if !video {
        let image = match atlas_core::decode::decode(original) {
            Ok(decoded) => decoded.rgb,
            Err(e) => match thumb {
                // a format the decoder does not read (some RAW files): the
                // preview the server made from it
                Some(thumb) => {
                    tracing::debug!("{}: {e:#}; using the preview", original.display());
                    pixels::open(thumb)?
                }
                None if original.exists() => return Err(e),
                None => return Ok(None),
            },
        };
        let image = fit(image, MAX_SIDE)?;
        return Ok(Some(vec![Frame {
            image,
            at: None,
            poster: true,
            animals: true,
            text: true,
        }]));
    }

    let sampled = original
        .exists()
        .then(|| sample_video(original))
        .transpose();
    match sampled {
        Ok(Some(frames)) if !frames.is_empty() => Ok(Some(frames)),
        other => {
            if let Err(e) = other {
                tracing::warn!(
                    "{}: cannot read frames: {e:#}; using the poster",
                    original.display()
                );
            }
            // the poster the server made, as the clip's only frame
            let Some(thumb) = thumb else { return Ok(None) };
            let image = pixels::open(thumb)?;
            Ok(Some(vec![Frame {
                image,
                at: Some(1.0),
                poster: true,
                animals: true,
                text: true,
            }]))
        }
    }
}

fn sample_video(path: &Path) -> Result<Vec<Frame>> {
    let clip = pixels::probe(path)?;
    let duration = clip.times.last().copied().unwrap_or(0.0);
    let times = sample_times(duration);
    let text_at: HashSet<usize> = text_frames(times.len());
    let mut frames = Vec::with_capacity(times.len());
    for (chunk_index, chunk) in times.chunks(8).enumerate() {
        let decoded = pixels::frames_at(path, chunk, clip.hdr)?;
        for (k, image) in decoded.into_iter().enumerate() {
            let i = chunk_index * 8 + k;
            let at = times[i];
            frames.push(Frame {
                image: fit(image, MAX_FRAME_SIDE)?,
                at: Some(at as f32),
                poster: (at - poster_time(duration)).abs() < 1e-6,
                animals: i % ANIMAL_EVERY == 0,
                text: text_at.contains(&i),
            });
        }
    }
    Ok(frames)
}

/// The server's poster is 1 s into a clip, or its first frame if shorter.
fn poster_time(duration: f64) -> f64 {
    if duration > 1.0 { 1.0 } else { 0.0 }
}

/// About one frame a second, at most [`MAX_FRAMES`], always including the
/// poster's moment.
fn sample_times(duration: f64) -> Vec<f64> {
    let step = (duration / MAX_FRAMES as f64).max(1.0);
    let mut times: Vec<f64> = (0..MAX_FRAMES)
        .map(|k| k as f64 * step)
        .take_while(|&t| t <= duration)
        .collect();
    if times.is_empty() {
        times.push(0.0);
    }
    let poster = poster_time(duration);
    if !times.iter().any(|&t| (t - poster).abs() < 1e-6) {
        times.push(poster);
        times.sort_by(f64::total_cmp);
    }
    times
}

/// Which sampled frames are read for text: the first and three spread over
/// the clip.
fn text_frames(count: usize) -> HashSet<usize> {
    [0, count / 4, count / 2, 3 * count / 4]
        .into_iter()
        .filter(|&i| i < count)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn videos_sample_about_a_frame_a_second_with_the_poster() {
        let t = sample_times(10.0);
        assert_eq!(t.len(), 11);
        assert!(t.contains(&1.0));
        let long = sample_times(600.0);
        assert!(long.len() <= MAX_FRAMES + 1);
        assert!(long.contains(&1.0));
        assert_eq!(sample_times(0.4), vec![0.0]);
    }
}
