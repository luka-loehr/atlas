import SwiftUI

/// Round floating button (system-background circle, primary icon) — Google-Photos chrome.
/// `nudge` shifts the glyph vertically for optical centering: symbols like
/// square.and.arrow.up carry their visual mass (the box) below the bounding-box
/// center, so geometric centering makes them sit visibly low in the circle.
struct CircleButton: View {
    let icon: String
    /// VoiceOver name of the icon-only button.
    let label: String
    var nudge: CGFloat = 0
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.primary)
                .offset(y: nudge)
                .frame(width: size, height: size)
                .glassEffect(.regular, in: .circle)   // iOS 26 Liquid Glass
        }
        .accessibilityLabel(label)
    }
}
