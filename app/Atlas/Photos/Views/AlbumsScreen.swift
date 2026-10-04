import SwiftUI

/// The Albums tab, laid out like the Albums tab of Apple's Photos: the
/// albums as a carousel of large covers, the people as round faces, then
/// media types and utilities as plain lists with counts.
struct AlbumsScreen: View {
    var library: Library
    /// An album to open, from a link (atlas://album/<id>, the widget).
    @Binding var link: Int?

    @State private var albums: [Album] = AlbumsMemo.albums
    @State private var loaded = !AlbumsMemo.albums.isEmpty
    @State private var people: [Person] = PeopleMemo.people
    @State private var counts: [SpecialKind: Int] = [:]
    @State private var countsAt = Date.distantPast
    @State private var openAlbum: Album?
    @State private var openSpecial: SpecialKind?
    @State private var authing = false
    @State private var naming = false
    @State private var renaming: Album?
    @State private var deleting: Album?
    @State private var changeFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    albumsSection
                    peopleSection
                    listSection("Media Types", [.favorites, .videos])
                    listSection("Utilities", [.archive, .locked, .trash])
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Color(.systemBackground))
            .refreshable { await load(); await loadCounts() }
            .navigationTitle("Albums")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Album", systemImage: "plus") { naming = true }
                }
            }
            .navigationDestination(item: $openAlbum) { album in
                AlbumScreen(library: library, album: album)
            }
            .navigationDestination(item: $openSpecial) { kind in
                SpecialCollectionScreen(library: library, kind: kind)
            }
        }
        // once per launch, not on every tab switch; pull to refresh reloads
        .task { if AlbumsMemo.fetchedAt == nil { await load() } }
        .task {
            guard let fresh = try? await library.client.persons() else { return }
            if fresh != people { people = fresh }
            PeopleMemo.people = fresh
        }
        // counts change behind this screen (deleting, archiving, recovering):
        // read again on return, at most every half minute
        .onAppear {
            guard Date().timeIntervalSince(countsAt) > 30 else { return }
            Task { await loadCounts() }
        }
        .onChange(of: link, initial: true) { _, id in
            guard let id else { return }
            Task { await follow(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .atlasAlbumsChanged)) { _ in
            Task { await load() }
        }
        .albumNameAlert("New Album", isPresented: $naming) { title in
            Task {
                do {
                    let album = try await library.client.createAlbum(title)
                    await load()
                    openSpecial = nil
                    openAlbum = albums.first { $0.id == album.id } ?? album
                } catch {
                    changeFailed = true
                }
            }
        }
        .albumNameAlert("Rename Album", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                        initial: renaming?.title ?? "") { title in
            guard let album = renaming, title != album.title else { return }
            change { try await library.client.renameAlbum(album.id, to: title) }
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Album", role: .destructive) {
                guard let album = deleting else { return }
                change { try await library.client.deleteAlbum(album.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photos stay in your library.")
        }
        .changeFailedAlert($changeFailed)
    }

    /// An album change from this screen; the list is read again after it.
    private func change(_ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                await load()
            } catch {
                changeFailed = true
            }
        }
    }

    /// Long press on an album: rename or delete it.
    @ViewBuilder
    private func albumMenu(_ album: Album) -> some View {
        Button("Rename", systemImage: "pencil") { renaming = album }
        Button("Delete Album", systemImage: "trash", role: .destructive) { deleting = album }
    }

    // MARK: - Albums

    private var userAlbums: [Album] {
        // Takeout's "Trash" and "Locked Folder" rows show as utilities instead
        albums.filter { !SpecialAlbum.isLocked($0.title) && !SpecialAlbum.isTrash($0.title) }
    }

    @ViewBuilder
    private var albumsSection: some View {
        let list = userAlbums
        SectionHeader(title: "My Albums") {
            if list.count > 2 {
                NavigationLink("See All") { AllAlbumsScreen(library: library, albums: list) }
            }
        }
        if list.isEmpty {
            if loaded {
                Text("Tap + to make an album.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            } else {
                AlbumCarousel(library: library, albums: [], placeholders: 4) { _ in }
            }
        } else {
            AlbumCarousel(library: library, albums: list, menu: { AnyView(albumMenu($0)) }) { openAlbum = $0 }
        }
    }

    // MARK: - People

    @ViewBuilder
    private var peopleSection: some View {
        if !people.isEmpty {
            SectionHeader(title: "People") {
                NavigationLink("See All") { PersonsScreen(library: library) }
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(people.prefix(20)) { person in
                        NavigationLink {
                            PersonDetailScreen(library: library, person: person)
                        } label: {
                            VStack(spacing: 8) {
                                FaceCircle(library: library, person: person)
                                    .frame(width: 84, height: 84)
                                Text(person.displayName)
                                    .font(.footnote)
                                    .foregroundStyle(person.name == nil ? .secondary : .primary)
                                    .lineLimit(1)
                                    .frame(width: 88)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(person.displayName)
                        .accessibilityValue("\(person.photos) \(person.photos == 1 ? "photo" : "photos")")
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Media types and utilities

    @ViewBuilder
    private func listSection(_ title: String, _ kinds: [SpecialKind]) -> some View {
        SectionHeader(title: title) { EmptyView() }
        VStack(spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.element) { i, kind in
                CollectionRow(kind: kind, count: counts[kind]) { open(kind) }
                if i < kinds.count - 1 {
                    Divider().padding(.leading, 60)
                }
            }
        }
        .disabled(authing)
    }

    private func open(_ kind: SpecialKind) {
        guard kind == .locked else { openSpecial = kind; return }
        authing = true
        Task {
            let ok = await Biometric.authenticate(reason: "Unlock the Locked album")
            authing = false
            if ok { openSpecial = .locked }
        }
    }

    // MARK: - Data

    private func load() async {
        // a failed reload keeps what is shown; an unchanged list is not reassigned
        if let fresh = try? await library.client.albums() {
            if fresh != albums { albums = fresh }
            AlbumsMemo.albums = fresh
            AlbumsMemo.fetchedAt = Date()
        }
        loaded = true
    }

    /// How many items each list row holds. The Locked album shows none
    /// until it is unlocked.
    private func loadCounts() async {
        countsAt = Date()
        let client = library.client
        async let favorites = client.collection("/library/favorites")
        async let videos = client.collection("/library/videos")
        async let archive = client.listArchive()
        async let trash = client.listTrash()
        let fresh: [SpecialKind: Int?] = [.favorites: (try? await favorites)?.count,
                                          .videos: (try? await videos)?.count,
                                          .archive: (try? await archive)?.count,
                                          .trash: (try? await trash)?.count]
        for (kind, n) in fresh { if let n, counts[kind] != n { counts[kind] = n } }
    }

    /// Opens the album a link names, once the list knows it.
    private func follow(_ id: Int) async {
        link = nil
        if !albums.contains(where: { $0.id == id }) { await load() }
        guard let album = albums.first(where: { $0.id == id }) else { return }
        openSpecial = nil
        openAlbum = album
    }
}

/// The album list as last fetched, so the tab opens complete and refreshes
/// behind it.
@MainActor
enum AlbumsMemo {
    static var albums: [Album] = []
    static var fetchedAt: Date?
}

/// A section title in the Photos style: bold, with an optional "See All".
private struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
                .font(.body)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }
}

/// Albums side by side, two rows when there are enough of them, scrolling
/// sideways a column at a time; the next column peeks in at the edge.
private struct AlbumCarousel: View {
    var library: Library
    var albums: [Album]
    var placeholders = 0
    var menu: ((Album) -> AnyView)? = nil
    var open: (Album) -> Void

    private var rows: Int { albums.count > 4 || placeholders > 2 ? 2 : 1 }

    var body: some View {
        let count = albums.isEmpty ? placeholders : albums.count
        let columns = stride(from: 0, to: count, by: rows).map { $0..<min($0 + rows, count) }
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(columns, id: \.lowerBound) { range in
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(range, id: \.self) { i in
                            if let album = albums[safe: i] {
                                Button { open(album) } label: { AlbumTile(library: library, album: album) }
                                    .buttonStyle(.plain)
                                    .contextMenu { menu?(album) }
                            } else {
                                AlbumTile.placeholder
                            }
                        }
                    }
                    // two full columns and a peek of the third
                    .containerRelativeFrame(.horizontal) { width, _ in
                        max(120, (width - 40 - 14 * 2) / 2.18)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .padding(.bottom, 8)
    }
}

/// One album: a large rounded square cover, the title and the count.
struct AlbumTile: View {
    var library: Library
    var album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { CoverImage(library: library, id: album.cover) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(album.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.top, 7)
            Text(album.count, format: .number)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(album.title)
        .accessibilityValue("\(album.count) \(album.count == 1 ? "item" : "items")")
        .accessibilityAddTraits(.isButton)
    }

    static var placeholder: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemFill))
                .aspectRatio(1, contentMode: .fit)
            Text("Album").font(.subheadline).padding(.top, 7)
            Text("00").font(.subheadline)
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

/// An album cover: the grid thumbnail at once (it is on the phone), then
/// the sharp preview decoded at the size the cover is shown.
private struct CoverImage: View {
    var library: Library
    var id: String?
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geo in
            let px = (max(geo.size.width, geo.size.height) * scale * 1.5).rounded(.up)
            ZStack {
                Rectangle().fill(Color(.secondarySystemFill))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if id == nil {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: "\(id ?? "")@\(Int(px))") { await load(px) }
        }
        .accessibilityHidden(true)
    }

    private func load(_ px: CGFloat) async {
        guard let id, px > 0,
              let small = library.client.thumbURL(id, 512),
              let big = library.client.thumbURL(id, 2048) else { return }
        let cache = MediaCache.shared
        if let sharp = cache.cached(big, maxPixel: px) { image = sharp; return }
        if image == nil {
            image = cache.cached(small)
            if image == nil { image = await cache.load(small) }
        }
        if let sharp = await cache.load(big, maxPixel: px) { image = sharp }
    }
}

/// A row of Media Types or Utilities: symbol, title, count, chevron.
private struct CollectionRow: View {
    let kind: SpecialKind
    let count: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: kind.icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(kind.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if kind == .locked {
                    Image(systemName: "faceid")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                } else if let count {
                    Text(count, format: .number)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.forward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .accessibilityValue(kind == .locked ? "Locked" : count.map { "\($0) \($0 == 1 ? "item" : "items")" } ?? "")
    }
}

/// The grey highlight a list row shows while pressed.
private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemFill) : .clear)
    }
}

