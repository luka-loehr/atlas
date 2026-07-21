import SwiftUI
import UIKit

struct PhotosScreen: View {
    var library: Library
    @State private var showAccount = false
    @State private var pick: Asset?
    @State private var selection = Selection()
    @State private var shareBundle: ShareBundle?
    @State private var confirmDelete = false
    @State private var busy = false
    @State private var lastViewedId: String?   // zoom-return cell stays on top
    @Namespace private var zoom

    /// Apple-Fotos-Raster-Zoom: Pinch schaltet durch die Spaltenstufen.
    /// Persistiert, damit die App mit der zuletzt gewählten Dichte startet.
    private static let zoomLevels = [1, 3, 5, 9]
    @AppStorage("photos.gridColumns") private var gridColumns = 3
    /// Kumulierter Pinch-Faktor seit dem letzten Stufenwechsel — erlaubt
    /// mehrere Stufen in EINER durchgehenden Pinch-Bewegung.
    @State private var pinchBase: CGFloat = 1
    /// Id der obersten sichtbaren Tages-Sektion — koppelt Scroll-Position und
    /// den Jahr/Monat-Schnellscroller (TimeScrubber) bidirektional.
    @State private var scrolledSectionID: String?

    private var cols: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: gridColumns)
    }

    /// Eine Zoom-Stufe weiter (in = Zellen größer = weniger Spalten).
    private func stepZoom(in zoomIn: Bool) {
        let levels = Self.zoomLevels
        guard let i = levels.firstIndex(of: gridColumns) else { gridColumns = 3; return }
        let next = zoomIn ? i - 1 : i + 1
        guard levels.indices.contains(next) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.32)) { gridColumns = levels[next] }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                if library.sections.isEmpty {
                    emptyState
                } else {
                    grid
                }
                if busy {
                    ProgressView()
                        .padding(20)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .navigationTitle(selection.active ? title : "Atlas")
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
                ToolbarItem(placement: .topBarTrailing) {
                    if selection.active {
                        Button("Fertig") { withAnimation(.snappy(duration: 0.4)) { selection.exit() } }
                    } else {
                        // Auswahl startet wie bei Apple per Long-Press auf ein
                        // Bild — oben rechts bleibt nur das Konto. Der „Atlas"-
                        // Titel steht als großer Titel oben links über dem Raster.
                        Button { showAccount = true } label: {
                            Image(systemName: "person.crop.circle").font(.system(size: 22))
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
        .confirmationDialog("\(selection.count) Objekte in den Papierkorb?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("In Papierkorb", role: .destructive) { run { try await library.client.trash($0) } }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private var title: String {
        selection.isEmpty ? "Objekte auswählen" : "\(selection.count) ausgewählt"
    }
    private var allSelected: Bool { selection.allSelected(of: library.assets.map(\.id)) }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(library.sections) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.date.sectionTitle())
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LazyVGrid(columns: cols, spacing: 2) {
                            ForEach(section.assets) { asset in
                                SelectableThumb(asset: asset,
                                                thumbURL: library.client.thumbURL(asset.id, gridColumns == 1 ? 2048 : 512),
                                                selection: selection, namespace: zoom) { pick = asset }
                                    .task {
                                        await library.loadMoreIfNeeded(current: asset)
                                        library.prefetch(around: asset)
                                    }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .id(section.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $scrolledSectionID, anchor: .top)
        .overlay(alignment: .trailing) {
            if !selection.active, library.sections.count > 12 {
                TimeScrubber(sections: library.sections, scrolledID: $scrolledSectionID)
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
            onShare:    { shareSelected() },
            onFavorite: { run(hides: false) { try await library.client.favorite($0, true) } },
            onArchive:  { run { try await library.client.archive($0, true) } },
            onLock:     { run { try await library.client.lock($0, true) } },
            onTrash:    { confirmDelete = true })
    }

    // MARK: - batch actions

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

    private func shareSelected() {
        let ids = Array(selection.ids)
        guard !ids.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            var urls: [URL] = []
            for id in ids {
                guard let src = library.client.originalURL(id) else { continue }
                if let (tmp, resp) = try? await URLSession.shared.download(from: src) {
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
            withAnimation(.snappy(duration: 0.4)) { selection.exit() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if library.online {
                ProgressView()
                Text("lade Bibliothek …")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("atlas nicht erreichbar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("im Tailnet? atlas wach?")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}


/// Google-Fotos-Schnellscroller am rechten Rand: ein Griff, den man vertikal
/// zieht, um blitzschnell zu einem Jahr/Monat zu springen. Während des Ziehens
/// erscheinen Jahres-Marken entlang der Bahn und eine große Monats/Jahr-Blase,
/// dazu ein haptischer Tick bei jedem Monatswechsel.
///
/// Bidirektional über `scrolledID` (an ScrollView.scrollPosition gebunden):
/// scrollt der Nutzer normal, wandert der Griff mit; zieht er den Griff, scrollt
/// das Raster.
struct TimeScrubber: View {
    let sections: [Library.DaySection]
    @Binding var scrolledID: String?

    @State private var dragging = false
    @State private var dragFrac: CGFloat = 0
    @State private var lastMonthKey = ""

    private let space = "scrubTrack"

    private var count: Int { sections.count }

    private var currentIndex: Int {
        guard let id = scrolledID,
              let i = sections.firstIndex(where: { $0.id == id }) else { return 0 }
        return i
    }

    /// Jahr → Anteil (0…1) der obersten (neuesten) Sektion dieses Jahres.
    private var yearMarks: [(year: Int, frac: CGFloat)] {
        guard count > 1 else { return [] }
        let cal = Calendar.current
        var seen = Set<Int>()
        var out: [(Int, CGFloat)] = []
        for (i, s) in sections.enumerated() {
            let y = cal.component(.year, from: s.date)
            if seen.insert(y).inserted {
                out.append((y, CGFloat(i) / CGFloat(count - 1)))
            }
        }
        return out.map { (year: $0.0, frac: $0.1) }
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let frac = dragging
                ? dragFrac
                : (count > 1 ? CGFloat(currentIndex) / CGFloat(count - 1) : 0)
            let handleY = clamp(frac * h, 22, h - 22)

            ZStack(alignment: .topTrailing) {
                if dragging {
                    ForEach(yearMarks, id: \.year) { m in
                        Text(String(m.year))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                            .position(x: geo.size.width - 34, y: clamp(m.frac * h, 12, h - 12))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                    Text(monthLabel(at: targetIndex(dragFrac)))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                        .position(x: geo.size.width - 118, y: handleY)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
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
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
            .scaleEffect(dragging ? 1.12 : 1)
            .animation(.snappy(duration: 0.2), value: dragging)
            .contentShape(Rectangle().inset(by: -12))
    }

    private func drag(h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { v in
                if !dragging {
                    withAnimation(.snappy(duration: 0.2)) { dragging = true }
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
                let f = clamp(v.location.y / h, 0, 1)
                dragFrac = f
                let idx = targetIndex(f)
                let id = sections[idx].id
                if id != scrolledID { scrolledID = id }
                let mk = monthKey(at: idx)
                if mk != lastMonthKey {
                    lastMonthKey = mk
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.25)) { dragging = false }
            }
    }

    private func targetIndex(_ frac: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        return clamp(Int((frac * CGFloat(count - 1)).rounded()), 0, count - 1)
    }

    private func monthLabel(at i: Int) -> String {
        guard sections.indices.contains(i) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "MMM yyyy"
        return f.string(from: sections[i].date)
    }

    private func monthKey(at i: Int) -> String {
        guard sections.indices.contains(i) else { return "" }
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month], from: sections[i].date)
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }

    private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
        min(max(v, lo), hi)
    }
}
