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
            .navigationTitle(selection.active ? title : "Fotos")
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
                        // Bild — oben rechts bleibt nur noch das Konto.
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
