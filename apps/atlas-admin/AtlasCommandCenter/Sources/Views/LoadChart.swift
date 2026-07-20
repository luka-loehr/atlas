import SwiftUI
import Charts

/// Rolling CPU + GPU usage sparkline over a continuously sliding 60 s window.
struct LoadChart: View {
    var cpu: [(Date, Double)]
    var gpu: [(Date, Double)]

    private struct Point: Identifiable {
        let id: Int
        let t: Date
        let value: Double
        let series: String
    }

    private var points: [Point] {
        var p: [Point] = []
        p.reserveCapacity(cpu.count + gpu.count)
        for (i, s) in cpu.enumerated() { p.append(Point(id: i, t: s.0, value: s.1, series: "CPU")) }
        for (i, s) in gpu.enumerated() { p.append(Point(id: cpu.count + i, t: s.0, value: s.1, series: "GPU")) }
        return p
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Auslastung")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    legend("CPU", Theme.accent)
                    legend("GPU", Theme.violet)
                }
                TimelineView(.periodic(from: .now, by: 0.05)) { context in
                    chart(now: context.date)
                }
                .frame(height: 120)
            }
        }
    }

    private func chart(now: Date) -> some View {
        Chart(points) { p in
            AreaMark(
                x: .value("t", p.t),
                y: .value("%", p.value),
                stacking: .unstacked
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [(p.series == "CPU" ? Theme.accent : Theme.violet).opacity(0.35), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .foregroundStyle(by: .value("s", p.series))

            LineMark(
                x: .value("t", p.t),
                y: .value("%", p.value)
            )
            .foregroundStyle(by: .value("s", p.series))
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartForegroundStyleScale(["CPU": Theme.accent, "GPU": Theme.violet])
        .chartLegend(.hidden)
        .chartXScale(domain: now.addingTimeInterval(-60)...now)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) {
                AxisGridLine().foregroundStyle(.white.opacity(0.06))
                AxisValueLabel().foregroundStyle(.white.opacity(0.3))
            }
        }
        .chartXAxis(.hidden)
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}
