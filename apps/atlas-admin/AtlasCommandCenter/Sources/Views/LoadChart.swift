import SwiftUI
import Charts

/// CPU + GPU usage over a continuously sliding 60 s window.
/// The visible head of each curve is interpolated per frame (ChartLive) so
/// values glide smoothly toward each new sample instead of popping in; the
/// series themselves are EMA-smoothed by the model — soft waves, no scribble.
struct LoadChart: View {
    var cpu: [(Date, Double)]
    var gpu: [(Date, Double)]

    private static let window: TimeInterval = 60

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
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                    chart(now: context.date)
                }
                .frame(height: 120)
            }
        }
    }

    private func chart(now: Date) -> some View {
        let head = now.addingTimeInterval(-ChartLive.renderDelay)
        let cpuPts = ChartLive.points(cpu, frame: now, window: Self.window)
        let gpuPts = ChartLive.points(gpu, frame: now, window: Self.window)

        return Chart {
            series("GPU", gpuPts, Theme.violet)   // hinten
            series("CPU", cpuPts, Theme.accent)   // vorn
        }
        .chartForegroundStyleScale(["CPU": Theme.accent, "GPU": Theme.violet])
        .chartLegend(.hidden)
        .chartXScale(domain: head.addingTimeInterval(-Self.window)...head)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [50, 100]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.white.opacity(0.06))
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .chartXAxis(.hidden)
    }

    @ChartContentBuilder
    private func series(_ name: String, _ pts: [(Date, Double)], _ color: Color) -> some ChartContent {
        ForEach(Array(pts.enumerated()), id: \.offset) { _, s in
            AreaMark(x: .value("t", s.0), y: .value("%", s.1), stacking: .unstacked)
                .foregroundStyle(
                    .linearGradient(colors: [color.opacity(0.22), color.opacity(0.02)],
                                    startPoint: .top, endPoint: .bottom))
                .foregroundStyle(by: .value("s", name))
                .interpolationMethod(.monotone)

            LineMark(x: .value("t", s.0), y: .value("%", s.1))
                .foregroundStyle(by: .value("s", name))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
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
