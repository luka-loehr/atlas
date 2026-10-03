import SwiftUI
import UIKit

struct PhotosScreen: View {
    var library: Library
    @State private var showAccount = false
    @State private var pick: Asset?
    @State private var selection = Selection()
    @State private var shareBundle: ShareBundle?
    @State private var confirmDelete = false
    @State private var trashOne: Asset?
    @State private var favorites: [String: Bool] = [:]   // optimistic overrides
    @State private var busy = false
    @Namespace private var zoom

    /// Apple-Fotos-Raster-Zoom: Pinch schaltet durch die Spaltenstufen.
    /// Persistiert, damit die App mit der zuletzt gewählten Dichte startet.
    private static let zoomLevels = [1, 3, 5, 9]
    @AppStorage("photos.gridColumns") private var gridColumns = 5
    /// Kumulierter Pinch-Faktor seit dem letzten Stufenwechsel — erlaubt
    /// mehrere Stufen in EINER durchgehenden Pinch-Bewegung.
    @State private var pinchBase: CGFloat = 1
    @State private var position = ScrollPosition()
    /// Sichtbarer Ausschnitt des Rasters in Zeilen (mit Vorlauf) — nur Zeilen
    /// in diesem Fenster existieren als Views.
    @State private var window = GridWindow()
    /// Asset-Position oben im Bild: hält die Stelle beim Zoomen und benennt
    /// den Monat unter dem Titel.
    @State private var topPosition: Int?

    /// Decode target for a grid cell: its pixel size (+ small headroom) so we
    /// never hold a full 512/2048 bitmap for a tiny cell — less decode, less RAM.
    private var cellMaxPixel: CGFloat {
        let w = UIScreen.main.bounds.width / CGFloat(max(gridColumns, 1))
        return w * UIScreen.main.scale * 1.15
    }

