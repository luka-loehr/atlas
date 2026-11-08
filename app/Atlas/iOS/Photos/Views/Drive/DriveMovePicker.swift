import SwiftUI

/// Ordner-Browser im Sheet: hineinnavigieren (System-Zurück), dann
/// „Verschieben“. Der Server verhindert Zyklen (Ordner in sich selbst).
struct DriveMovePicker: View {
    let client: DriveClient
    let target: DriveMoveTarget
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var moveFailed = false

    var body: some View {
        NavigationStack {
            DriveMoveLevel(client: client, target: target, folder: nil, title: "Files", move: move)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .navigationDestination(for: DriveCrumb.self) { c in
                    DriveMoveLevel(client: client, target: target, folder: c.id, title: c.name, move: move)
                }
        }
        .presentationDetents([.medium, .large])
        .changeFailedAlert($moveFailed)
    }

    private func move(to folder: Int?) async {
        do {
            switch target {
            case .file(let f): try await client.move(files: [f.id], to: folder)
            case .folder(let d): try await client.move(folders: [d.id], to: folder)
            }
        } catch {
            moveFailed = true
            return
        }
        onDone()
        dismiss()
    }
}

/// Eine Ebene im Verschieben-Sheet.
private struct DriveMoveLevel: View {
    let client: DriveClient
    let target: DriveMoveTarget
    let folder: Int?
    let title: String
    let move: (Int?) async -> Void

    @State private var folders: [DriveFolder] = []
    @State private var busy = false

    var body: some View {
        List {
            ForEach(folders.filter { !isMoving($0) }) { f in
                NavigationLink(value: DriveCrumb(id: f.id, name: f.name)) {
                    Label(f.name, systemImage: "folder.fill")
                        .lineLimit(1)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if busy {
                    ProgressView()
                } else {
                    Button("Move") {
                        busy = true
                        Task { await move(folder); busy = false }
                    }
                }
            }
        }
        .task { folders = (try? await client.list(folder: folder))?.folders ?? [] }
    }

    private func isMoving(_ f: DriveFolder) -> Bool {
        if case .folder(let d) = target { return d.id == f.id }
        return false
    }
}
