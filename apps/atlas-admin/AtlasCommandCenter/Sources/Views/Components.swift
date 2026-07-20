import SwiftUI

/// A circular usage ring with the value in the middle.
struct RingGauge: View {
    var value: Double          // 0…100
    var label: String
    var systemImage: String
    var detail: String? = nil

    private var ratio: Double { min(max(value / 100, 0), 1) }
    private var tint: Color { Theme.heat(ratio) }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: ratio)
                    .stroke(
                        AngularGradient(
                            colors: [tint.opacity(0.7), tint],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.5), radius: 6)
                VStack(spacing: 1) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                    Text("\(Int(value.rounded()))")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monoDigits()
                        .contentTransition(.numericText(value: value))
                    Text("%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 96, height: 96)
            // one animation over the whole ring: arc, heat color, glow and the
            // rolling number all glide together instead of stepping
            .animation(.smooth(duration: 0.6), value: value)

            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .monoDigits()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A small labelled stat chip (temp, power, load…).
struct StatChip: View {
    var icon: String
    var value: String
    var label: String
    var tint: Color = Theme.accent

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monoDigits()
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// A labelled horizontal usage bar (disk, memory…).
struct UsageBar: View {
    var title: String
    var systemImage: String
    var ratio: Double          // 0…1
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(caption)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .monoDigits()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Theme.heat(ratio).opacity(0.8), Theme.heat(ratio)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * min(max(ratio, 0), 1)))
                        .animation(.smooth(duration: 0.5), value: ratio)
                }
            }
            .frame(height: 12)
        }
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .textCase(.uppercase)
            .kerning(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
    }
}