    /// Eine Zoom-Stufe weiter (in = Zellen größer = weniger Spalten).
    private func stepZoom(in zoomIn: Bool) {
        let levels = Self.zoomLevels
        guard let i = levels.firstIndex(of: gridColumns) else { gridColumns = 5; return }
        let next = zoomIn ? i - 1 : i + 1
        guard levels.indices.contains(next) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        gridColumns = levels[next]
    }

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
            .navigationTitle(selection.active ? title : "Fotos")
            .navigationSubtitle(selection.active ? "" : subtitle)
            .navigationBarTitleDisplayMode(selection.active ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selection.active {
                        Button(allSelected ? "Keine" : "Alle") {
                            withAnimation(.snappy) {
                                if allSelected { selection.clear() }
                                else { selection.selectAll(library.assets.map(\.id)) }
                            }
                        }
                    }
                }
                if selection.active {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Fertig") { withAnimation(.snappy(duration: 0.4)) { selection.exit() } }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Auswählen") { withAnimation(.snappy) { selection.enter() } }
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAccount = true } label: {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAccount) {
            AccountSheet(library: library)
        }
        .sheet(item: $shareBundle) { bundle in
            ShareSheet(items: bundle.urls).presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $pick) { asset in
            ViewerScreen(library: library, assets: library.assets, start: asset)
                .navigationTransition(.zoom(sourceID: asset.id, in: zoom))
        }
        .confirmationDialog("\(selection.count) Objekte löschen?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { run { try await library.client.trash($0) } }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Foto löschen?",
                            isPresented: Binding(get: { trashOne != nil }, set: { if !$0 { trashOne = nil } }),
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                guard let a = trashOne else { return }
                runOne(a) { try await library.client.trash([$0]) }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private var title: String {
        selection.isEmpty ? "Objekte auswählen" : "\(selection.count) ausgewählt"
    }
    private var allSelected: Bool { selection.allSelected(of: library.assets.map(\.id)) }

    /// Der Monat oben im Bild; ganz unten (dem Startpunkt) die Anzahl.
    private var subtitle: String {
        guard let top = topPosition, let month = library.month(at: top) else {
            return "\(library.assets.count.formatted()) Objekte"
        }
        return month.label
    }

    /// The timeline as one grid, oldest first, opened at its newest (bottom)
    /// end — like Apple Photos, without day headers.
    ///
    /// The geometry is plain arithmetic (rows × pitch), so the scroll view
    /// gets a spacer of the exact total height and only the rows inside the
    /// visible window exist as views. That is what lets it open at the bottom
    /// of 25,000 photos instantly and lets the scrubber jump anywhere in one
    /// step.
    private var grid: some View {
        GeometryReader { geo in
            let layout = GridLayout(count: library.assets.count, columns: gridColumns, width: geo.size.width)
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: geo.size.width, height: layout.total)
                    ForEach(window.rows(limit: layout.rows), id: \.self) { row in
                        rowView(row, layout: layout)
                            .offset(y: CGFloat(row) * layout.pitch)
                    }
                }
            }
            .scrollPosition($position)
            // the timeline runs oldest → newest: open at the newest end
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: GridWindow.self, of: { geometry in
                // one screen above and half a screen below, in whole rows:
                // thumbnails are on their way before a row scrolls in, and
                // the state only changes when a row boundary is crossed
                let pitch = max(layout.pitch, 1)
                let rect = geometry.visibleRect
                let atBottom = rect.maxY >= geometry.contentSize.height - pitch
                return GridWindow(low: Int(((rect.minY - rect.height) / pitch).rounded(.down)),
                                  high: Int(((rect.maxY + rect.height * 0.5) / pitch).rounded(.up)),
                                  top: Int((max(rect.minY + geo.safeAreaInsets.top, 0) / pitch).rounded(.down)),
                                  atBottom: atBottom)
            }) { _, new in
                window = new
                let top = min(new.top * layout.columns, max(library.assets.count - 1, 0))
                let next: Int? = new.atBottom ? nil : top
                if library.month(at: next ?? -1)?.key != library.month(at: topPosition ?? -1)?.key || (next == nil) != (topPosition == nil) {
                    topPosition = next
                }
                let rowsOnScreen = max(new.high - new.low, 1)
                library.prefetch(around: top, span: rowsOnScreen * layout.columns)
            }
            .onChange(of: gridColumns) { old, columns in
                // keep the photo at the top of the screen in place across densities
                guard let top = topPosition else { return }
                let next = GridLayout(count: library.assets.count, columns: columns, width: geo.size.width)
                position.scrollTo(y: CGFloat(top / max(columns, 1)) * next.pitch)
            }
            .overlay(alignment: .trailing) {
                if !selection.active, library.months.count > 1 {
                    TimeScrubber(months: library.months, total: library.assets.count,
                                 current: topPosition ?? max(library.assets.count - 1, 0),
                                 onJump: { month in
                                     let row = month.first / max(layout.columns, 1)
                                     position.scrollTo(y: min(CGFloat(row) * layout.pitch,
                                                              max(layout.total - geo.size.height * 0.6, 0)))
                                 },
                                 onScrubbing: { library.scrubbing = $0 })
                }
            }
            .scrollIndicators(.hidden)
            // Pinch-Zoom fürs Raster (wie Apple Fotos): simultaneousGesture, damit
            // Scrollen und Zell-Taps unangetastet bleiben. Stufen werden schon
            // WÄHREND der Geste geschaltet (Schwellen 1.25/0.8 relativ zur letzten
            // Stufe), sodass ein langer Pinch mehrere Stufen durchläuft.
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let ratio = value.magnification / pinchBase
                        if ratio > 1.25 {
                            pinchBase = value.magnification
                            stepZoom(in: true)
                        } else if ratio < 0.8 {
                            pinchBase = value.magnification
                            stepZoom(in: false)
                        }
                    }
                    .onEnded { _ in pinchBase = 1 }
            )
            .refreshable { await library.refresh() }
            .selectionToolbar(selection,
                onShare:    { share(Array(selection.ids)) },
                onFavorite: { run(hides: false) { try await library.client.favorite($0, true) } },
                onArchive:  { run { try await library.client.archive($0, true) } },
                onLock:     { run { try await library.client.lock($0, true) } },
                onTrash:    { confirmDelete = true })
        }
    }

    /// One row of the grid.
    private func rowView(_ row: Int, layout: GridLayout) -> some View {
        let lo = row * layout.columns
        let hi = min(lo + layout.columns, library.assets.count)
        return HStack(spacing: GridLayout.spacing) {
            ForEach(library.assets[lo..<hi]) { asset in
                SelectableThumb(asset: asset,
                                thumbURL: library.client.thumbURL(asset.id, gridColumns == 1 ? 2048 : 512),
                                maxPixel: cellMaxPixel,
                                selection: selection, namespace: zoom,
                                holdToSelect: false) { pick = asset }
                    .frame(width: layout.side, height: layout.side)
                    .contextMenu { menu(for: asset) } preview: { ContextPreview(asset: asset, client: library.client) }
            }
        }
        .frame(width: layout.width, alignment: .leading)
    }

    /// Long press on a photo: the system context menu with a large preview.
    @ViewBuilder
    private func menu(for asset: Asset) -> some View {
        let fav = favorites[asset.id] ?? asset.isFavorite
        Section {
            Button { share([asset.id]) } label: { Label("Teilen", systemImage: "square.and.arrow.up") }
            Button {
                favorites[asset.id] = !fav
                Task { try? await library.client.favorite([asset.id], !fav) }
            } label: {
                Label(fav ? "Kein Favorit" : "Favorit", systemImage: fav ? "heart.slash" : "heart")
            }
            Button {
                withAnimation(.snappy) { selection.enter(with: asset.id) }
            } label: { Label("Auswählen", systemImage: "checkmark.circle") }
        }
        Section {
            Button { runOne(asset) { try await library.client.archive([$0], true) } } label: {
                Label("Archivieren", systemImage: "archivebox")
            }
            Button { runOne(asset) { try await library.client.lock([$0], true) } } label: {
                Label("Ausblenden", systemImage: "eye.slash")
            }
        }
        Button(role: .destructive) { trashOne = asset } label: { Label("Löschen", systemImage: "trash") }
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
                if let (tmp, resp) = try? await URLSession.shared.download(for: AtlasAuth.request(src, timeoutInterval: 600)) {
                    let ext = (resp.suggestedFilename as NSString?)?.pathExtension.nilIfEmpty ?? "jpg"
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(id).\(ext)")
                    try? FileManager.default.removeItem(at: dest)
                    if (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil {
                        urls.append(dest)
                    }
                }
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
                ContentUnavailableView("atlas nicht erreichbar", systemImage: "moon.zzz.fill")
            }
        }
    }
}

