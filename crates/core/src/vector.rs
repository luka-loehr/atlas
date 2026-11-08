//! Vector arithmetic both processes need: embeddings are compared by the dot
//! product of unit vectors.

/// A dot product LLVM can vectorize: eight independent sums. A single
/// running total would force strict left-to-right float addition.
pub fn dot(a: &[f32], b: &[f32]) -> f32 {
    let mut acc = [0f32; 8];
    let ((ca, ra), (cb, rb)) = (a.as_chunks::<8>(), b.as_chunks::<8>());
    let tail: f32 = ra.iter().zip(rb).map(|(x, y)| x * y).sum();
    for (x, y) in ca.iter().zip(cb) {
        for k in 0..8 {
            acc[k] += x[k] * y[k];
        }
    }
    acc.iter().sum::<f32>() + tail
}

/// Scales `v` to unit length; a zero vector stays as it is.
pub fn normalize(v: &mut [f32]) {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        v.iter_mut().for_each(|x| *x /= norm);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dot_matches_the_plain_sum() {
        // a length that is no multiple of eight exercises the tail
        let a: Vec<f32> = (0..19).map(|i| i as f32 * 0.1).collect();
        let b: Vec<f32> = (0..19).map(|i| 1.0 - i as f32 * 0.05).collect();
        let plain: f32 = a.iter().zip(&b).map(|(x, y)| x * y).sum();
        assert!((dot(&a, &b) - plain).abs() < 1e-4);

        let a: Vec<f32> = (0..crate::EMBED_DIM)
            .map(|i| (i as f32 * 0.37).sin())
            .collect();
        let b: Vec<f32> = (0..crate::EMBED_DIM)
            .map(|i| (i as f32 * 0.11).cos())
            .collect();
        let plain: f32 = a.iter().zip(&b).map(|(x, y)| x * y).sum();
        assert!((dot(&a, &b) - plain).abs() < 1e-2);
    }

    #[test]
    fn normalize_makes_unit_vectors() {
        let mut v = vec![3.0, 4.0];
        normalize(&mut v);
        assert!((v[0] - 0.6).abs() < 1e-6 && (v[1] - 0.8).abs() < 1e-6);
        let mut zero = vec![0.0, 0.0];
        normalize(&mut zero);
        assert_eq!(zero, [0.0, 0.0]);
    }
}
