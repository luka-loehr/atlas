import SwiftUI
import UniformTypeIdentifiers

/// A main window: the sidebar, what it selects, and the inspector.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @State private var window = MacWindowState()
    /// Where the window was, restored on the next launch.
    @SceneStorage("sidebar") private var savedSidebar: Data?
    @State private var newAlbum = false
    @State private var linkError: String?

    var body: some View {
        Group {
            if session.isConnected {
                split
            } else {
                MacConnectView()
            }
        }
        .environment(window)
        .task(id: session.config) { await model.start() }
        .onOpenURL { url in
            // a link can come from any web page: it connects only once confirmed
            if let link = Session.connectLink(url) { model.connectLink = link }
        }
        .onReceive(NotificationCenter.default.publisher(for: .atlasNewWindow)) { _ in openWindow(id: "main") }
        .alert("Connect to \(model.connectLink?.host ?? "")?",
               isPresented: Binding(get: { model.connectLink != nil }, set: { if !$0 { model.connectLink = nil } }),
               presenting: model.connectLink) { link in
            Button("Connect") {
                Task {
                    do { try await session.connect(to: link.address, token: link.token) } catch {
                        linkError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(session.isConnected
                 ? "Atlas would stop using your current server. Only connect if you opened this link with “atlas connect”."
                 : "Only connect if you opened this link with “atlas connect”.")
        }
        .alert("Connection Failed", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(linkError ?? "")
        }
    }

    private var split: some View {
        NavigationSplitView {
            MacSidebar(newAlbum: $newAlbum)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            detail
        }
        .searchable(text: $window.search, placement: .toolbar,
                    prompt: window.sidebar?.searchesFiles == true ? "Search Files" : "Search Photos")
        .focusedSceneValue(\.windowActions, WindowActions(
            state: window,
            newAlbum: { newAlbum = true },
            upload: window.upload,
            newFolder: window.newFolder,
            refresh: { Task { await model.refresh() } }))
        .albumNameAlert("New Album", isPresented: $newAlbum) { title in
            guard !title.isEmpty else { return }
            Task {
                guard let album = try? await model.library.client.createAlbum(title) else { return }
                await model.loadAlbums()
                window.sidebar = .album(album.id)
            }
        }
        .onAppear(perform: restore)
        .onChange(of: window.sidebar) { _, item in
            savedSidebar = try? JSONEncoder().encode(item)
            window.inspected = nil
            window.upload = nil
            window.newFolder = nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        let item = window.sidebar ?? .library
        Group {
            if window.isSearching {
                if item.searchesFiles {
                    MacDriveSearch(query: window.search)
                } else {
                    MacSearchView(query: window.search)
                }
            } else {
                switch item {
                case .library:
                    MacPhotoBrowser(source: .library)
                case .people:
                    MacPeopleView()
                case .special(let kind):
                    MacPhotoBrowser(source: .special(kind))
                case .album(let id):
                    if let album = model.albums.first(where: { $0.id == id }) {
                        MacPhotoBrowser(source: .album(album))
                    } else {
                        ProgressView()
                    }
                case .files:
                    MacDriveView()
                case .filesTrash:
                    MacDriveTrash()
                case .sharedLinks:
                    NavigationStack {
                        SharedLinksScreen(library: model.library).formStyle(.grouped)
                    }
                case .server:
                    MacServerView()
                }
            }
        }
        .id(window.isSearching ? "search" : String(describing: item))
    }

    private func restore() {
        guard let data = savedSidebar, let item = try? JSONDecoder().decode(SidebarItem?.self, from: data) else { return }
        window.sidebar = item
    }
}

// MARK: - Sidebar

/// The sidebar, grouped as in Photos and the Finder. Photos dragged from a
/// grid onto an album are added to it.
private struct MacSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(MacWindowState.self) private var window
    @Binding var newAlbum: Bool
    @AppStorage("sidebar.albums.expanded") private var albumsExpanded = true
    @State private var renaming: Album?
    @State private var deleting: Album?
    @State private var dropTarget: Int?
    @State private var changeFailed = false

    var body: some View {
        @Bindable var window = window
        List(selection: $window.sidebar) {
            Section("Photos") {
                row(.library)
                row(.people)
                row(.special(.favorites))
                row(.special(.videos))
            }
            Section("Albums", isExpanded: $albumsExpanded) {
                ForEach(model.userAlbums) { album in
                    Label(album.title, systemImage: "rectangle.stack")
                        .badge(album.count)
                        .tag(SidebarItem.album(album.id))
                        .listItemTint(dropTarget == album.id ? .accentColor : nil)
                        .contextMenu {
                            if model.library.sharing {
                                Button("Share Album as Link…") { window.sidebar = .album(album.id) }
                            }
                            Button("Rename Album…") { renaming = album }
                            Divider()
                            Button("Delete Album…", role: .destructive) { deleting = album }
                        }
                        .onDrop(of: [.atlasAssetIDs], isTargeted: Binding(
                            get: { dropTarget == album.id },
                            set: { dropTarget = $0 ? album.id : (dropTarget == album.id ? nil : dropTarget) })) { providers in
                            drop(providers, on: album)
                        }
                }
                Button { newAlbum = true } label: {
                    Label("New Album…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Section("Utilities") {
                row(.special(.archive))
                row(.special(.locked))
                row(.special(.trash))
            }
            Section("Files") {
                row(.files)
                row(.filesTrash)
            }
            Section("atlas") {
                if model.library.sharing { row(.sharedLinks) }
                row(.server)
            }
        }
        .listStyle(.sidebar)
        .albumNameAlert("Rename Album", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                        initial: renaming?.title ?? "") { title in
            guard let album = renaming, !title.isEmpty else { return }
            change { try await model.library.client.renameAlbum(album.id, to: title) }
        }
        .confirmationDialog("Delete Album “\(deleting?.title ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { album in
            Button("Delete Album", role: .destructive) {
                if window.sidebar == .album(album.id) { window.sidebar = .library }
                change { try await model.library.client.deleteAlbum(album.id) }
            }
        } message: { _ in
            Text("The photos stay in your library.")
        }
        .changeFailedAlert($changeFailed)
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.symbol).tag(item)
    }

    private func change(_ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                await model.loadAlbums()
                NotificationCenter.default.post(name: .atlasAlbumsChanged, object: nil)
            } catch {
                changeFailed = true
            }
        }
    }

    private func drop(_ providers: [NSItemProvider], on album: Album) -> Bool {
        let type = UTType.atlasAssetIDs.identifier
        let wanted = providers.filter { $0.hasItemConformingToTypeIdentifier(type) }
        guard !wanted.isEmpty else { return false }
        Task {
            var ids: [String] = []
            for provider in wanted {
                if let data = try? await provider.loadData(type), let id = String(data: data, encoding: .utf8) {
                    ids.append(id)
                }
            }
            guard !ids.isEmpty else { return }
            change {
                try await model.library.client.addToAlbum(album.id, ids)
                NSSound(named: "Pop")?.play()
            }
        }
        return true
    }
}

private extension NSItemProvider {
    func loadData(_ type: String) async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            _ = loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: data) }
            }
        }
    }
}

