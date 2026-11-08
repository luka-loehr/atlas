import SwiftUI
import AppKit

/// A set of photos as a grid, and the viewer over it: the library, an
/// album, a person, a special collection. It owns the selection and offers
/// what can be done with it in four places that always agree: the menu
/// bar's Image menu, the toolbar, the context menu and the keyboard.
struct MacPhotoBrowser: View {
    let source: PhotoSource
    /// Search results come with their photos.
    var given: [Asset]? = nil
    /// Floats over the top of the grid, under the toolbar (how a search was
    /// read), as on the iPhone: the photos scroll on beneath it.
    var header: AnyView? = nil

    @Environment(AppModel.self) private var model
    @Environment(MacWindowState.self) private var window

    @State private var assets: [Asset] = []
    @State private var revision = 0
    @State private var loaded = false
    @State private var selection: Set<String> = []
    /// The photo the viewer shows; nil while the grid is up.
    @State private var viewing: String?
    @State private var reveal: String?
    /// The month at the top of the grid, for the subtitle. Set only when
    /// it changes, so scrolling does not re-render the window per row.
    @State private var topMonth: String?
    /// The days on screen, as the iPhone's Library header names them
    /// ("26–28 Sept 2026"). Set only when it changes.
    @State private var visibleDays: String?
    @State private var busy = false
    @State private var changeFailed = false
    @State private var deleting: [String]?
    @State private var emptyingTrash = false
    @State private var albumAdd: AlbumAdd?
    @State private var shareLink: ShareLinkItem?
    @State private var renamingAlbum = false
    @State private var deletingAlbum = false
    @State private var albumTitle: String?
    @State private var unlocked = false

    private var library: Library { model.library }
    private var client: PhotoClient { library.client }

