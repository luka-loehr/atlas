import SwiftUI
import Charts

/// Live network throughput over a continuously sliding 60 s window.
/// Same live-rendering as LoadChart (EMA series + per-frame interpolated
/// head); the y-axis re-scales to a "nice" ceiling that follows the traffic.
struct NetChart: View {
    var down: [(Date, Double)]
    var up: [(Date, Double)]
    var downNow: Double
    var upNow: Double

    private static let window: TimeInterval = 60

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Netzwerk")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    rate("arrow.down", downNow, Theme.accent)
                    rate("arrow.up", upNow, Theme.violet)
                }
                TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { context in
                    chart(now: context.date)
                }
                .frame(height: 110)
            }
        }
    }

    private func chart(now: Date) -> some View {
        let head = now.addingTimeInterval(-ChartLive.renderDelay)
        let downPts = ChartLive.points(down, frame: now, window: Self.window)
        let upPts = ChartLive.points(up, frame: now, window: Self.window)
        let peak = (downPts.map(\.1) + upPts.map(\.1)).max() ?? 1
        let top = ChartLive.niceCeil(peak * 1.15, floor: 1)

        return Chart {
            series("Upload", upPts, Theme.violet)
            series("Download", downPts, Theme.accent)
        }
        .chartForegroundStyleScale(["Download": Theme.accent, "Upload": Theme.violet])
        .chartLegend(.hidden)
        .chartXScale(domain: head.addingTimeInterval(-Self.window)...head)
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(values: [top / 2, top]) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.white.opacity(0.06))
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(short(d))
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
            }
        }
        .chartXAxis(.hidden)
    }

    @ChartContentBuilder
    private func series(_ name: String, _ pts: [(Date, Double)], _ color: Color) -> some ChartContent {
        ForEach(Array(pts.enumerated()), id: \.offset) { _, s in
            AreaMark(x: .value("t", s.0), y: .value("mbps", s.1), stacking: .unstacked)
                .foregroundStyle(
                    .linearGradient(colors: [color.opacity(0.22), color.opacity(0.02)],
                                    startPoint: .top, endPoint: .bottom))
                .foregroundStyle(by: .value("s", name))
                .interpolationMethod(.monotone)

            LineMark(x: .value("t", s.0), y: .value("mbps", s.1))
                .foregroundStyle(by: .value("s", name))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
    }

    private func rate(_ icon: String, _ mbps: Double, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(fmt(mbps))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.leading, 8)
    }

    /// "3,2 Mbit/s", "870 kbit/s", "1,1 Gbit/s"
    private func fmt(_ mbps: Double) -> String {
        if mbps >= 1000 { return String(format: "%.1f Gbit/s", mbps / 1000) }
        if mbps >= 10 { return String(format: "%.0f Mbit/s", mbps) }
        if mbps >= 1 { return String(format: "%.1f Mbit/s", mbps) }
        return String(format: "%.0f kbit/s", mbps * 1000)
    }

    private func short(_ mbps: Double) -> String {
        if mbps >= 1000 { return String(format: "%.0fG", mbps / 1000) }
        if mbps >= 1 { return String(format: "%.0fM", mbps) }
        return String(format: "%.0fk", mbps * 1000)
    }
}
