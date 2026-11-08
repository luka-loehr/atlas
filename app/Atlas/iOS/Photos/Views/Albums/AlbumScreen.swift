import SwiftUI

/// One album's photos, with adding, removing, renaming and deleting.
struct AlbumScreen: View {
    var library: Library
    var album: Album
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var assets: [Asset] = []
    @State private var loaded = false
    @State private var selection = Selection()
    @State private var picking = false
    @State private var renaming = false
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var changeFailed = false
    @State private var shareLink: ShareLinkItem?

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if assets.isEmpty && loaded {
                ContentUnavailableView {
                    Label("No Photos", systemImage: "photo.on.rectangle")
                } actions: {
                    Button("Add Photos") { picking = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                AssetGrid(library: library, assets: assets, selection: selection,
                          onRefresh: { await load() }, onViewerClosed: { Task { await load() } }, underBar: true)
                    .selectionToolbar(selection, actions: [
                    .init(title: "Remove from Album", icon: "minus.circle", role: .destructive) { removeSelected() },
                ])
            }
            if busy { BusyBox() }
        }
        .navigationTitle(title.isEmpty ? album.title : title)
        .navigationSubtitle(loaded ? (assets.count == 1 ? "1 Item" : "\(assets.count.formatted()) Items")
                                   : (album.count == 1 ? "1 Item" : "\(album.count.formatted()) Items"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if selection.active {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { withAnimation(.snappy) { selection.exit() } }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Photos", systemImage: "plus") { picking = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        if !assets.isEmpty {
                            Button("Select", systemImage: "checkmark.circle") {
                                withAnimation(.snappy) { selection.enter() }
                            }
                        }
                        if library.sharing, !assets.isEmpty {
                            Button("Share Link…", systemImage: "link") {
                                shareLink = ShareLinkItem(title: title.isEmpty ? album.title : title, album: album.id)
                            }
                        }
                        Button("Rename", systemImage: "pencil") { renaming = true }
                        Button("Delete Album", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $picking) {
            PhotoPickerSheet(library: library, title: "Add to “\(title.isEmpty ? album.title : title)”") { ids in
                act { try await library.client.addToAlbum(album.id, ids) }
            }
        }
        .sheet(item: $shareLink) { item in
            ShareLinkSheet(library: library, item: item)
        }
        .albumNameAlert("Rename Album", isPresented: $renaming, initial: title.isEmpty ? album.title : title) { new in
            act {
                try await library.client.renameAlbum(album.id, to: new)
                title = new
            }
        }
        .confirmationDialog("Delete “\(title.isEmpty ? album.title : title)”?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete Album", role: .destructive) {
                act {
                    try await library.client.deleteAlbum(album.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photos stay in your library.")
        }
        .changeFailedAlert($changeFailed)
    }

    private func load() async {
        // a failed reload keeps what is shown
        if let fresh = try? await library.client.albumAssets(album.id) { assets = fresh }
        loaded = true
    }

    private func removeSelected() {
        let ids = Array(selection.ids)
        guard !ids.isEmpty else { return }
        act {
            try await library.client.removeFromAlbum(album.id, ids)
            let gone = Set(ids)
            withAnimation(.snappy) { assets.removeAll { gone.contains($0.id) } }
            withAnimation(.snappy) { selection.exit() }
        }
    }

    /// A change to this album, then the album and the Albums tab read again.
    private func act(_ op: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await op()
                NotificationCenter.default.post(name: .atlasAlbumsChanged, object: nil)
                await load()
            } catch {
                changeFailed = true
            }
        }
    }
}
