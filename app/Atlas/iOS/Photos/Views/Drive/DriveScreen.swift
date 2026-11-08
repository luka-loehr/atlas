import SwiftUI

/// Der Google-Drive-Teil der Atlas-Photos-App: Ordnerbaum + Dateien vom atlas
/// (content-addressed Blobs). Root trägt Suche + Papierkorb; jede Ebene kann
/// hochladen, anlegen, umbenennen, verschieben, löschen.
struct DriveScreen: View {
    var library: Library
    /// The search tab opened from Dateien: the root becomes a file search.
    var searchMode = false

    var body: some View {
        NavigationStack {
            DriveFolderScreen(client: DriveClient(host: library.host), isRoot: true, searchMode: searchMode)
                .navigationDestination(for: DriveFolder.self) { f in
                    DriveFolderScreen(client: DriveClient(host: library.host),
                                      folder: f.id, title: f.name)
                }
                .navigationDestination(for: DriveCrumb.self) { c in
                    DriveFolderScreen(client: DriveClient(host: library.host),
                                      folder: c.id, title: c.name)
                }
                .navigationDestination(for: DriveTrashRoute.self) { _ in
                    DriveTrashScreen(client: DriveClient(host: library.host))
                }
        }
    }
}

struct DriveTrashRoute: Hashable {}

/// Ziel einer Verschieben-Aktion (Datei oder Ordner) für den Picker-Sheet.
enum DriveMoveTarget: Identifiable {
    case file(DriveFile)
    case folder(DriveFolder)
    var id: String {
        switch self {
        case .file(let f): return "f\(f.id)"
        case .folder(let d): return "d\(d.id)"
        }
    }
}
