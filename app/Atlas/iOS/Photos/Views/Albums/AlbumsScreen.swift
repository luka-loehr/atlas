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
                    PlacesSection(library: library)
                    listSection("Media Types", [.favorites, .videos])
                    listSection("Utilities", [.archive, .locked, .trash])
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(SimulatorHooks.scrolledDown ? .bottom : .top)
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

    private var userAlbums: [Album] { albums.filter(\.isUserAlbum) }

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
