import SwiftUI

struct RootView: View {
    /// Choosing Search opens its field. ATLAS_NOFOCUS=1 keeps it closed in a
    /// simulator, to see the tab as it is without the keyboard.
    private static var searchActivation: TabSearchActivation {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["ATLAS_NOFOCUS"] != nil { return .automatic }
        #endif
        return .searchTabSelection
    }

    @Environment(Session.self) private var session
    @State private var library = Library()
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = "photos"
    /// The tab the search button was pressed from: Dateien searches files,
    /// every other tab searches photos.
    @State private var searchFrom = "photos"
    @State private var linkError: String?
    /// A connect link waiting for the owner's yes.
    @State private var connectLink: Session.ConnectLink?
    /// An album or a photo a link asked for (the Album widget).
    @State private var albumLink: Int?
    @State private var linkedPhoto: LinkedPhoto?

    var body: some View {
        Group {
            if session.isConnected {
                // a tap on the Library tab while it is open goes to the newest photos
                TabView(selection: Binding(get: { tab }, set: { new in
                    if new == "photos", tab == "photos" {
                        NotificationCenter.default.post(name: .atlasScrollToNewest, object: nil)
                    }
                    tab = new
                })) {
                    Tab("Library", systemImage: "photo.on.rectangle.angled", value: "photos") {
                        PhotosScreen(library: library)
                    }
                    Tab("Albums", systemImage: "rectangle.stack", value: "albums") {
                        AlbumsScreen(library: library, link: $albumLink)
                    }
                    Tab("Files", systemImage: "folder", value: "drive") {
                        DriveScreen(library: library)
                    }
                    Tab(value: "search", role: .search) {
                        if searchFrom == "drive" {
                            DriveScreen(library: library, searchMode: true)
                        } else {
                            SearchScreen(library: library)
                        }
                    }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
                // choosing Search opens its field, the system's way (as Photos)
                .tabViewSearchActivation(Self.searchActivation)
                .onChange(of: tab) { old, new in
                    if new == "search", old != "search" { searchFrom = old }
                }
            } else {
                ConnectScreen()
            }
        }
        .task(id: session.config) {
            #if targetEnvironment(simulator)
            // ATLAS_TAB=albums|drive|settings|search opens a simulator on that tab
            if let wanted = ProcessInfo.processInfo.environment["ATLAS_TAB"] { tab = wanted }
            #endif
            guard session.isConnected else {
                library.host = ""
                library.reset()
                return
            }
            library.host = session.base
            MediaCache.shared.client = library.client
            // the backup always runs: photos taken while the app was closed
            // appear in the grid at once and upload behind it
            BackupService.shared.library = library
            BackupService.shared.configure(host: session.base)
            BackupService.shared.foreground()
            await library.start()
            CacheWarmer.shared.start(library)
            // back online (or on Wi-Fi again): everything carries on at once
            NetworkWatch.shared.start {
                guard session.isConnected else { return }
                Task { await library.refresh() }
                BackupService.shared.kick()
                ThumbFill.shared.resume()
            }
            // the Album widgets' photos, for albums chosen while the app was closed
            await WidgetShelf.shared.refresh(library: library, force: true)
        }
        .onChange(of: scenePhase) { _, phase in
            guard session.isConnected else { return }
            switch phase {
            case .background:
                BackupService.shared.background()
                AtlasApp.scheduleBackgroundWork()
                CacheWarmer.shared.stop()
                MediaStore.shared.scheduleTrim()
            case .active:
                Task {
                    await library.refresh()
                    await WidgetShelf.shared.refresh(library: library)
                }
                BackupService.shared.foreground()
                ThumbFill.shared.resume()
                if !library.assets.isEmpty { CacheWarmer.shared.start(library) }
            default:
                break
            }
        }
        .onOpenURL { url in
            if session.isConnected, let link = WidgetLink(url) {
                open(link)
                return
            }
            // a link can come from any web page: it connects only once confirmed
            connectLink = Session.connectLink(url)
        }
        .alert(
            "Connect to \(connectLink?.host ?? "")?",
            isPresented: Binding(get: { connectLink != nil }, set: { if !$0 { connectLink = nil } }),
            presenting: connectLink
        ) { link in
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
                ? "Atlas would stop using your current server and back up your photos to this one. Only connect if you opened this link with “atlas connect”."
                : "Atlas will back up your photos to this server. Only connect if you opened this link with “atlas connect”.")
        }
        .fullScreenCover(item: $linkedPhoto) { linked in
            ViewerScreen(library: library, assets: linked.assets, start: linked.start)
        }
        .alert("Connection Failed", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(linkError ?? "")
        }
    }
}

extension RootView {
    /// atlas://photo/<id>?album=<key> opens the photo in the viewer, among
    /// the album's photos (or the library's); atlas://album/<id> opens the
    /// album; atlas://open just the app.
    fileprivate func open(_ link: WidgetLink) {
        switch link {
        case .open:
            break
        case .album(let id):
            linkedPhoto = nil
            tab = "albums"
            albumLink = id
        case .photo(let id, let album):
            tab = album == nil ? "photos" : "albums"
            Task {
                var assets: [Asset] = []
                if let album {
                    assets = (try? await library.client.albumAssets(album)) ?? []
                } else {
                    // a cold start: the timeline comes from the disk first
                    for _ in 0..<50 where library.assets.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                    assets = library.assets
                }
                guard let start = assets.first(where: { $0.id == id }) else {
                    // gone from the album since the widget got it: the album
                    if let album { albumLink = album }
                    return
                }
                linkedPhoto = LinkedPhoto(assets: assets, start: start)
            }
        }
    }
}

/// What a link from the Album widget asks for.
enum WidgetLink {
    case open
    case album(Int)
    case photo(String, album: Int?)

    init?(_ url: URL) {
        guard url.scheme == "atlas" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host() {
        case "open":
            self = .open
        case "album":
            guard let id = parts.first.flatMap({ Int($0) }) else { return nil }
            self = .album(id)
        case "photo":
            guard let id = parts.first else { return nil }
            let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "album" }?.value
            self = .photo(id, album: key.flatMap(WidgetData.albumID(of:)))
        default:
            return nil
        }
    }
}

struct LinkedPhoto: Identifiable {
    let assets: [Asset]
    let start: Asset
    var id: String { start.id }
}