    var body: some View {
        content
            // the Library draws its own title over the photos, as on the iPhone
            .navigationTitle(ownTitle ? "" : title)
            .navigationSubtitle(ownTitle ? "" : subtitle)
            .toolbar { toolbar }
            .inspector(isPresented: Bindable(window).showInspector) {
                inspector.inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            .focusedSceneValue(\.photoActions, gated ? nil : actions(for: targetIDs))
            .task(id: source) { await load() }
            .onChange(of: library.revision) { if source == .library { syncInspector() } }
            .onChange(of: selection) { syncInspector() }
            .onChange(of: viewing) { syncInspector() }
            .onReceive(NotificationCenter.default.publisher(for: .atlasRelock)) { _ in
                if source == .special(.locked) { unlocked = false; viewing = nil }
            }
            .onReceive(NotificationCenter.default.publisher(for: .atlasAlbumsChanged)) { _ in
                Task { await model.loadAlbums(); if case .album = source { await load() } }
            }
            .sheet(item: $albumAdd) { add in
                AddToAlbumSheet(library: library, ids: add.ids) { _ in
                    Task { await model.loadAlbums() }
                }
                .frame(minWidth: 380, idealWidth: 420, minHeight: 420, idealHeight: 520)
            }
            .sheet(item: $shareLink) { item in
                ShareLinkSheet(library: library, item: item)
                    .formStyle(.grouped)
                    .frame(minWidth: 420, idealWidth: 460, minHeight: 380, idealHeight: 480)
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button(isTrash ? "Delete Permanently" : "Delete", role: .destructive) {
                    if let ids = deleting { delete(ids) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(isTrash ? "This can’t be undone."
                     : "\((deleting?.count ?? 0) == 1 ? "It stays" : "They stay") in Recently Deleted for 30 days.")
            }
            .confirmationDialog("Delete All Items in Recently Deleted?", isPresented: $emptyingTrash, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    run(reload: true) { try await client.emptyTrash() }
                }
            } message: {
                Text("All \(assets.count.formatted()) items will be deleted permanently. This can’t be undone.")
            }
            .albumNameAlert("Rename Album", isPresented: $renamingAlbum, initial: albumName) { name in
                guard case .album(let album) = source, !name.isEmpty else { return }
                run(reload: false) {
                    try await client.renameAlbum(album.id, to: name)
                    albumTitle = name
                    NotificationCenter.default.post(name: .atlasAlbumsChanged, object: nil)
                }
            }
            .confirmationDialog("Delete Album “\(albumName)”?", isPresented: $deletingAlbum, titleVisibility: .visible) {
                Button("Delete Album", role: .destructive) { deleteAlbum() }
            } message: {
                Text("The photos stay in your library.")
            }
            .changeFailedAlert($changeFailed)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if gated {
            ContentUnavailableView {
                Label("Locked", systemImage: "lock.fill")
            } description: {
                Text("Unlock with Touch ID or your password to see these photos.")
            } actions: {
                Button("Unlock") { Task { await unlock() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .task { await unlock() }
        } else {
            photos.overlay(alignment: .topLeading) {
                // a search's pills take the title's place, top left
                if let header, viewing == nil {
                    header
                        .padding(.top, selection.isEmpty ? 0 : 52)
                        .padding(.leading, window.topLeadingClearance)
                        .padding(.trailing, 440)
                        .ignoresSafeArea(edges: .top)
                }
            }
            .overlay(alignment: .topLeading) {
                if libraryHeader { libraryTitle }
            }
        }
    }

    /// The grid, or the viewer over it.
    private var photos: some View {
        ZStack {
            if shown.isEmpty {
                if loaded || (source == .library && library.loaded) {
                    PhotoSourceEmpty(source: source, online: library.online)
                } else {
                    ProgressView()
                }
            } else {
                MacPhotoGrid(assets: shown, revision: shownRevision, cellSize: GridZoom.sizes[window.zoom],
                             // every grid reads like the library: oldest at the top,
                             // opened at the newest end
                             selection: $selection, startAtEnd: true, reveal: reveal,
                             onOpen: { open($0) },
                             menu: { contextMenu($0) },
                             onTopIndex: { i in
                                 guard source == .library else { return }
                                 let label = library.month(at: i)?.label
                                 if label != topMonth { topMonth = label }
                             },
                             onVisible: { lo, hi in
                                 guard source == .library else { return }
                                 let days = Self.days(library.assets, lo, hi)
                                 if days != visibleDays { visibleDays = days }
                             },
                             onFavoriteKey: { actions(for: targetIDs).toggleFavorite?() },
                             onZoom: { step in withAnimation(.snappy) { step > 0 ? window.zoomIn() : window.zoomOut() } })
                    // up to the window's top edge, under the floating toolbar
                    .ignoresSafeArea(edges: .top)
                    .opacity(viewing == nil ? 1 : 0)
                    .allowsHitTesting(viewing == nil)
                    .accessibilityHidden(viewing != nil)
            }
            if let viewing {
                MacViewer(library: library, assets: shown, current: Binding(get: { viewing }, set: { self.viewing = $0 }),
                          onClose: closeViewer,
                          onFavorite: { actions(for: [viewing]).toggleFavorite?() })
                    .transition(.opacity)
            }
            if busy { BusyOverlay() }
        }
        .animation(.easeOut(duration: 0.18), value: viewing)
    }

    @ViewBuilder
    private var inspector: some View {
        if let asset = window.inspected {
            InfoSheet(library: library, asset: asset)
                .environment(\.openPerson, OpenPersonAction { person in window.open(person) })
        } else {
            ContentUnavailableView(selection.count > 1 ? "\(selection.count.formatted()) Items Selected" : "No Selection",
                                   systemImage: "info.circle",
                                   description: Text(selection.count > 1 ? "" : "Select a photo to see where and how it was taken."))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // whose photos these are: their face and name in a pill of its own
        // beside the back button, like a search's pills
        if case .person(let person) = source, viewing == nil, selection.isEmpty {
            ToolbarSpacer(.fixed, placement: .navigation)
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 7) {
                    FaceCircle(library: library, person: person)
                        .frame(width: 26, height: 26)
                    Text(person.displayName)
                        .font(.headline)
                        .lineLimit(1)
                }
                .padding(.leading, 4)
                .padding(.trailing, 12)
                .frame(minHeight: 34)
                // its own glass, not the back button's: a pill like a search's
                .glassEffect(.regular, in: .capsule)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(person.displayName)
                .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        if viewing != nil {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") { closeViewer() }
                    .help("Back to \(source == .library ? "Library" : title)")
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        if !gated {
            let a = actions(for: targetIDs)
            ToolbarItemGroup(placement: .primaryAction) {
                if case .album = source, viewing == nil {
                    Menu("Album", systemImage: "ellipsis.circle") {
                        if library.sharing {
                            Button("Share Album as Link…", systemImage: "link") { shareAlbum() }
                        }
                        Button("Rename Album…", systemImage: "pencil") { renamingAlbum = true }
                        Divider()
                        Button("Delete Album…", systemImage: "trash", role: .destructive) { deletingAlbum = true }
                    }
                    .help("Album")
                }
                if source == .special(.trash), viewing == nil {
                    Button("Delete All…") { emptyingTrash = true }
                        .disabled(assets.isEmpty)
                }
                if let restore = a.restore {
                    Button(restore.title, systemImage: "arrow.uturn.backward") { restore.run() }
                        .help(restore.title)
                        .disabled(targetIDs.isEmpty)
                }
                if a.toggleFavorite != nil || targetIDs.isEmpty {
                    Button(a.allFavorite ? "Unfavorite" : "Favorite", systemImage: a.allFavorite ? "heart.fill" : "heart") {
                        a.toggleFavorite?()
                    }
                    .help(a.allFavorite ? "Unfavorite" : "Favorite")
                    .disabled(a.toggleFavorite == nil)
                }
                Button("Share", systemImage: "square.and.arrow.up") { a.share?() }
                    .help("Share")
                    .disabled(a.share == nil)
                Button("Delete", systemImage: "trash") { a.delete?() }
                    .help(isTrash ? "Delete Permanently" : "Delete")
                    .disabled(a.delete == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Info", systemImage: "info.circle") { window.showInspector.toggle() }
                    .help(window.showInspector ? "Hide Info" : "Show Info")
            }
        }
    }

    // MARK: - What is shown

    private var shown: [Asset] { source == .library ? library.assets : assets }
    private var shownRevision: Int { source == .library ? library.revision : revision }
    private var isTrash: Bool { source == .special(.trash) }
    private var gated: Bool { source == .special(.locked) && !unlocked }

    /// What the commands act on: the photo in the viewer, else the
    /// selection, in timeline order.
    private var targetIDs: [String] {
        if let viewing { return [viewing] }
        return lookup(selection).map(\.id)
    }

    /// The assets of `ids` in the order shown, without walking the whole
    /// library: the library answers positions from its index.
    private func lookup<S: Sequence>(_ ids: S) -> [Asset] where S.Element == String {
        if source == .library {
            return ids.compactMap { library.position(of: $0) }.sorted().compactMap { library.assets[safe: $0] }
        }
        let set = Set(ids)
        return set.isEmpty ? [] : assets.filter { set.contains($0.id) }
    }

    private var viewed: Asset? { viewing.flatMap { lookup([$0]).first } }

    private var albumName: String {
        if let albumTitle { return albumTitle }
        if case .album(let album) = source { return album.title }
        return ""
    }

    private var title: String {
        if let asset = viewed {
            return asset.takenAt?.formatted(date: .long, time: .omitted) ?? "No Date"
        }
        switch source {
        case .library: return "Library"
        case .special(let kind): return kind.title
        case .album: return albumName
        case .person(let person): return person.displayName
        case .search(let q): return "“\(q)”"
        }
    }

    private var subtitle: String {
        if let asset = viewed {
            return asset.takenAt?.formatted(date: .omitted, time: .shortened) ?? ""
        }
        if !selection.isEmpty { return "\(selection.count.formatted()) of \(countText) Selected" }
        if source == .library, let topMonth { return topMonth }
        if isTrash, !assets.isEmpty { return "\(countText) · Deleted permanently after 30 days" }
        return shown.isEmpty ? "" : countText
    }

    /// The Library's header is drawn over the photos while the grid shows
    /// and nothing is selected (a selection keeps its count in the title).
    private var libraryHeader: Bool { source == .library && viewing == nil && selection.isEmpty }

    /// The window title gives way to the Library's header or a search's pills.
    private var ownTitle: Bool {
        guard viewing == nil, selection.isEmpty else { return false }
        if case .person = source { return true }
        return libraryHeader || header != nil
    }

    /// As the iPhone's Library: a large white title and the days on screen,
    /// with a soft shadow, at the top left over the photos.
    private var libraryTitle: some View {
        VStack(alignment: .leading, spacing: -2) {
            Text("Library")
                .font(.system(size: 30, weight: .bold))
            Text(visibleDays ?? countText)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 6)
        .padding(.leading, 20 + window.topLeadingClearance)
        .padding(.top, 6)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The days from the first to the last photo on screen: "26–28 Sept 2026".
    private static func days(_ assets: [Asset], _ lo: Int, _ hi: Int) -> String? {
        guard lo <= hi, hi < assets.count,
              let from = assets[lo].takenAt ?? assets[hi].takenAt,
              let to = assets[hi].takenAt else { return nil }
        return DayRange.text(from, to)
    }

    private var countText: String {
        let n = shown.count
        return n == 1 ? "1 Item" : "\(n.formatted()) Items"
    }

    private func syncInspector() {
        let id = viewing ?? (selection.count == 1 ? selection.first : nil)
        let asset = id.flatMap { lookup([$0]).first }
        if window.inspected != asset { window.inspected = asset }
    }

    // MARK: - Loading

    private func load() async {
        if let given {
            assets = given.timelineOrdered()
            revision &+= 1
            loaded = true
            return
        }
        do {
            let fresh: [Asset]
            switch source {
            case .library:
                loaded = true
                return
            case .special(.favorites): fresh = try await client.collection("/library/favorites")
            case .special(.videos): fresh = try await client.collection("/library/videos")
            case .special(.archive): fresh = try await client.listArchive()
            case .special(.locked): fresh = try await client.listLocked()
            case .special(.trash): fresh = try await client.listTrash()
            case .album(let album): fresh = try await client.albumAssets(album.id)
            case .person(let person): fresh = try await client.personAssets(person.id)
            case .search: fresh = []
            }
            let ordered = fresh.timelineOrdered()
            if ordered != assets {
                assets = ordered
                revision &+= 1
                selection.formIntersection(Set(ordered.map(\.id)))
            }
        } catch {}
        loaded = true
    }

    private func unlock() async {
        guard !unlocked else { return }
        unlocked = await Biometric.authenticate(reason: "show your Locked photos")
        if unlocked { await load() }
    }

    // MARK: - Viewer

    private func open(_ asset: Asset) {
        reveal = nil
        viewing = asset.id
        if window.showInspector { window.inspected = asset }
    }

    private func closeViewer() {
        guard let id = viewing else { return }
        viewing = nil
        MediaCache.shared.viewerClosed()
        selection = [id]
        reveal = id
    }

    // MARK: - Actions

    /// Everything that can be done with `ids` here, for the menu bar, the
    /// toolbar, the context menu and the keyboard.
    private func actions(for ids: [String]) -> PhotoActions {
        let set = Set(ids)
        let items = lookup(ids)
        let allFavorite = !items.isEmpty && items.allSatisfy(\.isFavorite)
        var a = PhotoActions(count: ids.count, allFavorite: allFavorite)
        guard !ids.isEmpty else { return a }
        if viewing == nil { a.open = { if let first = items.first { open(first) } } }
        let kind: SpecialKind? = if case .special(let k) = source { k } else { nil }
        let inTrash = kind == .trash
        if !inTrash && kind != .locked {
            a.toggleFavorite = {
                let value = !allFavorite
                run(removes: kind == .favorites && !value ? ids : []) {
                    try await client.favorite(ids, value)
                    library.setFavorite(set, value)
                    if source != .library { markFavorite(set, value) }
                }
            }
            a.addToAlbum = { albumAdd = AlbumAdd(ids: ids) }
            if library.sharing {
                a.shareLink = { shareLink = ShareLinkItem(title: ShareLinkItem.title(for: items), ids: ids) }
            }
            a.share = { MacShare.share(items, client: client) { busy = $0 } }
            a.export = { MacShare.export(items, client: client) { busy = $0 } }
        }
        if case .album(let album) = source {
            a.removeFromAlbum = {
                run(removes: ids) {
                    try await client.removeFromAlbum(album.id, ids)
                    NotificationCenter.default.post(name: .atlasAlbumsChanged, object: nil)
                }
            }
        }
        switch kind {
        case .archive:
            a.restore = ("Unarchive", { run(removes: ids, refreshLibrary: true) { try await client.archive(ids, false) } })
        case .locked:
            a.restore = ("Unlock", { run(removes: ids, refreshLibrary: true) { try await client.lock(ids, false) } })
        case .trash:
            a.restore = ("Recover", { run(removes: ids, refreshLibrary: true) { try await client.restore(ids) } })
        default:
            a.archive = {
                run(removes: ids) {
                    try await client.archive(ids, true)
                    library.removeLocally(set)
                }
            }
            a.lock = {
                run(removes: ids) {
                    try await client.lock(ids, true)
                    library.removeLocally(set)
                }
            }
        }
        if kind != .locked { a.delete = { deleting = ids } }
        return a
    }

    private func contextMenu(_ ids: Set<String>) -> NSMenu? {
        let ordered = lookup(ids).map(\.id)
        let a = actions(for: ordered)
        var items: [NSMenuItem] = []
        if let open = a.open, ordered.count == 1 { items.append(BlockMenuItem("Open", open)) }
        items.append(.separator())
        if let fav = a.toggleFavorite {
            items.append(BlockMenuItem(a.allFavorite ? "Unfavorite" : "Favorite", symbol: a.allFavorite ? "heart.slash" : "heart", fav))
        }
        if a.addToAlbum != nil {
            let addItem = NSMenuItem(title: "Add to Album", action: nil, keyEquivalent: "")
            addItem.image = NSImage(systemSymbolName: "rectangle.stack.badge.plus", accessibilityDescription: nil)
            var albumItems: [NSMenuItem] = [BlockMenuItem("New Album…") { albumAdd = AlbumAdd(ids: ordered) }, .separator()]
            for album in model.userAlbums {
                albumItems.append(BlockMenuItem(album.title) { add(ordered, to: album) })
            }
            addItem.submenu = NSMenu(items: albumItems)
            items.append(addItem)
        }
        if let remove = a.removeFromAlbum { items.append(BlockMenuItem("Remove from Album", symbol: "rectangle.stack.badge.minus", remove)) }
        items.append(.separator())
        if let share = a.share { items.append(BlockMenuItem("Share…", symbol: "square.and.arrow.up", share)) }
        if let link = a.shareLink { items.append(BlockMenuItem("Share as Link…", symbol: "link", link)) }
        if let export = a.export {
            items.append(BlockMenuItem(ordered.count == 1 ? "Export Original…" : "Export \(ordered.count.formatted()) Originals…",
                                       symbol: "square.and.arrow.down", export))
        }
        items.append(.separator())
        if let restore = a.restore { items.append(BlockMenuItem(restore.title, symbol: "arrow.uturn.backward", restore.run)) }
        if let archive = a.archive { items.append(BlockMenuItem("Archive", symbol: "archivebox", archive)) }
        if let lock = a.lock { items.append(BlockMenuItem("Lock", symbol: "lock", lock)) }
        items.append(.separator())
        if let delete = a.delete { items.append(BlockMenuItem(isTrash ? "Delete Permanently…" : "Delete…", symbol: "trash", destructive: true, delete)) }
        return NSMenu(items: items)
    }

    private var deleteTitle: String {
        let n = deleting?.count ?? 0
        let what = n == 1 ? "1 Item" : "\(n.formatted()) Items"
        return isTrash ? "Delete \(what) Permanently?" : "Delete \(what)?"
    }

    private func delete(_ ids: [String]) {
        let set = Set(ids)
        if isTrash {
            run(removes: ids) { try await client.deletePermanent(ids) }
        } else {
            run(removes: ids) {
                try await client.trash(ids)
                library.removeLocally(set)
            }
        }
    }

    private func add(_ ids: [String], to album: Album) {
        run {
            try await client.addToAlbum(album.id, ids)
            Haptics.success()
            NotificationCenter.default.post(name: .atlasAlbumsChanged, object: nil)
        }
    }

    private func shareAlbum() {
        guard case .album(let album) = source else { return }
        shareLink = ShareLinkItem(title: albumName, album: album.id)
    }

    private func deleteAlbum() {
        guard case .album(let album) = source else { return }
        run {
            try await client.deleteAlbum(album.id)
            await model.loadAlbums()
            window.sidebar = .library
        }
    }

    private func markFavorite(_ ids: Set<String>, _ value: Bool) {
        var next = assets
        for i in next.indices where ids.contains(next[i].id) { next[i].favorite = value }
        assets = next
        revision &+= 1
    }

    /// Runs a change on the server; what left this collection leaves the
    /// grid (and the viewer moves on to the next photo).
    private func run(removes: [String] = [], refreshLibrary: Bool = false, reload: Bool = false,
                     _ op: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await op()
                if !removes.isEmpty { removeShown(Set(removes)) }
                if reload { await load() }
                if refreshLibrary { await library.refresh() }
            } catch {
                changeFailed = true
            }
        }
    }

    private func removeShown(_ ids: Set<String>) {
        let list = shown
        if let viewing, ids.contains(viewing) {
            // on to the next photo, as Photos does; the grid when none is left
            let i = list.firstIndex { $0.id == viewing } ?? 0
            let rest = list.filter { !ids.contains($0.id) }
            self.viewing = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id
        }
        selection.subtract(ids)
        if source != .library {
            assets.removeAll { ids.contains($0.id) }
            revision &+= 1
        }
    }
}