/// Every album as a two-column grid ("See All").
struct AllAlbumsScreen: View {
    var library: Library
    var albums: [Album]
    @State private var open: Album?

    private let cols = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, alignment: .leading, spacing: 20) {
                ForEach(albums) { album in
                    Button { open = album } label: { AlbumTile(library: library, album: album) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("My Albums")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $open) { album in
            AlbumScreen(library: library, album: album)
        }
    }
}

// MARK: - Special collections

enum SpecialKind: String, Identifiable, Hashable {
    case favorites, videos, locked, archive, trash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: return "Favorites"
        case .videos:    return "Videos"
        case .locked:    return "Locked"
        case .archive:   return "Archive"
        case .trash:     return "Recently Deleted"
        }
    }
    var icon: String {
        switch self {
        case .favorites: return "heart"
        case .videos:    return "video"
        case .locked:    return "lock"
        case .archive:   return "archivebox"
        case .trash:     return "trash"
        }
    }
}

/// A collection of the Media Types or Utilities lists, with the actions
/// that fit it in a selection toolbar.
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

/// One album's photos, with adding, removing, renaming and deleting.
struct AlbumScreen: View {
    var library: Library
    var album: Album
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var assets: [Asset] = []
    @State private var loaded = false
    @State private var pick: Asset?
    @State private var selection = Selection()
    @State private var picking = false
    @State private var renaming = false
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var changeFailed = false
    @State private var shareLink: ShareLinkItem?
    @Namespace private var zoom
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

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
                .selectionToolbar(selection, actions: [
                    .init(title: "Remove from Album", icon: "minus.circle", role: .destructive) { removeSelected() },
                ])
            }
            if busy {
                ProgressView().padding(20)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle(title.isEmpty ? album.title : title)
        .navigationSubtitle(loaded ? (assets.count == 1 ? "1 Item" : "\(assets.count.formatted()) Items")
                                   : (album.count == 1 ? "1 Item" : "\(album.count.formatted()) Items"))
        .navigationBarTitleDisplayMode(.inline)
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
        .fullScreenCover(item: $pick) { a in
            ViewerScreen(library: library, assets: assets, start: a,
                         onRemoved: { id in assets.removeAll { $0.id == id } })
                .navigationTransition(.zoom(sourceID: a.id, in: zoom))
        }
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
