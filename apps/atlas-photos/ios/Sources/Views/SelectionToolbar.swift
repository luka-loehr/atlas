import SwiftUI

/// Schwebende Aktions-Pille unten (Apple-Fotos-Stil, iOS-26 Liquid Glass).
/// Teilen / Favorit / Archiv / Sperren / Papierkorb. Aktionen sind deaktiviert,
/// solange nichts ausgewählt ist. Die Ein-/Ausblend-Animation liefert der
/// `.selectionToolbar(…)`-Modifier weiter unten.
struct SelectionToolbar: View {
    var selection: Selection
    var onShare: () -> Void
    var onFavorite: () -> Void
    var onArchive: () -> Void
    var onLock: () -> Void
    var onTrash: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            button("Teilen",     "square.and.arrow.up", action: onShare)
            button("Favorit",    "heart",               action: onFavorite)
            button("Archiv",     "archivebox",          action: onArchive)
            button("Sperren",    "lock",                action: onLock)
            button("Papierkorb", "trash", tint: .red,   action: onTrash)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)      // iOS 26 Liquid Glass
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
        .disabled(selection.isEmpty)
        .opacity(selection.isEmpty ? 0.5 : 1)
        .animation(.snappy(duration: 0.3), value: selection.isEmpty)
    }

    private func button(_ title: String, _ icon: String,
                        tint: Color = .white,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Blendet die `SelectionToolbar` als unteren Safe-Area-Inset ein, sobald
    /// `selection.active` ist — sanftes Feder-Slide-in von unten (Apple-Ton).
    /// Legt sich um den Grid-Container (schiebt Content sauber hoch).
    func selectionToolbar(_ selection: Selection,
                          onShare: @escaping () -> Void,
                          onFavorite: @escaping () -> Void,
                          onArchive: @escaping () -> Void,
                          onLock: @escaping () -> Void,
                          onTrash: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom) {
            if selection.active {
                SelectionToolbar(selection: selection,
                                 onShare: onShare,
                                 onFavorite: onFavorite,
                                 onArchive: onArchive,
                                 onLock: onLock,
                                 onTrash: onTrash)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: selection.active)
    }
}

// MARK: - Generic action toolbar (Dienstprogramme: Wiederherstellen/Löschen …)

/// Eine frei definierbare Auswahl-Aktion für `.selectionToolbar(_:actions:)`.
struct SelectionAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var role: ButtonRole? = nil
    let run: () -> Void

    init(title: String, icon: String, role: ButtonRole? = nil, run: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.role = role; self.run = run
    }
}

private struct GenericSelectionToolbar: View {
    var selection: Selection
    var actions: [SelectionAction]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(actions) { action in
                Button(action: action.run) {
                    VStack(spacing: 3) {
                        Image(systemName: action.icon).font(.system(size: 20))
                        Text(action.title).font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(action.role == .destructive ? Color.red : .white)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
        .disabled(selection.isEmpty)
        .opacity(selection.isEmpty ? 0.5 : 1)
        .animation(.snappy(duration: 0.3), value: selection.isEmpty)
    }
}

extension View {
    /// Wie oben, aber mit frei definierten Aktionen (Restore/Delete je Sammlung).
    func selectionToolbar(_ selection: Selection, actions: [SelectionAction]) -> some View {
        safeAreaInset(edge: .bottom) {
            if selection.active {
                GenericSelectionToolbar(selection: selection, actions: actions)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: selection.active)
    }
}