/// The large preview of the context menu: the cached grid thumbnail at once,
/// the sharp 2048 version over it as soon as it is there.
private struct ContextPreview: View {
    let asset: Asset
    let client: PhotoClient
    @State private var sharp: UIImage?

    private var size: CGSize {
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
            sharp = await ThumbLoader.shared.loadFull(url, maxPixel: 1400)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Which rows of the grid exist as views, in whole rows.
struct GridWindow: Equatable {
    var low = 0
    var high = 0
    /// The row under the top edge of the screen.
    var top = 0
    var atBottom = true

    func rows(limit: Int) -> Range<Int> {
        let lo = max(low, 0), hi = min(high, limit)
        return lo..<max(hi, lo)
    }
}

/// Where every row of the grid sits, computed instead of measured.
struct GridLayout {
    static let spacing: CGFloat = 2

    let columns: Int
    let width: CGFloat
    let rows: Int
    /// Cells are square, 2pt apart, edge to edge.
    let side: CGFloat
    var pitch: CGFloat { side + Self.spacing }
    var total: CGFloat { max(CGFloat(rows) * pitch - Self.spacing, 0) }

    init(count: Int, columns: Int, width: CGFloat) {
        self.columns = max(columns, 1)
        self.width = width
        rows = (count + self.columns - 1) / self.columns
        side = max((width - Self.spacing * CGFloat(self.columns - 1)) / CGFloat(self.columns), 1)
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
            }
            .coordinateSpace(.named(space))
            .frame(width: geo.size.width, height: h)
        }
        .frame(width: 150)
        .frame(maxHeight: .infinity)
    }

    private var handle: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: 36, height: 46)
            .glassEffect(.regular.interactive(), in: .capsule)
            .scaleEffect(dragging ? 1.12 : 1)
            .animation(.snappy(duration: 0.2), value: dragging)
            .contentShape(Rectangle().inset(by: -12))
            .opacity(dragging ? 1 : 0.9)
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
