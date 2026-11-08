import SwiftUI
import UIKit

/// Full-screen viewer, Google-Photos style.
///
/// Two modes, toggled by tapping the photo:
///   • CHROME    — system background; top bar (round back button, pill
///                 with relative date + time, ⋯ menu), bottom filmstrip of
///                 neighbors and the action bar (share ○ | ♥ ⓘ ⧉ pill | 🗑 ○).
///   • IMMERSIVE — pure black, nothing but the image.
///
/// Paging is a UIPageViewController (PhotoPager): one swipe = exactly one
/// photo, it can never rest between two pages. Swipe-down still dismisses via
/// the zoom transition.
struct ViewerScreen: View {
    var library: Library
    var assets: [Asset]
    var start: Asset
    /// Set when the viewer is presented from UIKit (the photo grid), which
    /// dismisses it itself; else the SwiftUI presentation is dismissed.
    var onClose: (() -> Void)? = nil
    /// The photo now shown, for the zoom transition back into the grid.
    var onPage: ((Asset) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
    @State private var pages: [Asset] = []
    @State private var index: Int = 0
    @State private var chrome = true
    @State private var infoAsset: Asset?
    @State private var shareBundle: ShareBundle?
    @State private var confirmTrash = false
    @State private var favorites: [String: Bool] = [:]   // optimistic overrides
    @State private var busy = false
    @State private var changeFailed = false
    @State private var albumAdd: AlbumAdd?
    @State private var shareLink: ShareLinkItem?
    // measured height of the bottom chrome stack (filmstrip + action bar) —
    // video controls anchor EXACTLY above it, overlap is structurally impossible
    @State private var chromeBottomHeight: CGFloat = 150
    /// The pager's position frame by frame, for the filmstrip and the tick.
    @State private var motion = PageMotion()

    var body: some View {
        ZStack {
            (chrome ? Color(uiColor: .systemBackground) : .black)
                .ignoresSafeArea()

            if !pages.isEmpty {
                PhotoPager(index: $index, count: pages.count, motion: motion) { i in
                    ViewerPage(library: library, asset: pages[i], chrome: chrome,
                               bottomInset: chromeBottomHeight + 20) {
                        // NO withAnimation: chrome pops in/out instantly, both ways
                        chrome.toggle()
                    }
                }
                .ignoresSafeArea()
            }

            if chrome, let asset = pages[safe: index] {
                chromeOverlay(asset)
            }

            if busy {
                ProgressView().tint(chrome ? nil : Color.white).padding(18)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
        }
        .statusBarHidden(!chrome)
        .preferredColorScheme(chrome ? nil : .dark)
        .onAppear {
            Orientation.viewer(true)
            // no audio session here: a photo never interrupts the owner's music
            pages = assets
            index = assets.firstIndex(of: start) ?? 0
            ViewerNow.show(pages[safe: index]?.id)
            MediaCache.shared.viewerFocus(pages, index: index, forward: true)
            if let a = pages[safe: index] { ShareFiles.prepare(a, client: library.client) }
        }
        .onChange(of: index) { old, new in focus(new, forward: new >= old) }
        // the tick when a swipe crosses halfway comes from `motion`, with or
        // without the chrome; the filmstrip ticks for its own scrubbing
        .onDisappear {
            Orientation.viewer(false)
            ViewerNow.show(nil)
            MediaCache.shared.viewerClosed()
            // music a video interrupted (Spotify ...) carries on
            PlaybackAudio.deactivate()
        }
        .sheet(item: $infoAsset) { a in
            InfoSheet(library: library, asset: a)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $shareBundle) { b in
            ShareSheet(items: b.urls).presentationDetents([.medium, .large])
        }
        .sheet(item: $albumAdd) { add in
            AddToAlbumSheet(library: library, ids: add.ids)
        }
        .sheet(item: $shareLink) { item in
            ShareLinkSheet(library: library, item: item)
        }
        .changeFailedAlert($changeFailed)
    }

    /// The page at `i` is the one on screen now.
    private func focus(_ i: Int, forward: Bool) {
        MediaCache.shared.viewerFocus(pages, index: i, forward: forward)
        ViewerNow.show(pages[safe: i]?.id)
        if let a = pages[safe: i] {
            onPage?(a)
            ShareFiles.prepare(a, client: library.client)
        }
    }

    // MARK: - Chrome (Google-Photos layout)

    @ViewBuilder
    private func chromeOverlay(_ asset: Asset) -> some View {
        let screenHeight = ScreenSize.bounds.height
        VStack(spacing: 0) {
            topBar(asset)
            Spacer()
            VStack(spacing: 19) {
                FilmstripView(assets: pages, index: $index, motion: motion)
                    .frame(height: FilmstripView.height)
                bottomBar(asset)
            }
            .padding(.bottom, -6)
            .onGeometryChange(for: CGFloat.self, of: {
                // distance from the stack's TOP edge to the PHYSICAL screen
                // bottom — pages ignore safe areas, so measure in global space
                screenHeight - $0.frame(in: .global).minY
            }) { chromeBottomHeight = $0 }
        }
    }

    private func topBar(_ asset: Asset) -> some View {
        HStack(alignment: .center) {
            CircleButton(icon: "chevron.backward", label: "Back") { close() }
            Spacer(minLength: 8)
            let place = placeTitle(asset)
            VStack(spacing: 0) {
                Text(place ?? relativeDay(asset.takenAt))
                    .font(.headline)
                if let t = asset.takenAt {
                    Text(place != nil
                         ? "\(relativeDay(t))  \(t.formatted(date: .omitted, time: .shortened))"
                         : t.formatted(date: .omitted, time: .shortened))
                        .font(.footnote)
                }
            }
            // a new photo changes the words, never the pill: no fade, no morph
            .transaction { $0.animation = nil }
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityElement(children: .combine)
            .padding(.horizontal, 24)
            .frame(minWidth: 158, minHeight: 44)
            .glassEffect(.regular, in: .capsule)      // iOS 26 Liquid Glass
            Spacer(minLength: 8)
            .task(id: asset.id) { await loadPlaces(around: asset) }
            Menu {
                Button { albumAdd = AlbumAdd(ids: [asset.id]) } label: {
                    Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                }
                if library.sharing {
                    Button { shareLink = ShareLinkItem(title: ShareLinkItem.title(for: [asset]), ids: [asset.id]) } label: {
                        Label("Share as Link…", systemImage: "link")
                    }
                }
                Button {
                    mutateAndRemove { try await library.client.archive([$0], true) }
                } label: { Label("Archive", systemImage: "archivebox") }
                Button {
                    mutateAndRemove { try await library.client.lock([$0], true) }
                } label: { Label("Lock", systemImage: "lock") }
                Button { infoAsset = asset } label: {
                    Label("Details", systemImage: "info.circle")
                }
            } label: {
                CircleButton(icon: "ellipsis", label: "More") {}.allowsHitTesting(false)
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 16)
    }

    private func bottomBar(_ asset: Asset) -> some View {
        HStack {
            CircleButton(icon: "square.and.arrow.up", label: "Share", nudge: -1.5, size: 48) { shareCurrent() }
            Spacer()
            // 44-pt hit areas; spacing and padding shrink by the same amount,
            // so the glyphs sit exactly where they did with the bare icons
            HStack(spacing: 10) {
                Button { toggleFavorite(asset) } label: {
                    barIcon(isFav(asset) ? "heart.fill" : "heart")
                        .foregroundStyle(isFav(asset) ? .red : .primary)
                }
                .accessibilityLabel(isFav(asset) ? "Unfavorite" : "Favorite")
                Button { infoAsset = asset } label: {
                    barIcon("info.circle").foregroundStyle(.primary)
                }
                .accessibilityLabel("Details")
                Button {
                    mutateAndRemove { try await library.client.archive([$0], true) }
                } label: {
                    barIcon("archivebox").foregroundStyle(.primary)
                }
                .accessibilityLabel("Archive")
            }
            .padding(.horizontal, 3)
            .frame(height: 48)
            .glassEffect(.regular, in: .capsule)      // iOS 26 Liquid Glass
            Spacer()
            CircleButton(icon: "trash", label: "Delete", size: 48) { confirmTrash = true }
                .confirmationDialog("Delete Photo?", isPresented: $confirmTrash,
                                    titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { trashCurrent() }
                }
        }
        .padding(.horizontal, 28)
    }

    private func barIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func isFav(_ a: Asset) -> Bool { favorites[a.id] ?? a.isFavorite }

    private func toggleFavorite(_ a: Asset) {
        let new = !isFav(a)
        favorites[a.id] = new                       // optimistic
        Task {
            do {
                try await library.client.favorite([a.id], new)
                library.setFavorite([a.id], new)
            } catch {
                favorites[a.id] = !new
                changeFailed = true
            }
        }
    }

    private func shareCurrent() {
        guard let a = pages[safe: index] else { return }
        Task {
            defer { busy = false }
            // the original the viewer fetched when the page appeared; the
            // spinner only when it is not on the phone yet
            let files = await ShareFiles.files(for: [a], client: library.client) { busy = true }
            if !files.isEmpty { shareBundle = ShareBundle(urls: files) }
        }
    }

    private func trashCurrent() {
        mutateAndRemove { try await library.client.trash([$0]) }
    }

    /// Run a single-asset mutation, drop the asset from the pager + grid, and
    /// advance to the next photo (dismiss when it was the last one).
    private func mutateAndRemove(_ op: @escaping (String) async throws -> Void) {
        guard let a = pages[safe: index] else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await op(a.id) } catch { changeFailed = true; return }
            library.removeLocally([a.id])
            // the page may have moved on while the server answered
            guard let at = pages.firstIndex(where: { $0.id == a.id }) else { return }
            if pages.count <= 1 {
                close()
            } else {
                var next = pages
                next.remove(at: at)
                let newIndex = min(at < index ? index - 1 : index, next.count - 1)
                pages = next
                if newIndex != index { index = newIndex }
                // same index, another photo: `onChange(of: index)` stays quiet
                focus(newIndex, forward: true)
            }
        }
    }

    /// Where each photo was taken, as the title of the top pill (like
    /// Photos). `noPlace` holds photos known to have none.
    @State private var places: [String: String] = [:]
    @State private var noPlace: Set<String> = []
    /// The place last shown: kept while the next photo's place is still on its
    /// way, so swiping between photos of one town never flickers.
    @State private var lastPlace: String?

    private func placeTitle(_ a: Asset) -> String? {
        if let p = places[a.id] { return p }
        if noPlace.contains(a.id) { return nil }
        return lastPlace
    }

    /// The photo's place, and its neighbours' ahead of the next swipe.
    private func loadPlaces(around a: Asset) async {
        if let p = places[a.id] { lastPlace = p } else if noPlace.contains(a.id) { lastPlace = nil }
        guard let i = pages.firstIndex(of: a) else { return }
        let ids = ([i] + (1...3).flatMap { [i + $0, i - $0] }).compactMap { pages[safe: $0]?.id }
            .filter { places[$0] == nil && !noPlace.contains($0) }
        let client = library.client
        await withTaskGroup(of: (String, String?, Bool).self) { group in
            for id in ids {
                group.addTask {
                    guard let info = try? await client.assetInfo(id) else { return (id, nil, false) }
                    // the locality, like Photos ("Munich"), not the state after it
                    return (id, info.place.map { $0.components(separatedBy: ", ").first ?? $0 }, true)
                }
            }
            for await (id, place, answered) in group {
                guard answered else { continue }
                if let place { places[id] = place } else { noPlace.insert(id) }
                if id == a.id { lastPlace = place }
            }
        }
    }

    private func relativeDay(_ d: Date?) -> String {
        guard let d else { return "—" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f: DateFormatter
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day,
           days < 7 {
            f = Self.weekday
        } else {
            f = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? Self.dayThisYear : Self.dayOtherYear
        }
        return f.string(from: d)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = format; return f
    }
    private static let weekday = formatter("EEEE")
    private static let dayThisYear = formatter("d MMMM")
    private static let dayOtherYear = formatter("d MMMM yyyy")
}
