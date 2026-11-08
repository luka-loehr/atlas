import Foundation
import Observation

/// Auswahl-Zustand für den Foto-Grid (Apple-Fotos-Stil "Auswählen").
/// Wird über Asset-IDs (SHA-256-Hash, `Asset.id`) geführt. `@Observable`:
/// der Grid und die Leisten, die ihn in `body` lesen, folgen ihm.
@MainActor
@Observable
final class Selection {
    /// Auswahl-Modus aktiv (Grid zeigt Häkchen, Tap togglet statt zu öffnen).
    var active = false
    /// Aktuell ausgewählte Asset-IDs.
    var ids: Set<String> = []

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    /// Ein einzelnes Asset an-/abwählen.
    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    /// Alle übergebenen IDs auswählen (z. B. "Alle auswählen").
    func selectAll(_ all: [String]) {
        ids = Set(all)
    }

    /// Nur die Auswahl leeren, Modus bleibt aktiv.
    func clear() {
        ids.removeAll()
    }

    /// Auswahl-Modus betreten, optional mit einem ersten Asset (aus dem Kontextmenü).
    func enter(with id: String? = nil) {
        active = true
        if let id { ids.insert(id) }
    }

    /// Auswahl-Modus verlassen und Auswahl leeren.
    func exit() {
        active = false
        ids.removeAll()
    }
}
