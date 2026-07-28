import SwiftUI

/// The Lightshow identity: near-black stage, electric violet + hot pink.
/// Member names match the admin app so shared views port over unchanged.
enum Theme {
    static let bgTop = Color(red: 0.055, green: 0.03, blue: 0.10)
    static let bgBottom = Color(red: 0.01, green: 0.01, blue: 0.03)
    static let accent = Color(red: 0.62, green: 0.42, blue: 1.0)      // electric violet
    static let violet = Color(red: 1.0, green: 0.36, blue: 0.62)     // hot pink (secondary)
    static let good = Color(red: 0.20, green: 0.85, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.20)
    static let hot = Color(red: 1.0, green: 0.35, blue: 0.42)

    static var background: some View {
        LinearGradient(
            colors: [bgTop, bgBottom],
            startPoint: .top, endPoint: .bottom
        )
        .overlay(alignment: .top) {
            RadialGradient(
                colors: [accent.opacity(0.20), .clear],
                center: .init(x: 0.25, y: 0), startRadius: 0, endRadius: 380
            )
            .blur(radius: 30)
        }
        .overlay(alignment: .topTrailing) {
            RadialGradient(
                colors: [violet.opacity(0.12), .clear],
                center: .init(x: 0.9, y: 0.05), startRadius: 0, endRadius: 320
            )
            .blur(radius: 36)
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
