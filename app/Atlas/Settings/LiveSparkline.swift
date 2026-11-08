import SwiftUI

/// A live load curve (0–100) over a sliding 60 s window, drawn as one path
/// in a Canvas. It replaces a Swift Charts chart that was rebuilt mark by
/// mark 30 times a second: here a frame only filters the few points in the
/// window and strokes them. The series is mapped once per sample by the
/// caller, never per frame. Out of focus it slows to the sample rate.
struct LiveSparkline: View {
    /// (time, value 0–100), oldest first.
    let series: [LiveSparkline.Point]
    let color: Color
    @Environment(\.appearsActive) private var active

    struct Point: Equatable {
        var date: Date
        var value: Double
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 30 : 0.5)) { context in
            Canvas { gc, size in
                let head = context.date.addingTimeInterval(-LiveChart.renderDelay)
                let start = head.addingTimeInterval(-LiveChart.window)
                let points = LiveChart.points(series.map { ($0.date, $0.value) }, frame: context.date,
                                              window: LiveChart.window)
                guard points.count > 1 else { return }
                let xy = points.map { p in
                    CGPoint(x: CGFloat(p.0.timeIntervalSince(start) / LiveChart.window) * size.width,
                            y: size.height - CGFloat(min(max(p.1, 0), 100) / 100) * (size.height - 1.5) - 0.75)
                }
                let line = Self.smooth(xy)
                var area = line
                area.addLine(to: CGPoint(x: xy[xy.count - 1].x, y: size.height))
                area.addLine(to: CGPoint(x: xy[0].x, y: size.height))
                area.closeSubpath()
                gc.fill(area, with: .color(color.opacity(0.16)))
                gc.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }

    /// A curve through every point (Catmull–Rom as cubic Béziers), close to
    /// the monotone interpolation the chart used; the y of the control
    /// points is clamped between its neighbours, so it never overshoots.
    private static func smooth(_ p: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: p[0])
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let lo = min(p1.y, p2.y), hi = max(p1.y, p2.y)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: min(max(p1.y + (p2.y - p0.y) / 6, lo), hi))
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: min(max(p2.y - (p3.y - p1.y) / 6, lo), hi))
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

extension Machine {
    /// The last 160 samples of one measure, for a sparkline: mapped once
    /// per sample.
    func series(_ keyPath: KeyPath<MetricSample, Double>) -> [LiveSparkline.Point] {
        samples.suffix(160).map { LiveSparkline.Point(date: $0.date, value: $0[keyPath: keyPath]) }
    }
}
