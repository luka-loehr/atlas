import SwiftUI
import UIKit

struct PhotosScreen: View {
    var library: Library
    @State private var showSettings = false
    @State private var selection = Selection()
    @State private var shareBundle: ShareBundle?
    @State private var confirmDelete = false
    @State private var trashOne: Asset?
    @State private var busy = false
    @State private var changeFailed = false
    @State private var albumAdd: AlbumAdd?
    @State private var shareLink: ShareLinkItem?

    /// Asset-Position oben im Bild (nil = ganz unten): benennt den Monat
    /// unter dem Titel und setzt den Griff des Schnellscrollers.
    @State private var topPosition: Int?
    /// The photos on screen, first and last: the date range under the title.
    @State private var visible: (Int, Int)?
    /// The scroll indicator shows while the grid moves and a moment after.
    @State private var scrolling = false
    @State private var hideIndicator: Task<Void, Never>?
    @State private var gridProxy = PhotoGridProxy()

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                if library.assets.isEmpty {
                    emptyState
                } else {
                    grid
                }
                if busy {
                    ProgressView()
                        .padding(20)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            // Photos' header: the large title on the row of the buttons, the
            // dates on screen under it, both over the photos
            .overlay(alignment: .topLeading) {
                if !library.assets.isEmpty { header }
            }
            .toolbar {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                if selection.active {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("More", systemImage: "ellipsis") {
                            Button(allSelected ? "Deselect All" : "Select All",
                                   systemImage: allSelected ? "circle" : "checkmark.circle") {
                                if allSelected { selection.clear() }
                                else { selection.selectAll(library.assets.map(\.id)) }
                            }
                            Section {
                                Button("Add to Album", systemImage: "rectangle.stack.badge.plus") {
                                    albumAdd = AlbumAdd(ids: Array(selection.ids))
                                }
                                if library.sharing {
                                    Button("Share as Link…", systemImage: "link") { shareLink = linkItem(Array(selection.ids)) }
                                }
                                Button("Favorite", systemImage: "heart") {
                                    run(hides: false) { ids in
                                        try await library.client.favorite(ids, true)
                                        library.setFavorite(Set(ids), true)
                                    }
                                }
                                Button("Archive", systemImage: "archivebox") {
                                    run { try await library.client.archive($0, true) }
                                }
                                Button("Lock", systemImage: "lock") {
                                    run { try await library.client.lock($0, true) }
                                }
                            }
                            .disabled(selection.isEmpty)
                        }
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done", systemImage: "xmark") {
                            withAnimation(.snappy(duration: 0.4)) { selection.exit() }
                        }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button("Share", systemImage: "square.and.arrow.up") { share(Array(selection.ids)) }
                            .disabled(selection.isEmpty)
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button("Delete", systemImage: "trash") { confirmDelete = true }
                            .disabled(selection.isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Select") { withAnimation(.snappy) { selection.enter() } }
                    }
                }
            }
            .toolbar(selection.active ? .hidden : .visible, for: .tabBar)
        }
        .sheet(isPresented: $showSettings) {
            SettingsScreen(library: library)
        }
        #if targetEnvironment(simulator)
        // ATLAS_SETTINGS=1 opens a simulator with the settings sheet up
        .task { if ProcessInfo.processInfo.environment["ATLAS_SETTINGS"] != nil { showSettings = true } }
        // ATLAS_SHARE_DEMO=1 (or uploading|ready|failed) opens it with the share link sheet up
        .task { if ProcessInfo.processInfo.environment["ATLAS_SHARE_DEMO"] != nil { shareLink = ShareLinkItem(title: "Lake Weekend") } }
        #endif
        .sheet(item: $shareBundle) { bundle in
            ShareSheet(items: bundle.urls).presentationDetents([.medium, .large])
        }
        .sheet(item: $albumAdd) { add in
            AddToAlbumSheet(library: library, ids: add.ids) { _ in
                if selection.active { withAnimation(.snappy(duration: 0.4)) { selection.exit() } }
            }
        }
        .sheet(item: $shareLink) { item in
            ShareLinkSheet(library: library, item: item) {
                if selection.active { withAnimation(.snappy(duration: 0.4)) { selection.exit() } }
            }
        }
        .confirmationDialog(selection.count == 1 ? "Delete 1 Item?" : "Delete \(selection.count) Items?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { run { try await library.client.trash($0) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete Photo?",
                            isPresented: Binding(get: { trashOne != nil }, set: { if !$0 { trashOne = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let a = trashOne else { return }
                runOne(a) { try await library.client.trash([$0]) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .changeFailedAlert($changeFailed)
    }

    private var title: String {
        switch selection.count {
        case 0: "Select Items"
        case 1: "1 Item Selected"
        default: "\(selection.count) Items Selected"
        }
    }
    /// The selection only ever holds ids of the timeline, so counting is enough.
    private var allSelected: Bool { !library.assets.isEmpty && selection.count == library.assets.count }

    private var header: some View {
        VStack(alignment: .leading, spacing: -2) {
            Text("Library")
                .font(.largeTitle.bold())
            Text(subtitle)
                .font(.headline)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.25), radius: 6)
        .padding(.leading, 16)
        .padding(.top, Self.windowTop + 1)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Height of the status bar area of the window.
    private static var windowTop: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets.top ?? 62
    }

    /// Die Tage auf dem Bildschirm, wie in Fotos: „26.–28. Sept. 2026“.
    private var subtitle: String {
        guard let (lo, hi) = visible, hi < library.assets.count,
              let from = library.assets[lo].takenAt ?? library.assets[hi].takenAt,
              let to = library.assets[hi].takenAt else {
            return library.assets.isEmpty ? "" : "\(library.assets.count.formatted()) Items"
        }
        if Calendar.current.isDate(from, inSameDayAs: to) { return Self.day.string(from: to) }
        return Self.range.string(from: min(from, to), to: max(from, to))
    }

    private static let range: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateTemplate = "dMMMyyyy"
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        return f
    }()

    /// The timeline as one grid, oldest first, opened at its newest (bottom)
    /// end — like Apple Photos, without day headers. A UICollectionView (see
    /// `PhotoGrid`): recycled cells, thumbnails decoded off the main thread.
    private var grid: some View {
        ZStack {
            PhotoGrid(library: library, assets: library.assets, revision: library.revision,
                      selecting: selection.active, selected: selection.ids, proxy: gridProxy,
                      onTop: { topPosition = $0 },
                      onRange: { visible = ($0, $1) },
                      onScrolling: { moving in
                          hideIndicator?.cancel()
                          if moving {
                              withAnimation(.easeOut(duration: 0.15)) { scrolling = true }
                          } else {
                              hideIndicator = Task {
                                  try? await Task.sleep(for: .seconds(1.2))
                                  guard !Task.isCancelled else { return }
                                  withAnimation(.easeOut(duration: 0.3)) { scrolling = false }
                              }
                          }
                      },
                      onToggle: { asset in withAnimation(.snappy(duration: 0.26, extraBounce: 0.05)) { selection.toggle(asset.id) } },
                      menu: { menu(for: $0) },
                      onRefresh: { await library.refresh() })
                .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            if !selection.active, library.months.count > 1 {
                TimeScrubber(months: library.months, total: library.assets.count,
                             current: topPosition ?? max(library.assets.count - 1, 0),
                             visible: scrolling,
                             onJump: { gridProxy.jump(to: $0.first) })
            }
        }

    }

    /// Long press on a photo: the system context menu with a large preview.
    private func menu(for asset: Asset) -> UIMenu {
        // Share from this menu should not wait: the original and its people
        // are fetched while the menu is open
        if let o = library.client.originalURL(asset.id) {
            _ = MediaFetch.shared.ensure(.init(.original, asset.id), from: o, priority: .visible)
        }
        ShareFiles.prepare(asset, client: library.client)
        // the timeline's own copy: the viewer may have changed it since
        let fav = library.position(of: asset.id).map { library.assets[$0].isFavorite } ?? asset.isFavorite
        let first = UIMenu(options: .displayInline, children: [
            UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in share([asset.id]) },
            UIAction(title: fav ? "Unfavorite" : "Favorite", image: UIImage(systemName: fav ? "heart.slash" : "heart")) { _ in
                Task {
                    do {
                        try await library.client.favorite([asset.id], !fav)
                        library.setFavorite([asset.id], !fav)
                    } catch {
                        changeFailed = true
                    }
                }
            },
            UIAction(title: "Select", image: UIImage(systemName: "checkmark.circle")) { _ in
                withAnimation(.snappy) { selection.enter(with: asset.id) }
            },
        ])
        var albumActions = [
            UIAction(title: "Add to Album", image: UIImage(systemName: "rectangle.stack.badge.plus")) { _ in
                albumAdd = AlbumAdd(ids: [asset.id])
            },
        ]
        if library.sharing {
            albumActions.append(UIAction(title: "Share as Link…", image: UIImage(systemName: "link")) { _ in
                shareLink = ShareLinkItem(title: ShareLinkItem.title(for: [asset]), ids: [asset.id])
            })
        }
        let album = UIMenu(options: .displayInline, children: albumActions)
        let second = UIMenu(options: .displayInline, children: [
            UIAction(title: "Archive", image: UIImage(systemName: "archivebox")) { _ in
                runOne(asset) { try await library.client.archive([$0], true) }
            },
            UIAction(title: "Lock", image: UIImage(systemName: "lock")) { _ in
                runOne(asset) { try await library.client.lock([$0], true) }
            },
        ])
        let trash = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
            trashOne = asset
        }
        return UIMenu(children: [first, album, second, trash])
    }

    // MARK: - actions

    /// Run a server mutation on the current selection. `hides` = the affected
    /// assets leave the main timeline (archive/lock/trash) → drop them locally.
    private func run(hides: Bool = true, _ op: @escaping ([String]) async throws -> Void) {
        let ids = Array(selection.ids)
        guard !ids.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await op(ids)
                if hides {
                    withAnimation(.snappy) { library.removeLocally(Set(ids)) }
                }
            } catch {
                changeFailed = true
            }
            withAnimation(.snappy(duration: 0.4)) { selection.exit() }
        }
    }

    /// The same for one photo (context menu); it leaves the timeline.
    private func runOne(_ asset: Asset, _ op: @escaping (String) async throws -> Void) {
        Task {
            do {
                try await op(asset.id)
                withAnimation(.snappy) { library.removeLocally([asset.id]) }
            } catch {
                changeFailed = true
            }
        }
    }

    /// The selected photos for a share link, named after their days.
    private func linkItem(_ ids: [String]) -> ShareLinkItem {
        let assets = ids.compactMap { library.position(of: $0).map { library.assets[$0] } }
        return ShareLinkItem(title: ShareLinkItem.title(for: assets), ids: ids)
    }

    private func share(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let assets = ids.map { id in
            library.position(of: id).map { library.assets[$0] }
                ?? Asset(id: id, type: "photo", takenAt: nil, width: nil, height: nil, durationS: nil)
        }
        Task {
            defer { busy = false }
            // the cached originals when there are; the spinner only when
            // something has to come from the server
            let urls = await ShareFiles.files(for: assets, client: library.client) { busy = true }
            if !urls.isEmpty { shareBundle = ShareBundle(urls: urls) }
            if selection.active { withAnimation(.snappy(duration: 0.4)) { selection.exit() } }
        }
    }

    private var emptyState: some View {
        Group {
            if !library.online {
                ServerUnavailableView()
            } else if library.loaded {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle.angled")
            } else {
                ProgressView()
            }
        }
    }
}
