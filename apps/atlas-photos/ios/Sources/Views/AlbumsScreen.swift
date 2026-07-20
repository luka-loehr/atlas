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
                        sectionHeader("Meine Alben")
                        LazyVGrid(columns: cols, spacing: 18) {
                            ForEach(userAlbums) { album in
                                Button { openAlbum = album } label: {
                                    AlbumCard(library: library, album: album, locked: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    } else if loaded {
                        Text("keine Alben")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 40)
                    }
                }
                .scrollIndicators(.hidden)
                .refreshable { await load() }
            }
            .navigationTitle("Alben")
            .navigationDestination(item: $openAlbum) { album in
                AlbumScreen(library: library, album: album)
            }
            .navigationDestination(item: $openSpecial) { kind in
                SpecialCollectionScreen(library: library, kind: kind)
            }
        }
        .task { await load() }
    }

    // MARK: - Personen (horizontal preview row -> PersonsScreen)

    @State private var personsPreview: [Person] = []

    private var peopleRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink {
                PersonsScreen(library: library)
            } label: {
                HStack {
                    sectionHeader("Personen")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 16)
                        .padding(.top, 8)
                }
            }
            .buttonStyle(.plain)
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
                                        .font(.system(size: 12, weight: .medium))
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
        .task { personsPreview = (try? await library.client.persons()) ?? [] }
    }

    // MARK: - Utilities (Dienstprogramme)

    private var utilities: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Dienstprogramme")
            VStack(spacing: 0) {
                graphRow
                divider
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
                Text(kind.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                if kind == .locked {
                    Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Knowledge-Graph-Visualisierung (Personen · Orte · Tags)
    private var graphRow: some View {
        NavigationLink {
            GraphScreen(library: library)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 9))
                Text("Graph")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
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
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)
    }

    // MARK: - Data

    /// Real user albums only — the legacy Takeout "Trash"/"Locked Folder" album
    /// rows are surfaced through Dienstprogramme instead.
    private var userAlbums: [Album] {
        albums.filter { !SpecialAlbum.isLocked($0.title) && !SpecialAlbum.isTrash($0.title) }
    }

    private func openSpecial(_ kind: SpecialKind) {
        guard kind == .locked else { openSpecial = kind; return }
        authing = true
        Task {
            let ok = await Biometric.authenticate(reason: "Gesperrten Ordner entsperren")
            authing = false
            if ok { openSpecial = .locked }
        }
    }

    private func load() async {
        albums = (try? await library.client.albums()) ?? []
        loaded = true
    }
}

// MARK: - Special collections

enum SpecialKind: String, Identifiable, Hashable {
    case locked, archive, trash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .locked:  return "Gesperrt"
        case .archive: return "Archiv"
        case .trash:   return "Papierkorb"
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if selection.active {
                    Button("Fertig") { withAnimation(.snappy) { selection.exit() } }
                } else if !assets.isEmpty {
                    Button("Auswählen") { withAnimation(.snappy) { selection.enter() } }
                }
            }
            if kind == .trash && !assets.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) { confirmEmpty = true } label: {
                        Label("Papierkorb leeren", systemImage: "trash.slash")
                    }
                }
            }
        }
        .task { await load() }
        .fullScreenCover(item: $pick) { a in
            ViewerScreen(library: library, assets: assets, start: a)
                .navigationTransition(.zoom(sourceID: a.id, in: zoom))
        }
        .confirmationDialog("Papierkorb leeren?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Endgültig löschen", role: .destructive) {
                act { try await library.client.emptyTrash() }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle \(assets.count) Objekte werden dauerhaft von atlas entfernt.")
        }
        .confirmationDialog("\(selection.count) Objekte endgültig löschen?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Endgültig löschen", role: .destructive) {
                let ids = Array(selection.ids)
                act(remove: ids) { try await library.client.deletePermanent(ids) }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(assets) { asset in
                    SelectableThumb(asset: asset,
                                    thumbURL: library.client.thumbURL(asset.id, 512),
                                    selection: selection, namespace: zoom) { pick = asset }
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
                .init(title: "Wiederherstellen", icon: "arrow.uturn.backward") {
                    let x = ids(); act(remove: x) { try await library.client.restore(x) }
                },
                .init(title: "Löschen", icon: "trash", role: .destructive) { confirmDelete = true },
            ]
        case .archive:
            return [
                .init(title: "Aus Archiv", icon: "tray.and.arrow.up") {
                    let x = ids(); act(remove: x) { try await library.client.archive(x, false) }
                },
            ]
        case .locked:
            return [
                .init(title: "Entsperren", icon: "lock.open") {
                    let x = ids(); act(remove: x) { try await library.client.lock(x, false) }
                },
            ]
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: kind.icon).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(kind == .trash ? "Papierkorb ist leer"
                 : kind == .archive ? "Archiv ist leer" : "Nichts Gesperrtes")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        do {
            switch kind {
            case .locked:  assets = try await library.client.listLocked()
            case .archive: assets = try await library.client.listArchive()
            case .trash:   assets = try await library.client.listTrash()
            }
        } catch { assets = [] }
        loaded = true
    }

    /// Run a mutation, optionally drop `remove` ids from the local grid, refresh.
    private func act(remove: [String] = [], _ op: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await op() } catch {}
            if remove.isEmpty {
                await load()               // e.g. empty-trash: reload the (now empty) set
            } else {
                let gone = Set(remove)
                withAnimation(.snappy) { assets.removeAll { gone.contains($0.id) } }
            }
            await library.loadStats()
            withAnimation(.snappy) { selection.exit() }
        }
    }
}

struct AlbumCard: View {
    var library: Library
    var album: Album
    var locked: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)     // square, fits column width
                .overlay {
                    if locked {
                        ZStack {
                            Rectangle().fill(Color(.secondarySystemFill))
                            Image(systemName: "lock.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Thumb(url: album.cover.flatMap { library.client.thumbURL($0, 512) })
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 5) {
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(album.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Text("\(album.count)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
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
            ViewerScreen(library: library, assets: assets, start: a)
        }
    }
}
