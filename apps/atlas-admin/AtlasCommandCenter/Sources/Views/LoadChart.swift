import SwiftUI
import Charts

/// Rolling CPU + GPU usage sparkline.
struct LoadChart: View {
    var cpu: [Double]
    var gpu: [Double]

    private struct Point: Identifiable {
        let id = UUID()
        let i: Int
        let value: Double
        let series: String
    }

    private var points: [Point] {
        var p: [Point] = []
        for (i, v) in cpu.enumerated() { p.append(Point(i: i, value: v, series: "CPU")) }
        for (i, v) in gpu.enumerated() { p.append(Point(i: i, value: v, series: "GPU")) }
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
                Chart(points) { p in
                    AreaMark(
                        x: .value("t", p.i),
                        y: .value("%", p.value)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [(p.series == "CPU" ? Theme.accent : Theme.violet).opacity(0.35), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .foregroundStyle(by: .value("s", p.series))

                    LineMark(
                        x: .value("t", p.i),
                        y: .value("%", p.value)
                    )
                    .foregroundStyle(by: .value("s", p.series))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartForegroundStyleScale(["CPU": Theme.accent, "GPU": Theme.violet])
                .chartLegend(.hidden)
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) {
                        AxisGridLine().foregroundStyle(.white.opacity(0.06))
                        AxisValueLabel().foregroundStyle(.white.opacity(0.3))
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: 120)
            }
        }
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
