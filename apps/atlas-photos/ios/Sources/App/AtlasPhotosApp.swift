import SwiftUI
import BackgroundTasks

@main
struct AtlasPhotosApp: App {
    static let backupTaskID = "com.lukaloehr.AtlasPhotos.backup"

    init() { Self.registerBackupTask() }

    var body: some Scene {
        WindowGroup { RootView() }
    }

    // MARK: Background backup (BGProcessingTask)

    /// The sync driven by the current background task — lets the expiration
    /// handler cancel it from any queue.
    @MainActor private static var backgroundSync: DeviceSync?

    private static func registerBackupTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backupTaskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handleBackup(task)
        }
    }

    /// Asks iOS to run the backup task at a good moment (charging not required,
    /// network required). Safe to call repeatedly — one pending request per id.
    static func scheduleBackup() {
        let request = BGProcessingTaskRequest(identifier: backupTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleBackup(_ task: BGProcessingTask) {
        task.expirationHandler = {
            Task { @MainActor in backgroundSync?.cancel() }
        }
        Task { @MainActor in
            defer {
                backgroundSync = nil
                scheduleBackup()   // keep the chain alive for the next window
            }
            guard UserDefaults.standard.bool(forKey: "photos.autoBackup") else {
                task.setTaskCompleted(success: true)
                return
            }
            let host = UserDefaults.standard.string(forKey: "photos.host")
                ?? "atlas.your-tailnet.ts.net:8788"
            let sync = DeviceSync(client: PhotoClient(host: host))
            backgroundSync = sync
            guard await sync.requestAccess() else {
                task.setTaskCompleted(success: false)
                return
            }
            await sync.scan()
            if case .failed = sync.phase {
                task.setTaskCompleted(success: false)
                return
            }
            await sync.backupNew()
            task.setTaskCompleted(success: sync.failed == 0)
        }
    }
}

struct RootView: View {
    @State private var library = Library()
    @State private var watchSync: DeviceSync?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("photos.host") private var host = "atlas.your-tailnet.ts.net:8788"
    @AppStorage("photos.autoBackup") private var autoBackup = false

    var body: some View {
        TabView {
            Tab("Fotos", systemImage: "photo.on.rectangle.angled") {
                PhotosScreen(library: library)
            }
            Tab("Alben", systemImage: "rectangle.stack") {
                AlbumsScreen(library: library)
            }
            Tab(role: .search) {
                SearchScreen(library: library)
            }
        }
        .tint(.primary)
        .task {
            library.host = host
            if autoBackup, watchSync == nil {
                let sync = DeviceSync(client: library.client)
                sync.startWatching()
                watchSync = sync
            }
            await library.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, autoBackup {
                AtlasPhotosApp.scheduleBackup()
            }
            // instant foreground sync: photos taken while the app was closed
            // appear in the grid within a second (local thumb seeded, upload
            // runs behind it) — Google-Photos-Gefühl beim Öffnen
            if phase == .active, autoBackup {
                Task {
                    let sync = watchSync ?? DeviceSync(client: library.client)
                    if watchSync == nil { watchSync = sync }
                    guard await sync.requestAccess() else { return }
                    await sync.quickSync(into: library)
                }
            }
        }
    }
}
