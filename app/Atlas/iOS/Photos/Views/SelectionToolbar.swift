import SwiftUI

// MARK: - Generic action toolbar (Dienstprogramme: Wiederherstellen/Löschen …)

/// Eine frei definierbare Auswahl-Aktion für `.selectionToolbar(_:actions:)`.
struct SelectionAction: Identifiable {
    /// The title: stable across renders, so the buttons are not rebuilt.
    var id: String { title }
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
                        Image(systemName: action.icon).font(.title3)
                        Text(action.title).font(.caption2.weight(.medium)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(action.role == .destructive ? Color.red : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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

// MARK: - VoiceOver for photo grid cells

extension View {
    /// One VoiceOver element per grid cell: kind and date, a button trait,
    /// and — while selecting (`selected` non-nil) — the selected state.
    func assetAccessibility(_ asset: Asset, selected: Bool? = nil) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(asset.spokenDescription)
            .accessibilityAddTraits(selected == true ? [.isButton, .isSelected] : .isButton)
    }
}
