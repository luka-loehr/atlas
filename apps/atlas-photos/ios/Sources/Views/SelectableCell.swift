import SwiftUI

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

/// Legt den Auswahl-Look (Inset-Skalierung + Ecken + Abdunkeln + Häkchen) über
/// beliebigen Zell-Inhalt und übernimmt die Tap-Logik. Tap im Auswahl-Modus
/// togglet; sonst wird `onOpen()` gerufen (z. B. Viewer öffnen).
///
/// Nutzung an einer bestehenden Zelle:
/// ```
/// Color.clear.aspectRatio(1, contentMode: .fill).overlay { Thumb(url: …) }
///     .selectable(id: asset.id, selection: selection) { pick = asset }
/// ```
struct SelectableModifier: ViewModifier {
    let id: String
    var selection: Selection
    let onOpen: () -> Void

    func body(content: Content) -> some View {
        let isSel = selection.contains(id)
        content
            .scaleEffect(isSel ? 0.88 : 1)
            .clipShape(RoundedRectangle(cornerRadius: isSel ? 9 : 0, style: .continuous))
            .overlay {
                if isSel {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.black.opacity(0.18))   // dezentes Abdunkeln
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if selection.active {
                    SelectionBadge(selected: isSel)
                        .padding(5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if selection.active {
                    withAnimation(selectSpring) { selection.toggle(id) }
                } else {
                    onOpen()
                }
            }
    }
}

extension View {
    /// Macht eine Grid-Zelle auswählbar (siehe `SelectableModifier`).
    func selectable(id: String, selection: Selection,
                    onOpen: @escaping () -> Void) -> some View {
        modifier(SelectableModifier(id: id, selection: selection, onOpen: onOpen))
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
    var selection: Selection
    let namespace: Namespace.ID
    let onOpen: () -> Void

    var body: some View {
        let isSel = selection.contains(asset.id)
        Color.clear
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                Thumb(url: thumbURL)
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
                if selection.active {
                    withAnimation(selectSpring) { selection.toggle(asset.id) }
                } else {
                    onOpen()
                }
            }
    }
}
