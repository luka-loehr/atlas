import SwiftUI
import UIKit

/// Feder für das An-/Abwählen einer Zelle — schnell, minimal-bouncy (Apple-Ton).
private let selectSpring: Animation = .snappy(duration: 0.26, extraBounce: 0.05)

/// Das Auswahl-Häkchen unten-rechts in fester Größe (skaliert NICHT mit dem Thumb).
/// Ausgewählt: weißes Häkchen auf Apple-blauem Kreis. Sonst: dünner weißer Ring.
struct SelectionBadge: View {
    let selected: Bool
    var body: some View {
        if selected {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .blue)
                .font(.system(size: 22))
                .shadow(color: .black.opacity(0.35), radius: 2)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.4), radius: 2)
        }
    }
}

/// Fertige, auswählbare Foto-Zelle — Drop-in-Ersatz für `PhotosScreen.cell(asset)`.
/// Rendert Thumb + Video-Badge + Auswahl-Häkchen und behandelt Tap/Zoom-Quelle.
/// Die Paginierung (`loadMoreIfNeeded`) bleibt Aufgabe des Aufrufers via `.task`.
///
/// Nutzung:
/// ```
/// SelectableThumb(asset: asset,
///                 thumbURL: library.client.thumbURL(asset.id, 256),
///                 selection: selection, namespace: zoom) { pick = asset }
///     .task { await library.loadMoreIfNeeded(current: asset) }
/// ```
struct SelectableThumb: View {
    let asset: Asset
    let thumbURL: URL?
    var maxPixel: CGFloat? = nil
    var selection: Selection
    let namespace: Namespace.ID
    let onOpen: () -> Void

    /// Nach erfolgreichem Long-Press feuert beim Loslassen AUCH der Tap —
    /// ohne Guard würde er das eben ausgewählte Foto sofort wieder abwählen.
    /// Timestamp statt Bool: Feuert der Tap ausnahmsweise NICHT (Finger beim
    /// Heben verrutscht, Touch gecancelt), verfällt der Guard von selbst und
    /// frisst nicht den nächsten echten Tap.
    @State private var holdFiredAt: Date?

    var body: some View {
        let isSel = selection.contains(asset.id)
        Color.clear
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                Thumb(url: thumbURL, maxPixel: maxPixel)
                    .scaleEffect(isSel ? 0.88 : 1)
                    .clipShape(RoundedRectangle(cornerRadius: isSel ? 9 : 0, style: .continuous))
                    .overlay {
                        if isSel {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(.black.opacity(0.18))
                        }
                    }
                    .clipped()
            }
            // Video-Badge (nur wenn NICHT selektiert, sonst kollidiert es mit dem Haken)
            .overlay(alignment: .bottomTrailing) {
                if asset.isVideo && !isSel {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            // Auswahl-Häkchen
            .overlay(alignment: .bottomTrailing) {
                if selection.active {
                    SelectionBadge(selected: isSel)
                        .padding(5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .matchedTransitionSource(id: asset.id, in: namespace)
            .onTapGesture {
                if let t = holdFiredAt, Date().timeIntervalSince(t) < 0.8 {
                    holdFiredAt = nil
                    return
                }
                if selection.active {
                    withAnimation(selectSpring) { selection.toggle(asset.id) }
                } else {
                    onOpen()
                }
            }
            // Apple-Fotos-Geste: gedrückt halten → Auswahl-Modus mit diesem Bild.
            // simultaneousGesture, damit der ScrollView-Pan die Geste nicht
            // schluckt; 12pt Toleranz: genug gegen Finger-Mikro-Wackler, aber
            // knapp genug, dass langsames Scrollen nicht falsch auslöst.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35, maximumDistance: 12)
                    .onEnded { _ in
                        guard !selection.active else { return }
                        holdFiredAt = Date()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(selectSpring) { selection.enter(with: asset.id) }
                    }
            )
    }
}
