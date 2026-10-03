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
            BackupService.shared.backgroundEventsDone = completionHandler
            let session = Session()
            if session.isConnected { BackupService.shared.configure(host: session.base) }
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

    var body: some View {
        Group {
            if session.isConnected {
                TabView(selection: $tab) {
                    Tab("Fotos", systemImage: "photo.on.rectangle.angled", value: "photos") {
                        PhotosScreen(library: library)
                    }
                    Tab("Alben", systemImage: "rectangle.stack", value: "albums") {
                        AlbumsScreen(library: library)
                    }
                    Tab("Dateien", systemImage: "folder", value: "drive") {
                        DriveScreen(library: library)
                    }
                    Tab("Einstellungen", systemImage: "gearshape", value: "settings") {
                        SettingsTab(library: library)
                    }
                    Tab(value: "search", role: .search) {
                        if searchFrom == "drive" {
                            DriveScreen(library: library, searchMode: true)
                        } else {
                            SearchScreen(library: library)
                        }
                    }
                }
                .tint(.primary)
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
            ThumbLoader.shared.client = library.client
            // the backup always runs: photos taken while the app was closed
            // appear in the grid at once and upload behind it
            BackupService.shared.library = library
            BackupService.shared.configure(host: session.base)
            BackupService.shared.foreground()
            await library.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard session.isConnected else { return }
            switch phase {
            case .background:
                BackupService.shared.background()
                AtlasApp.scheduleBackgroundWork()
            case .active:
                Task { await library.refresh() }
                BackupService.shared.foreground()
            default:
                break
            }
        }
        .onOpenURL { url in
            Task {
                do { try await session.handle(url) } catch { linkError = error.localizedDescription }
            }
        }
        .alert("Verbindung fehlgeschlagen", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(linkError ?? "")
        }
    }
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
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 78, height: 78)
                            .glassEffect(.regular, in: Circle())
                        Text("Mit atlas verbinden")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("Deine Fotos und Dateien liegen auf deinem eigenen Server. Gib seine Adresse und das Zugangstoken ein.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Serveradresse", text: $address, prompt: Text("atlas.your-tailnet.ts.net"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 15, design: .monospaced))
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focus = .token }
                    SecureField("Zugangstoken", text: $token)
                        .textContentType(.password)
                        .focused($focus, equals: .token)
                        .submitLabel(.go)
                        .onSubmit { connect() }
                } footer: {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else {
                        Text("„atlas connect“ auf dem Mac zeigt einen Link, der beides ausfüllt.")
                    }
                }
                Section {
                    Button {
                        connect()
                    } label: {
                        HStack {
                            Spacer()
                            if connecting { ProgressView() } else { Text("Verbinden").fontWeight(.semibold) }
                            Spacer()
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
