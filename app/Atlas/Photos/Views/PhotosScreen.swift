import SwiftUI
import UIKit

struct PhotosScreen: View {
    var library: Library
    @State private var showSettings = false
    @State private var selection = Selection()
    @State private var shareBundle: ShareBundle?
    @State private var confirmDelete = false
    @State private var trashOne: Asset?
    @State private var favorites: [String: Bool] = [:]   // optimistic overrides
    @State private var busy = false

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
                                Button("Favorite", systemImage: "heart") {
                                    run(hides: false) { try await library.client.favorite($0, true) }
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
        #endif
        .sheet(item: $shareBundle) { bundle in
            ShareSheet(items: bundle.urls).presentationDetents([.medium, .large])
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
                             onJump: { gridProxy.jump(to: $0.first) },
                             onScrubbing: { library.scrubbing = $0 })
            }
        }

    }

    /// Long press on a photo: the system context menu with a large preview.
    private func menu(for asset: Asset) -> UIMenu {
        let fav = favorites[asset.id] ?? asset.isFavorite
        let first = UIMenu(options: .displayInline, children: [
            UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in share([asset.id]) },
            UIAction(title: fav ? "Unfavorite" : "Favorite", image: UIImage(systemName: fav ? "heart.slash" : "heart")) { _ in
                favorites[asset.id] = !fav
                Task { try? await library.client.favorite([asset.id], !fav) }
            },
            UIAction(title: "Select", image: UIImage(systemName: "checkmark.circle")) { _ in
                withAnimation(.snappy) { selection.enter(with: asset.id) }
            },
        ])
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
        return UIMenu(children: [first, second, trash])
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
                await library.loadStats()
            } catch {}
            withAnimation(.snappy(duration: 0.4)) { selection.exit() }
        }
    }

    /// The same for one photo (context menu); it leaves the timeline.
    private func runOne(_ asset: Asset, _ op: @escaping (String) async throws -> Void) {
        Task {
            do {
                try await op(asset.id)
                withAnimation(.snappy) { library.removeLocally([asset.id]) }
                await library.loadStats()
            } catch {}
        }
    }

    private func share(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            var urls: [URL] = []
            for id in ids {
                guard let src = library.client.originalURL(id) else { continue }
                // the cached original when there is one
                if let file = await MediaCache.shared.shareableOriginal(id, from: src) { urls.append(file) }
            }
            if !urls.isEmpty { shareBundle = ShareBundle(urls: urls) }
            if selection.active { withAnimation(.snappy(duration: 0.4)) { selection.exit() } }
        }
    }

    private var emptyState: some View {
        Group {
            if library.online {
                ProgressView()
            } else {
                ServerUnavailableView()
            }
        }
    }
}

/// The large preview of the context menu: the cached grid thumbnail at once,
/// the sharp 2048 version over it as soon as it is there.
struct ContextPreview: View {
    let asset: Asset
    let client: PhotoClient
    @State private var sharp: UIImage?

    private var size: CGSize { Self.size(for: asset) }

    static func size(for asset: Asset) -> CGSize {
        let ratio = CGFloat(asset.width ?? 1) / CGFloat(max(asset.height ?? 1, 1))
        let maxW: CGFloat = 360, maxH: CGFloat = 480
        return ratio >= maxW / maxH ? CGSize(width: maxW, height: maxW / ratio)
                                    : CGSize(width: maxH * ratio, height: maxH)
    }

    var body: some View {
        ZStack {
            Thumb(url: client.thumbURL(asset.id, 512))
            if let sharp {
                Image(uiImage: sharp).resizable().scaledToFill()
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task {
            guard let url = client.thumbURL(asset.id, 2048) else { return }
            sharp = await MediaCache.shared.loadFull(url, maxPixel: 1400)
        }
    }
}

/// Schnellscroller am rechten Rand: Griff ziehen, Monat und Jahre erscheinen,
/// beim Loslassen steht das Raster dort. Alle Werte kommen vorberechnet aus
/// `Library.months`, im Drag-Pfad wird nur binär gesucht.
struct TimeScrubber: View {
    let months: [Library.Month]
    let total: Int
    /// Asset position at the top of the screen.
    let current: Int
    /// The grid is moving: show the slim indicator. At rest nothing shows;
    /// grabbing the indicator turns it into the full scrubber.
    var visible = false
    var onJump: (Library.Month) -> Void
    var onScrubbing: (Bool) -> Void = { _ in }

    @State private var dragging = false
    @State private var dragFrac: CGFloat = 0
    @State private var lastMonth = ""

    private let space = "scrubTrack"

    private func frac(_ position: Int) -> CGFloat { CGFloat(position) / CGFloat(max(total - 1, 1)) }

    private var yearMarks: [(year: Int, frac: CGFloat)] {
        var seen = Set<Int>()
        return months.compactMap { m in
            seen.insert(m.year).inserted && m.year > 0 ? (m.year, frac(m.first)) : nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let f = dragging ? dragFrac : frac(current)
            let handleY = clamp(f * h, 22, h - 22)
            ZStack(alignment: .topTrailing) {
                if dragging {
                    ForEach(yearMarks, id: \.year) { m in
                        Text(String(m.year))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .glassEffect(.regular, in: .capsule)
                            .position(x: geo.size.width - 34, y: clamp(m.frac * h, 12, h - 12))
                            .allowsHitTesting(false)
                    }
                    Text(month(at: dragFrac).label)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .glassEffect(.regular, in: .capsule)
                        .position(x: geo.size.width - 118, y: handleY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                handle
                    .position(x: geo.size.width - 20, y: handleY)
                    .gesture(drag(h: h))
                    .opacity(dragging || visible ? 1 : 0)
                    .allowsHitTesting(dragging || visible)
            }
            .coordinateSpace(.named(space))
            .frame(width: geo.size.width, height: h)
        }
        .frame(width: 150)
        .frame(maxHeight: .infinity)
    }

    /// A standard slim scroll indicator; while dragged, the big handle.
    @ViewBuilder private var handle: some View {
        ZStack {
            if dragging {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 46)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .transition(.scale(scale: 0.3, anchor: .trailing).combined(with: .opacity))
            } else {
                Capsule()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 40)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 2)
                    .transition(.opacity)
            }
        }
        .frame(width: 36, height: 46)
        .animation(.snappy(duration: 0.2), value: dragging)
        .contentShape(Rectangle().inset(by: -12))
    }

    private func drag(h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { v in
                if !dragging {
                    withAnimation(.snappy(duration: 0.2)) { dragging = true }
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    onScrubbing(true)
                }
                dragFrac = clamp(v.location.y / h, 0, 1)
                let m = month(at: dragFrac)
                if m.key != lastMonth {
                    lastMonth = m.key
                    UISelectionFeedbackGenerator().selectionChanged()
                    onJump(m)
                }
            }
            .onEnded { _ in
                onScrubbing(false)
                withAnimation(.easeOut(duration: 0.25)) { dragging = false }
            }
    }

    /// The month at a fraction of the track (binary search over start positions).
    private func month(at f: CGFloat) -> Library.Month {
        let position = Int(f * CGFloat(max(total - 1, 0)))
        var lo = 0, hi = months.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if months[mid].first <= position { lo = mid } else { hi = mid - 1 }
        }
        return months[lo]
    }

    private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
}
