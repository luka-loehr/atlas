import SwiftUI

struct AlbumsScreen: View {
    var library: Library
    @State private var albums: [Album] = []
    @State private var loaded = false
    @State private var openAlbum: Album?
    @State private var openSpecial: SpecialKind?
    @State private var authing = false

    private let cols = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                ScrollView {
                    peopleRow
                    utilities
                    if !userAlbums.isEmpty {
                        sectionHeader("My Albums")
                        LazyVGrid(columns: cols, spacing: 18) {
                            ForEach(userAlbums) { album in
                                Button { openAlbum = album } label: {
                                    AlbumCard(library: library, album: album)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    } else if loaded {
                        ContentUnavailableView("No Albums", systemImage: "rectangle.stack")
                            .padding(.top, 24)
                    }
                }
                .scrollIndicators(.hidden)
                .refreshable { await load() }
            }
            .navigationTitle("Albums")
            .navigationDestination(item: $openAlbum) { album in
                AlbumScreen(library: library, album: album)
            }
            .navigationDestination(item: $openSpecial) { kind in
                SpecialCollectionScreen(library: library, kind: kind)
            }
        }
        // once per launch, not on every tab switch; pull to refresh reloads
        .task { if !loaded { await load() } }
    }

    // MARK: - Personen (horizontal preview row -> PersonsScreen)

    @State private var personsPreview: [Person] = PeopleMemo.people
    @State private var personsFetched = false

    private var peopleRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink {
                PersonsScreen(library: library)
            } label: {
                HStack {
                    sectionHeader("People")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 16)
                        .padding(.top, 8)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            if !personsPreview.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(personsPreview.prefix(12)) { person in
                            NavigationLink {
                                PersonDetailScreen(library: library, person: person)
                            } label: {
                                VStack(spacing: 6) {
                                    FaceCircle(library: library, person: person)
                                        .frame(width: 72, height: 72)
                                    Text(person.displayName)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(person.name == nil
                                                         ? .tertiary : .primary)
                                        .lineLimit(1)
                                        .frame(width: 76)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .task {
            guard !personsFetched, let people = try? await library.client.persons() else { return }
            personsFetched = true
            if people != personsPreview { personsPreview = people }
            PeopleMemo.people = people
        }
    }

    // MARK: - Utilities (Dienstprogramme)

    private var utilities: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Utilities")
            VStack(spacing: 0) {
                utilityRow(.locked)
                divider
                utilityRow(.archive)
                divider
                utilityRow(.trash)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .disabled(authing)
        }
    }

    private func utilityRow(_ kind: SpecialKind) -> some View {
        Button { openSpecial(kind) } label: {
            HStack(spacing: 14) {
                Image(systemName: kind.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(kind.tint.gradient, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                Text(kind.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle().fill(Color(.separator).opacity(0.5)).frame(height: 1).padding(.leading, 62)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.title3.bold())
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)
    }

    // MARK: - Data

    /// Real user albums only — Takeout's "Trash"/"Locked Folder" album rows
    /// are surfaced through Dienstprogramme instead.
    private var userAlbums: [Album] {
        albums.filter { !SpecialAlbum.isLocked($0.title) && !SpecialAlbum.isTrash($0.title) }
    }

    private func openSpecial(_ kind: SpecialKind) {
        guard kind == .locked else { openSpecial = kind; return }
        authing = true
        Task {
            let ok = await Biometric.authenticate(reason: "Unlock the Locked album")
            authing = false
            if ok { openSpecial = .locked }
        }
    }

    private func load() async {
        // a failed reload keeps what is shown; an unchanged list is not reassigned
        if let fresh = try? await library.client.albums(), fresh != albums { albums = fresh }
        loaded = true
    }
}

// MARK: - Special collections

enum SpecialKind: String, Identifiable, Hashable {
    case locked, archive, trash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .locked:  return "Locked"
        case .archive: return "Archive"
        case .trash:   return "Recently Deleted"
        }
    }
    var icon: String {
        switch self {
        case .locked:  return "lock.fill"
        case .archive: return "archivebox.fill"
        case .trash:   return "trash.fill"
        }
    }
    var tint: Color {
        switch self {
        case .locked:  return .gray
        case .archive: return .orange
        case .trash:   return .red
        }
    }
}

/// A Dienstprogramm collection (Gesperrt / Archiv / Papierkorb) with the
/// appropriate restore / empty actions in a selection toolbar.
struct SpecialCollectionScreen: View {
    var library: Library
    let kind: SpecialKind

    @State private var assets: [Asset] = []
    @State private var loaded = false
    @State private var pick: Asset?
    @State private var selection = Selection()
    @State private var confirmEmpty = false
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var changeFailed = false
    @Namespace private var zoom

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if assets.isEmpty && loaded {
                empty
            } else {
                grid
            }
            if busy {
                ProgressView().padding(20)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle(kind.title)
        // the server removes trashed items for good after 30 days
        .navigationSubtitle(kind == .trash ? "Deleted permanently after 30 days" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if selection.active {
                    Button("Done") { withAnimation(.snappy) { selection.exit() } }
                } else if !assets.isEmpty {
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
        // what the viewer did (archive, lock, delete) may move items in or
        // out of this collection: it is read again
        .fullScreenCover(item: $pick, onDismiss: { Task { await load() } }) { a in
            ViewerScreen(library: library, assets: assets, start: a)
                .navigationTransition(.zoom(sourceID: a.id, in: zoom))
        }
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
        ScrollView {
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(assets) { asset in
                    SelectableThumb(asset: asset,
                                    thumbURL: library.client.thumbURL(asset.id, 512),
                                    selection: selection, namespace: zoom) { pick = asset }
                        .assetAccessibility(asset, selected: selection.active ? selection.contains(asset.id) : nil)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .refreshable { await load() }
        .selectionToolbar(selection, actions: toolbarActions)
    }

    /// Restore/delete actions depend on the collection.
    private var toolbarActions: [SelectionAction] {
        let ids = { Array(selection.ids) }
        switch kind {
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

    private var empty: some View {
        ContentUnavailableView(kind == .trash ? "No Recently Deleted Items"
                               : kind == .archive ? "No Archived Items" : "No Locked Items",
                               systemImage: kind.icon)
    }

    private func load() async {
        // a failed reload keeps what is shown
        do {
            switch kind {
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

struct AlbumCard: View {
    var library: Library
    var album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)     // square, fits column width
                .overlay {
                    Thumb(url: album.cover.flatMap { library.client.thumbURL($0, 512) })
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(album.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("\(album.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(album.title)
        .accessibilityValue("\(album.count) \(album.count == 1 ? "item" : "items")")
    }
}

/// One album's photos (reuses the grid + viewer).
struct AlbumScreen: View {
    var library: Library
    var album: Album
    @State private var assets: [Asset] = []
    @State private var pick: Asset?
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            ScrollView {
                LazyVGrid(columns: cols, spacing: 2) {
                    ForEach(assets) { asset in
                        Color.clear.aspectRatio(1, contentMode: .fill)
                            .overlay { Thumb(url: library.client.thumbURL(asset.id, 512)).clipped() }
                            .clipped()
                            .onTapGesture { pick = asset }
                            .assetAccessibility(asset)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { assets = (try? await library.client.albumAssets(album.id)) ?? [] }
        .fullScreenCover(item: $pick) { a in
            ViewerScreen(library: library, assets: assets, start: a,
                         onRemoved: { id in assets.removeAll { $0.id == id } })
        }
    }
}
