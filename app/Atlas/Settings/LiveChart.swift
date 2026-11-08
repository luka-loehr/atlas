import Foundation

/// The math behind the sliding live charts (from the old dashboard).
enum LiveChart {
    static let window: TimeInterval = 60
    /// The newest sample is treated as still arriving: the head of the curve
    /// is interpolated toward it frame by frame, so values glide.
    static let renderDelay: TimeInterval = 0.75

    /// Points inside the window, plus one interpolated point pinned to each
    /// edge, so both ends follow the sliding domain instead of stepping.
    static func points(_ samples: [(Date, Double)], frame: Date, window: TimeInterval) -> [(Date, Double)] {
        let head = frame.addingTimeInterval(-renderDelay)
        let start = head.addingTimeInterval(-window)
        var out = samples.filter { $0.0 >= start && $0.0 <= head }
        if let before = samples.last(where: { $0.0 < start }) {
            let after = out.first ?? samples.first(where: { $0.0 >= start }) ?? before
            let span = after.0.timeIntervalSince(before.0)
            if span > 0, after.0 > start {
                let f = start.timeIntervalSince(before.0) / span
                out.insert((start, before.1 + (after.1 - before.1) * max(0, min(1, f))), at: 0)
            }
        }
        if let after = samples.first(where: { $0.0 > head }) {
            let before = out.last ?? samples.last(where: { $0.0 <= head }) ?? after
            let span = after.0.timeIntervalSince(before.0)
            if span > 0 {
                let f = head.timeIntervalSince(before.0) / span
                out.append((head, before.1 + (after.1 - before.1) * max(0, min(1, f))))
            }
        }
        return out
    }
}
