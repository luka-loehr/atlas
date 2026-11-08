import SwiftUI

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
