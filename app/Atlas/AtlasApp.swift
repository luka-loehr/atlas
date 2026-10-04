import SwiftUI
import BackgroundTasks

@main
struct AtlasApp: App {
    static let backupTaskID = "com.lukaloehr.Atlas.backup"
    static let refreshTaskID = "com.lukaloehr.Atlas.refresh"

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = Session()

    init() { Self.registerBackgroundTasks() }

    var body: some Scene {
        WindowGroup {
            RootView().environment(session)
        }
    }

    // MARK: Background work while the app is closed

    private static func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backupTaskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handle(task, processing: true)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handle(task, processing: false)
        }
    }

    /// Asks iOS for the next background windows: a short refresh (new photos
    /// are queued for upload) and a long processing run (backup and the
    /// thumbnail store). Safe to call repeatedly.
    static func scheduleBackgroundWork() {
        let processing = BGProcessingTaskRequest(identifier: backupTaskID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(processing)
        let refresh = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)
    }

    private static func handle(_ task: BGTask, processing: Bool) {
        task.expirationHandler = {
            Task { @MainActor in
                BackupService.shared.cancelBackgroundWork()
                ThumbFill.shared.stop()
            }
        }
        Task { @MainActor in
            defer { scheduleBackgroundWork() }   // keep the chain alive
            let session = Session()
            guard session.isConnected else {
                task.setTaskCompleted(success: true)
                return
            }
            BackupService.shared.configure(host: session.base)
            var ok = await BackupService.shared.runInBackground(window: processing ? 64 : 24)
            if processing {
                // the timeline from disk and the server, then the thumbnails
                let library = Library()
                library.host = session.base
                await library.start()
                await WidgetShelf.shared.refresh(library: library, force: true)
                await ThumbFill.shared.finish()
                ok = ok && ThumbFill.shared.failed == 0
            }
            task.setTaskCompleted(success: ok)
        }
    }
}

/// Hands the background upload session's wake-ups to the backup service.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackupService.sessionID else { completionHandler(); return }
        MainActor.assumeIsolated {
            let session = Session()
            // no server, no session to deliver the events: iOS must not wait
            guard session.isConnected else { completionHandler(); return }
            BackupService.shared.backgroundEventsDone = completionHandler
            BackupService.shared.configure(host: session.base)
        }
    }
}

struct RootView: View {
    @Environment(Session.self) private var session
    @State private var library = Library()
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = "photos"
    /// The tab the search button was pressed from: Dateien searches files,
    /// every other tab searches photos.
    @State private var searchFrom = "photos"
    @State private var linkError: String?
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
            Task {
                do { try await session.handle(url) } catch { linkError = error.localizedDescription }
            }
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

/// Erster Start: Wo steht der Server, und wie lautet das Zugangstoken.
struct ConnectScreen: View {
    @Environment(Session.self) private var session
    @State private var address = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case address, token }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.stack")
                            .font(.largeTitle)
                            .imageScale(.large)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Connect to atlas")
                            .font(.title2.bold())
                        Text("Your photos and files live on your own server. Enter its address and access token.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Server Address", text: $address, prompt: Text("atlas.your-tailnet.ts.net"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focus = .token }
                    SecureField("Access Token", text: $token)
                        .textContentType(.password)
                        .focused($focus, equals: .token)
                        .submitLabel(.go)
                        .onSubmit { connect() }
                } footer: {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else {
                        Text("“atlas connect” on the Mac shows a link that fills in both.")
                    }
                }
                Section {
                    Button {
                        connect()
                    } label: {
                        if connecting {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Connect").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(address.isEmpty || token.isEmpty || connecting)
                }
            }
        }
    }

    private func connect() {
        guard !address.isEmpty, !token.isEmpty else { return }
        connecting = true
        error = nil
        Task {
            defer { connecting = false }
            do {
                try await session.connect(to: address, token: token)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
