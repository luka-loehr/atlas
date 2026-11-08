import SwiftUI

/// A collection of the Media Types or Utilities lists, with the actions
/// that fit it in a selection toolbar.
struct SpecialCollectionScreen: View {
    var library: Library
    let kind: SpecialKind

    @State private var assets: [Asset] = []
    @State private var loaded = false
    @State private var selection = Selection()
    @State private var confirmEmpty = false
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var changeFailed = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if assets.isEmpty && loaded {
                empty
            } else {
                grid
            }
            if busy { BusyBox() }
        }
        .navigationTitle(kind.title)
        // the server removes trashed items for good after 30 days
        .navigationSubtitle(kind == .trash ? "Deleted permanently after 30 days" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if selection.active {
                    Button("Done") { withAnimation(.snappy) { selection.exit() } }
                } else if !assets.isEmpty && !toolbarActions.isEmpty {
                    Button("Select") { withAnimation(.snappy) { selection.enter() } }
                }
            }
            if kind == .trash && !assets.isEmpty && !selection.active {
                ToolbarItem(placement: .bottomBar) {
                    Button("Delete All", role: .destructive) { confirmEmpty = true }
                        .confirmationDialog("Delete All Items?", isPresented: $confirmEmpty, titleVisibility: .visible) {
                            Button("Delete Permanently", role: .destructive) {
                                act { try await library.client.emptyTrash() }
                            }
                        } message: {
                            Text("All \(assets.count) items will be deleted permanently.")
                        }
                }
            }
        }
        .task { await load() }
        .confirmationDialog(selection.count == 1 ? "Delete 1 Item Permanently?" : "Delete \(selection.count) Items Permanently?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                let ids = Array(selection.ids)
                act(remove: ids) { try await library.client.deletePermanent(ids) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .changeFailedAlert($changeFailed)
    }

    private var grid: some View {
        // what the viewer did (archive, lock, delete) may move items in or
        // out of this collection: it is read again when the viewer closes
        AssetGrid(library: library, assets: assets, selection: selection,
                  onRefresh: { await load() }, onViewerClosed: { Task { await load() } }, underBar: true)
            .selectionToolbar(selection, actions: toolbarActions)
    }

    /// Restore/delete actions depend on the collection.
    private var toolbarActions: [SelectionAction] {
        let ids = { Array(selection.ids) }
        switch kind {
        case .favorites:
            return [
                .init(title: "Unfavorite", icon: "heart.slash") {
                    let x = ids()
                    act(remove: x) {
                        try await library.client.favorite(x, false)
                        library.setFavorite(Set(x), false)
                    }
                },
            ]
        case .videos:
            return [
                .init(title: "Favorite", icon: "heart") {
                    let x = ids()
                    act {
                        try await library.client.favorite(x, true)
                        library.setFavorite(Set(x), true)
                    }
                },
            ]
        case .trash:
            return [
                .init(title: "Recover", icon: "arrow.uturn.backward") {
                    let x = ids(); act(remove: x) { try await library.client.restore(x) }
                },
                .init(title: "Delete", icon: "trash", role: .destructive) { confirmDelete = true },
            ]
        case .archive:
            return [
                .init(title: "Unarchive", icon: "tray.and.arrow.up") {
                    let x = ids(); act(remove: x) { try await library.client.archive(x, false) }
                },
            ]
        case .locked:
            return [
                .init(title: "Unlock", icon: "lock.open") {
                    let x = ids(); act(remove: x) { try await library.client.lock(x, false) }
                },
            ]
        }
    }

    @ViewBuilder
    private var empty: some View {
        switch kind {
        case .favorites:
            ContentUnavailableView("No Favorites", systemImage: kind.icon,
                                   description: Text("Tap the heart on a photo to add it here."))
        case .videos:
            ContentUnavailableView("No Videos", systemImage: kind.icon)
        case .trash:
            ContentUnavailableView("No Recently Deleted Items", systemImage: kind.icon)
        case .archive:
            ContentUnavailableView("No Archived Items", systemImage: kind.icon)
        case .locked:
            ContentUnavailableView("No Locked Items", systemImage: kind.icon)
        }
    }

    private func load() async {
        // a failed reload keeps what is shown
        do {
            switch kind {
            case .favorites: assets = try await library.client.collection("/library/favorites")
            case .videos:  assets = try await library.client.collection("/library/videos")
            case .locked:  assets = try await library.client.listLocked()
            case .archive: assets = try await library.client.listArchive()
            case .trash:   assets = try await library.client.listTrash()
            }
        } catch {}
        loaded = true
    }

    /// Run a mutation, then drop `remove` ids from the local grid (or reload
    /// it), and refresh the timeline the items return to.
    private func act(remove: [String] = [], _ op: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await op()
                if remove.isEmpty {
                    await load()               // e.g. empty-trash: reload the (now empty) set
                } else {
                    let gone = Set(remove)
                    withAnimation(.snappy) { assets.removeAll { gone.contains($0.id) } }
                }
                // recovered, unarchived and unlocked items are back in the library
                if kind != .trash || !remove.isEmpty { await library.refresh() }
            } catch {
                changeFailed = true
            }
            withAnimation(.snappy) { selection.exit() }
        }
    }
}
