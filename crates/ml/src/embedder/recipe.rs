//! How much of a still or a clip the model sees: `qwen_vl_utils` (0.0.14)
//! as WeMM-Embedding's MMEB evaluation calls it. Python rounds halves to
//! even, so these do too.

/// The vision tower sees 16px patches merged 2x2: one token per 32px square.
const PATCH: u32 = 32;
/// A still: at least 64 and at most 1800 tokens (a 2048px thumbnail at 4:3
/// becomes 1536x1152).
pub const IMAGE_MIN_TOKENS: u32 = 64;
pub const IMAGE_MAX_TOKENS: u32 = 1800;
/// A clip: one frame per second, 4 to 64 frames, each 4 to 256 tokens,
/// 8192 tokens at most in all (the frames of a pair share their tokens).
const FPS: f64 = 1.0;
const MIN_FRAMES: usize = 4;
const MAX_FRAMES: usize = 64;
pub const FRAME_MIN_TOKENS: u32 = 4;
const FRAME_MAX_TOKENS: u32 = 256;
pub const VIDEO_TOKENS: u32 = 8192;

/// `smart_resize`: both sides multiples of 32, the area between the two
/// limits, the aspect kept as closely as that allows. Returns (w, h).
pub fn smart_size(width: u32, height: u32, min_pixels: f64, max_pixels: f64) -> (u32, u32) {
    let factor = f64::from(PATCH);
    let (w, h) = (f64::from(width.max(1)), f64::from(height.max(1)));
    let round = |v: f64| ((v / factor).round_ties_even() * factor).max(factor);
    let (mut out_w, mut out_h) = (round(w), round(h));
    if out_w * out_h > max_pixels {
        let beta = (w * h / max_pixels).sqrt();
        out_w = ((w / beta / factor).floor() * factor).max(factor);
        out_h = ((h / beta / factor).floor() * factor).max(factor);
    } else if out_w * out_h < min_pixels {
        let beta = (min_pixels / (w * h)).sqrt();
        out_w = (w * beta / factor).ceil() * factor;
        out_h = (h * beta / factor).ceil() * factor;
    }
    (out_w as u32, out_h as u32)
}

fn pixels(tokens: u32) -> f64 {
    f64::from(tokens * PATCH * PATCH)
}

pub fn image_size(width: u32, height: u32) -> (u32, u32) {
    smart_size(width, height, pixels(IMAGE_MIN_TOKENS), pixels(IMAGE_MAX_TOKENS))
}

/// `smart_nframes`: how many frames to read from a clip of `total`
/// frames at `fps`; even, and None when not even two can be had.
pub fn frame_count(total: usize, fps: f64) -> Option<usize> {
    let wanted = total as f64 / fps * FPS;
    let n = wanted.max(MIN_FRAMES as f64).min(MAX_FRAMES as f64).min(total as f64);
    let n = (n / 2.0).floor() as usize * 2;
    (n >= 2 && n <= total).then_some(n)
}

/// Which frames: `linspace(0, total - 1, count)`, rounded.
pub fn frame_indices(total: usize, count: usize) -> Vec<usize> {
    let last = total.saturating_sub(1) as f64;
    let step = if count > 1 { last / (count - 1) as f64 } else { 0.0 };
    (0..count).map(|i| (i as f64 * step).round_ties_even() as usize).collect()
}

/// The size every frame is brought to: at most 256 tokens, less when
/// many frames would exceed the clip's total.
pub fn frame_size(width: u32, height: u32, count: usize) -> (u32, u32) {
    let min = pixels(FRAME_MIN_TOKENS);
    let max = pixels(FRAME_MAX_TOKENS).min(pixels(VIDEO_TOKENS) / count as f64 * 2.0).max((min * 1.05).floor());
    smart_size(width, height, min, max)
}

/// The time of each merged pair of frames, in seconds: the mean of its
/// two frames' times.
pub fn pair_times(indices: &[usize], fps: f64) -> Vec<f64> {
    indices.chunks(2).map(|pair| (pair[0] + pair[pair.len() - 1]) as f64 / 2.0 / fps).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn image_sizes_match_the_reference() {
        // qwen_vl_utils.smart_resize(1536, 2048, factor=32, min_pixels=64*1024, max_pixels=1800*1024)
        assert_eq!(image_size(2048, 1536), (1536, 1152));
        // small enough already: only snapped to the patch grid
        assert_eq!(image_size(512, 384), (512, 384));
        assert_eq!(image_size(500, 375), (512, 384));
        // halves round to even, as Python's round() does: 720 / 32 = 22.5
        assert_eq!(image_size(720, 1280), (704, 1280));
        // tiny images are raised to the minimum of 64 tokens
        assert_eq!(image_size(20, 20), (256, 256));
    }

    #[test]
    fn clips_are_sampled_as_the_reference_does() {
        // 10 s at 30 fps: 10 frames
        assert_eq!(frame_count(300, 30.0), Some(10));
        // 3 s: raised to the minimum of 4
        assert_eq!(frame_count(90, 30.0), Some(4));
        // 5 minutes: capped at 64
        assert_eq!(frame_count(9000, 30.0), Some(64));
        // odd counts round down: 7.5 s -> 6
        assert_eq!(frame_count(225, 30.0), Some(6));
        // a clip of 3 frames gives 2, of 1 frame nothing
        assert_eq!(frame_count(3, 30.0), Some(2));
        assert_eq!(frame_count(1, 30.0), None);
        assert_eq!(frame_indices(300, 10), vec![0, 33, 66, 100, 133, 166, 199, 233, 266, 299]);
        assert_eq!(pair_times(&[0, 33, 66, 100], 30.0), vec![0.55, 2.7666666666666666]);
    }

    #[test]
    fn frames_are_sized_as_the_reference_does() {
        // qwen_vl_utils fetch_video with WeMM's min/max/total pixels
        let want = [((1920, 1080, 64), (672, 384)), ((1080, 1920, 10), (384, 672)), ((3840, 2160, 4), (672, 384)), ((640, 360, 64), (640, 352))];
        for ((w, h, n), size) in want {
            assert_eq!(frame_size(w, h, n), size, "{w}x{h}, {n} frames");
            let tokens = (size.0 / 32) * (size.1 / 32);
            assert!(tokens <= 256 && n as u32 / 2 * tokens <= VIDEO_TOKENS);
        }
    }
}
