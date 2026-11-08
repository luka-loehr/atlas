import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Deleted files: recovered or deleted for good.
struct MacDriveTrash: View {
    @Environment(AppModel.self) private var model
    @State private var files: [DriveFile] = []
    @State private var loaded = false
    @State private var selection: Set<Int> = []
    @State private var confirmEmpty = false
    @State private var confirmDelete: [Int]?
    @State private var changeFailed = false

    private var client: DriveClient { DriveClient(host: model.library.host) }

    var body: some View {
        NavigationStack {
            Table(files, selection: $selection) {
                TableColumn("Name") { f in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (f.name as NSString).pathExtension) ?? .data))
                            .resizable().frame(width: 18, height: 18)
                        Text(f.name).lineLimit(1)
                    }
                }
                .width(min: 200, ideal: 360)
                TableColumn("Size") { f in Text(f.size.fileSize).foregroundStyle(.secondary).monospacedDigit() }
                    .width(min: 60, ideal: 90)
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                if !ids.isEmpty {
                    Button("Recover") { change(Array(ids)) { try await client.restore(Array(ids)) } }
                    Button("Delete Permanently…", role: .destructive) { confirmDelete = Array(ids) }
                }
            }
            .overlay {
                if loaded && files.isEmpty {
                    ContentUnavailableView("No Deleted Files", systemImage: "trash")
                } else if !loaded {
                    ProgressView()
                }
            }
            .navigationTitle("Deleted Files")
            .navigationSubtitle(files.isEmpty ? "" : "\(files.count) \(files.count == 1 ? "File" : "Files")")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Recover", systemImage: "arrow.uturn.backward") {
                        change(Array(selection)) { try await client.restore(Array(selection)) }
                    }
                    .help("Recover")
                    .disabled(selection.isEmpty)
                    Button("Empty…") { confirmEmpty = true }
                        .disabled(files.isEmpty)
                }
            }
            .confirmationDialog("Delete All Deleted Files Permanently?", isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    change(files.map(\.id)) { try await client.emptyTrash() }
                }
            } message: {
                Text("All \(files.count) files will be deleted permanently. This can’t be undone.")
            }
            .confirmationDialog("Delete Permanently?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible, presenting: confirmDelete) { ids in
                Button("Delete Permanently", role: .destructive) { change(ids) { try await client.deletePermanent(ids) } }
            } message: { _ in
                Text("This can’t be undone.")
            }
            .changeFailedAlert($changeFailed)
            .task { await load() }
        }
    }

    private func load() async {
        if let fresh = try? await client.trash() { files = fresh }
        loaded = true
    }

    private func change(_ ids: [Int], _ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                let gone = Set(ids)
                withAnimation { files.removeAll { gone.contains($0.id) } }
                selection.subtract(gone)
            } catch {
                changeFailed = true
            }
        }
    }
}
