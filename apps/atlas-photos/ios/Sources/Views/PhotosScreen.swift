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
            if !selection.active, library.scale.count > 1 {
                TimeScrubber(scale: library.scale, sections: library.sections,
                             scrolledID: $scrolledSectionID)
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

/// Google-Fotos-Schnellscroller am rechten Rand mit STABILER, bildmengen-
/// proportionaler Skala: Grundlage ist `scale` (alle Monate + Anzahl, aus
/// /api/timeline/summary), nicht die geladenen Sektionen — dadurch verschiebt
/// sich nichts beim Nachladen, und ein Monat mit vielen Bildern bekommt
/// proportional mehr Platz auf der Bahn. Springen setzt `scrolledID` auf die
/// (im Hintergrund voll geladene) Tages-Sektion des Zielmonats.
struct TimeScrubber: View {
    let scale: [MonthBucket]
    let sections: [Library.DaySection]
    @Binding var scrolledID: String?

    @State private var dragging = false
    @State private var dragFrac: CGFloat = 0
    @State private var lastMonthKey = ""

    private let space = "scrubTrack"

    private struct Entry { let month: String; let year: Int; let date: Date; let start: CGFloat; let end: CGFloat }

    /// Kumulative Anteile pro Monat (neueste zuerst, oben = 0).
    private var entries: [Entry] {
        let total = max(scale.reduce(0) { $0 + $1.count }, 1)
        var acc = 0
        return scale.map { b in
            let start = CGFloat(acc) / CGFloat(total)
            acc += b.count
            let end = CGFloat(acc) / CGFloat(total)
            let (y, d) = Self.parse(b.month)
            return Entry(month: b.month, year: y, date: d, start: start, end: end)
        }
    }

    private var yearMarks: [(year: Int, frac: CGFloat)] {
        var seen = Set<Int>()
        var out: [(Int, CGFloat)] = []
        for e in entries where seen.insert(e.year).inserted { out.append((e.year, e.start)) }
        return out.map { (year: $0.0, frac: $0.1) }
    }

    /// Anteil der aktuell obersten Sektion (fein per Tag innerhalb des Monats).
    private var currentFrac: CGFloat {
        guard let id = scrolledID,
              let sec = sections.first(where: { $0.id == id }),
              let e = entries.first(where: { $0.month == Self.monthKey(sec.date) }) else { return 0 }
        let cal = Calendar.current
        let day = cal.component(.day, from: sec.date)
        let dim = cal.range(of: .day, in: .month, for: sec.date)?.count ?? 30
        let dayFrac = CGFloat(day - 1) / CGFloat(max(dim - 1, 1))
        return e.start + dayFrac * (e.end - e.start)
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let frac = dragging ? dragFrac : currentFrac
            let handleY = clamp(frac * h, 22, h - 22)
            ZStack(alignment: .topTrailing) {
                if dragging {
                    ForEach(yearMarks, id: \.year) { m in
                        Text(String(m.year))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                            .position(x: geo.size.width - 34, y: clamp(m.frac * h, 12, h - 12))
                            .allowsHitTesting(false)
                    }
                    Text(target(dragFrac).label)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14).padding(.vertical, 9)
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
                let t = target(f)
                if t.month != lastMonthKey {
                    lastMonthKey = t.month
                    UISelectionFeedbackGenerator().selectionChanged()
                    if let id = t.id, id != scrolledID { scrolledID = id }
                }
            }
            .onEnded { _ in withAnimation(.easeOut(duration: 0.25)) { dragging = false } }
    }

    /// Zielmonat für einen Bahn-Anteil: Label + (falls geladen) Sektions-Id.
    private func target(_ f: CGFloat) -> (month: String, label: String, id: String?) {
        let es = entries
        guard let e = es.first(where: { f >= $0.start && f < $0.end }) ?? es.last else {
            return ("", "", nil)
        }
        let id = sections.first(where: { Self.monthKey($0.date) == e.month })?.id
        return (e.month, Self.label(e.date), id)
    }

    private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

    // MARK: date helpers

    private static func parse(_ ym: String) -> (Int, Date) {
        let p = ym.split(separator: "-")
        let y = Int(p.first ?? "0") ?? 0
        let m = p.count > 1 ? (Int(p[1]) ?? 1) : 1
        let d = Calendar.current.date(from: DateComponents(year: y, month: m, day: 1)) ?? Date()
        return (y, d)
    }
    private static func monthKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
    private static func label(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "de_DE"); f.dateFormat = "MMM yyyy"
        return f.string(from: d)
    }
}
