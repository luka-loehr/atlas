import SwiftUI

enum Theme {
    static let bgTop = Color(red: 0.04, green: 0.05, blue: 0.09)
    static let bgBottom = Color(red: 0.02, green: 0.02, blue: 0.04)
    static let accent = Color(red: 0.22, green: 0.60, blue: 1.0)      // atlas blue
    static let good = Color(red: 0.20, green: 0.85, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.20)
    static let hot = Color(red: 1.0, green: 0.35, blue: 0.42)
    static let violet = Color(red: 0.55, green: 0.45, blue: 1.0)

    /// Green → amber → red as a load ratio (0…1) climbs.
    static func heat(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.6: return good
        case ..<0.85: return warn
        default: return hot
        }
    }

    static var background: some View {
        LinearGradient(
            colors: [bgTop, bgBottom],
            startPoint: .top, endPoint: .bottom
        )
        .overlay(alignment: .top) {
            RadialGradient(
                colors: [accent.opacity(0.18), .clear],
                center: .top, startRadius: 0, endRadius: 420
            )
            .blur(radius: 30)
        }
        .ignoresSafeArea()
    }
}

/// A floating Liquid-Glass card.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }
}

extension View {
    /// Tabular figures so live-updating numbers don't jitter.
    func monoDigits() -> some View {
        self.monospacedDigit().contentTransition(.numericText())
    }
}