// MARK: - People

/// Everyone atlas recognized, as faces; a person opens their photos.
private struct MacPeopleView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacWindowState.self) private var window
    @State private var persons: [Person] = PeopleMemo.people
    @State private var loaded = !PeopleMemo.people.isEmpty
    @State private var renaming: Person?
    @State private var newName = ""
    @State private var changeFailed = false

    private var size: CGFloat { max(90, GridZoom.sizes[window.zoom]) }

    var body: some View {
        @Bindable var window = window
        NavigationStack(path: $window.peoplePath) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size * 1.4), spacing: 24)], spacing: 24) {
                    ForEach(persons) { person in
                        NavigationLink(value: person) {
                            VStack(spacing: 6) {
                                FaceCircle(library: model.library, person: person)
                                    .aspectRatio(1, contentMode: .fit)
                                Text(person.displayName)
                                    .font(.callout)
                                    .foregroundStyle(person.name == nil ? .secondary : .primary)
                                    .lineLimit(1)
                                Text(person.photos, format: .number)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename…") { newName = person.name ?? ""; renaming = person }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(person.displayName)
                        .accessibilityValue("\(person.photos) photos")
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(24)
                if persons.isEmpty && loaded {
                    ContentUnavailableView("No People", systemImage: "person.crop.circle",
                                           description: Text("People appear here once atlas has recognized faces."))
                        .padding(.top, 60)
                }
            }
            .overlay { if persons.isEmpty && !loaded { ProgressView() } }
            .navigationTitle("People")
            .navigationSubtitle(persons.isEmpty ? "" : "\(persons.count.formatted()) People")
            .navigationDestination(for: Person.self) { person in
                MacPhotoBrowser(source: .person(person))
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Rename…", systemImage: "pencil") { newName = person.name ?? ""; renaming = person }
                                .help("Name This Person")
                        }
                    }
            }
        }
        .task { await load() }
        .alert("Name This Person", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .changeFailedAlert($changeFailed)
    }

    private func load() async {
        if let fresh = try? await model.library.client.persons() {
            persons = fresh
            PeopleMemo.people = fresh
        }
        loaded = true
    }

    private func rename() {
        guard let person = renaming else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await model.library.client.renamePerson(person.id, name: name)
                await load()
            } catch {
                changeFailed = true
            }
        }
    }
}

