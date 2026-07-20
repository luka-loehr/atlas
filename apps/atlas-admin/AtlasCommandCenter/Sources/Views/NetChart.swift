import SwiftUI
import Charts

/// Live network throughput (Mbit/s): download/upload area chart over a
/// continuously sliding 60 s window, with the current rates in the header.
/// Same visual language as LoadChart.
struct NetChart: View {
    var down: [(Date, Double)]
    var up: [(Date, Double)]
    var downNow: Double
    var upNow: Double

    private struct Point: Identifiable {
        let id: Int
        let t: Date
        let value: Double
        let series: String
    }

    private var points: [Point] {
        var p: [Point] = []
        p.reserveCapacity(down.count + up.count)
        for (i, s) in down.enumerated() { p.append(Point(id: i, t: s.0, value: s.1, series: "Download")) }
        for (i, s) in up.enumerated() { p.append(Point(id: down.count + i, t: s.0, value: s.1, series: "Upload")) }
        return p
    }

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
                if points.isEmpty {
                    Text("warte auf Daten …")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    TimelineView(.periodic(from: .now, by: 0.05)) { context in
                        chart(now: context.date)
                    }
                    .frame(height: 90)
                }
            }
        }
    }

    private func chart(now: Date) -> some View {
        Chart(points) { p in
            AreaMark(
                x: .value("t", p.t),
                y: .value("mbps", p.value),
                stacking: .unstacked
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [(p.series == "Download" ? Theme.accent : Theme.violet).opacity(0.35), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .foregroundStyle(by: .value("s", p.series))

            LineMark(
                x: .value("t", p.t),
                y: .value("mbps", p.value)
            )
            .lineStyle(StrokeStyle(lineWidth: 1.6))
            .foregroundStyle(p.series == "Download" ? Theme.accent : Theme.violet)
            .foregroundStyle(by: .value("s", p.series))
        }
        .chartXScale(domain: now.addingTimeInterval(-60)...now)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing) { v in
                AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(short(d))
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
        }
        .chartLegend(.hidden)
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
