import Foundation

/// Shared math for the live dashboard charts.
enum ChartLive {
    /// Render delay behind real time: the newest sample is treated as "still
    /// arriving", and the visible head of the curve is interpolated toward it
    /// frame by frame — values glide up and down instead of popping in.
    static let renderDelay: TimeInterval = 0.75

    /// Points visible at `frameDate`, clipped to the window, plus one
    /// interpolated head point at exactly (frameDate - renderDelay).
    static func points(_ samples: [(Date, Double)], frame frameDate: Date,
                       window: TimeInterval) -> [(Date, Double)] {
        let head = frameDate.addingTimeInterval(-renderDelay)
        let start = head.addingTimeInterval(-window)
        var out = samples.filter { $0.0 >= start && $0.0 <= head }
        // interpolated head between the two samples that bracket `head`
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

    /// Rounds up to a "nice" axis maximum (1/2/5 × 10^n), minimum `floor`.
    static func niceCeil(_ v: Double, floor: Double = 1) -> Double {
        let x = max(v, floor)
        let mag = pow(10, Foundation.floor(log10(x)))
        for m in [1.0, 2.0, 5.0, 10.0] where x <= m * mag {
            return m * mag
        }
        return 10 * mag
    }
}
