import Foundation
import Observation

/// Auswahl-Zustand für den Foto-Grid (Apple-Fotos-Stil "Auswählen").
/// Wird über Asset-IDs (blake3-Hash, `Asset.id`) geführt — passt zu `Asset: Hashable`.
/// Als `@Observable` an Zellen weiterreichen; Reads in `body` registrieren die
/// Abhängigkeit automatisch, es braucht kein `@State`/`@Bindable` an den Zellen.
@MainActor
@Observable
final class Selection {
    /// Auswahl-Modus aktiv (Grid zeigt Häkchen, Tap togglet statt zu öffnen).
    var active = false
    /// Aktuell ausgewählte Asset-IDs.
    var ids: Set<String> = []

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: String) -> Bool { ids.contains(id) }

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

    /// Sind exakt die übergebenen IDs komplett ausgewählt?
    func allSelected(of all: [String]) -> Bool {
        !all.isEmpty && ids.count == all.count
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
