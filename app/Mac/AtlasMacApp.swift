import SwiftUI
import AppKit

/// Atlas on the Mac: a native AppKit app built from the same target and the
/// same model, cache and network layer as the iPhone app, with an interface
/// made for the Mac (Human Interface Guidelines, "Designing for macOS"):
///
/// - one main window per `⌘N`, each a split view: a sidebar for the
///   library, albums, people, files and the server; the content in the
///   middle; an inspector for the photo's info (`⌘I`);
/// - every command in the menu bar with its keyboard shortcut, toolbar
///   items and context menus only repeating them;
/// - Settings in its own window (`⌘,`), the terminal in its own window;
/// - the system's full screen, window restoration, drag and drop with the
///   Finder and between the photos and the albums in the sidebar.
@main
struct AtlasMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Atlas", id: "main") {
            MacRootView()
                .environment(model.session)
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands { AtlasCommands(model: model) }

        Window("Terminal", id: "terminal") {
            MacTerminalWindow()
                .environment(model.session)
                .frame(minWidth: 520, minHeight: 300)
        }
        .defaultSize(width: 820, height: 520)
        .commandsRemoved()

        Settings {
            MacSettings()
                .environment(model.session)
                .environment(model)
        }
    }
}

/// What every window of the app shares: the connection to the server and
/// the library. Windows only hold what they show (`MacWindowState`).
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let session = Session()
    let library = Library()
    /// The albums for the sidebar and the Add to Album menu.
    var albums: [Album] = []
    /// A connect link waiting for the owner's yes (`atlas://connect`).
    var connectLink: Session.ConnectLink?

    private var started: ServerConfig?

    var userAlbums: [Album] { albums.filter(AddToAlbumSheet.isUserAlbum) }

    /// Connects the shared layer to the server the session names: the
    /// library from disk, then the server; the cache fill and warmer behind.
    func start() async {
        guard session.config != started else { return }
        started = session.config
        guard session.isConnected else {
            library.host = ""
            library.reset()
            albums = []
            return
        }
        library.host = session.base
        MediaCache.shared.client = library.client
        async let probe: Void = session.probe()
        async let albums: Void = loadAlbums()
        await library.start()
        buildTiles()
        CacheWarmer.shared.start(library)
        NetworkWatch.shared.start { [weak self] in
            guard let self, self.session.isConnected else { return }
            Task { await self.library.refresh() }
            ThumbFill.shared.resume()
        }
        _ = await (probe, albums)
    }

    /// The grid's tiles for what is new in the library; again a minute
    /// later while the thumbnail fill is still bringing thumbnails in.
    func buildTiles() {
        GridTiles.shared.build(library.assets.map(\.id))
        tileRetry?.cancel()
        tileRetry = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, ThumbFill.shared.stored < library.assets.count else { return }
            buildTiles()
        }
    }

    private var tileRetry: Task<Void, Never>?

    func loadAlbums() async {
        guard session.isConnected, let fresh = try? await library.client.albums() else { return }
        albums = fresh
        AlbumsMemo.albums = fresh
        AlbumsMemo.fetchedAt = .now
    }

    /// Back in front: what changed on the server while the app was away.
    func refresh() async {
        guard session.isConnected else { return }
        await library.refresh()
        buildTiles()
        await loadAlbums()
        ThumbFill.shared.resume()
    }
}

/// The app's AppKit side: links, the Dock menu, and staying open with no
/// window (the Mac convention for an app like Photos is to quit with the
/// last window; Atlas does, so the cache fill stops with it).
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DisplayColor.update()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        DisplayColor.update()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in await AppModel.shared.refresh() }
    }

    func applicationWillResignActive(_ notification: Notification) {
        Task { @MainActor in
            // the Locked album closes when the app goes to the background
            NotificationCenter.default.post(name: .atlasRelock, object: nil)
            MediaStore.shared.scheduleTrim()
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let window = NSMenuItem(title: "New Window", action: #selector(newWindow), keyEquivalent: "")
        window.target = self
        menu.addItem(window)
        return menu
    }

    @objc private func newWindow() {
        Task { @MainActor in
            NSApp.activate()
            NotificationCenter.default.post(name: .atlasNewWindow, object: nil)
        }
    }
}

extension Notification.Name {
    /// The app went to the background: the Locked album asks again.
    static let atlasRelock = Notification.Name("atlas.relock")
    static let atlasNewWindow = Notification.Name("atlas.newWindow")
}