// MARK: - Search

/// Photos search: people by name, then everything else by what is in the
/// picture, the moment the typing stops.
private struct MacSearchView: View {
    let query: String
    @Environment(AppModel.self) private var model
    @Environment(MacWindowState.self) private var window
    @State private var result: PhotoClient.SearchResult?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let result {
                    if !result.persons.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 16) {
                                ForEach(result.persons) { person in
                                    Button { window.open(person) } label: {
                                        VStack(spacing: 4) {
                                            FaceCircle(library: model.library, person: person).frame(width: 64, height: 64)
                                            Text(person.displayName).font(.caption).lineLimit(1)
                                        }
                                        .frame(width: 80)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .scrollIndicators(.hidden)
                        Divider()
                    }
                    if !result.semantic {
                        Label("Searching by content is unavailable right now: names, places and albums only.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                    MacPhotoBrowser(source: .search(query), given: result.items)
                } else if failed {
                    ServerUnavailableView()
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await model.library.client.warmSearch() }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                result = try await model.library.client.search(query.trimmingCharacters(in: .whitespaces))
                failed = false
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}

// MARK: - Server

/// The server's live status; the terminal opens in its own window.
private struct MacServerView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationStack {
            ServerStatusScreen()
                .formStyle(.grouped)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Terminal", systemImage: "terminal") { openWindow(id: "terminal") }
                            .help("Open a shell on atlas")
                    }
                }
        }
    }
}

// MARK: - Connecting

/// The first launch: where the server is and its token. `atlas connect`
/// prints a link that fills in both.
struct MacConnectView: View {
    @Environment(Session.self) private var session
    @State private var address = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("Connect to atlas").font(.title.bold())
                    Text("Your photos and files live on your own server. Enter its address and access token.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Form {
                    TextField("Server Address", text: $address, prompt: Text("atlas.your-tailnet.ts.net"))
                        .textContentType(.URL)
                        .plainTextEntry()
                    SecureField("Access Token", text: $token)
                        .textContentType(.password)
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(height: 120)
                Group {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else {
                        Text("“atlas connect” in Terminal prints a link that fills in both.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                Button {
                    connect()
                } label: {
                    if connecting { ProgressView().controlSize(.small).frame(width: 120) } else { Text("Connect").frame(width: 120) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(address.isEmpty || token.isEmpty || connecting)
            }
            .frame(maxWidth: 440)
            .padding(32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Connect")
    }

    private func connect() {
        guard !address.isEmpty, !token.isEmpty else { return }
        connecting = true
        error = nil
        Task {
            defer { connecting = false }
            do { try await session.connect(to: address, token: token) } catch { self.error = error.localizedDescription }
        }
    }
}
