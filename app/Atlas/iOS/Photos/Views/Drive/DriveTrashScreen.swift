import SwiftUI

struct DriveTrashScreen: View {
    let client: DriveClient
    @State private var files: [DriveFile] = []
    @State private var loaded = false
    @State private var confirmEmpty = false
    @State private var deleting: DriveFile?
    @State private var changeFailed = false

    var body: some View {
        List {
            ForEach(files) { f in
                HStack(spacing: 12) {
                    DriveIcon(file: f.name)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name)
                            .lineLimit(1)
                        Text(f.size.fileSize)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button { restore(f) } label: {
                        Label("Recover", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing) {
                    Button { deleting = f } label: {
                        Label("Delete Permanently", systemImage: "trash.slash")
                    }
                    .tint(.red)
                }
                .contextMenu {
                    Button { restore(f) } label: {
                        Label("Recover", systemImage: "arrow.uturn.backward")
                    }
                    Button(role: .destructive) { deleting = f } label: {
                        Label("Delete Permanently", systemImage: "trash.slash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !files.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button("Empty Trash", role: .destructive) { confirmEmpty = true }
                        .confirmationDialog("Empty Trash?", isPresented: $confirmEmpty, titleVisibility: .visible) {
                            Button("Delete Permanently", role: .destructive) {
                                Task {
                                    do { try await client.emptyTrash() } catch { changeFailed = true }
                                    await load()
                                }
                            }
                        } message: {
                            Text("All \(files.count) files will be deleted permanently.")
                        }
                }
            }
        }
        .overlay {
            if files.isEmpty && loaded {
                ContentUnavailableView("Trash Is Empty", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")” Permanently?",
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                if let f = deleting { delete(f) }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .changeFailedAlert($changeFailed)
    }

    private func restore(_ f: DriveFile) {
        remove(f) { try await client.restore([f.id]) }
    }

    private func delete(_ f: DriveFile) {
        remove(f) { try await client.deletePermanent([f.id]) }
    }

    /// The file leaves the trash once the server agreed.
    private func remove(_ f: DriveFile, _ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                withAnimation(.snappy) { files.removeAll { $0.id == f.id } }
            } catch {
                changeFailed = true
            }
        }
    }

    private func load() async {
        // a failed reload keeps what is shown
        if let fresh = try? await client.trash() { files = fresh }
        loaded = true
    }
}
