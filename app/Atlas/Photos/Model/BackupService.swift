import Foundation
import Observation
import Photos
import CryptoKit
import UIKit
import os

/// Backs up the iPhone's photo library to atlas, always, without a button.
///
/// It runs on launch and on every return to the foreground, whenever the
/// photo library changes, and while the app is closed: uploads go through a
/// background URLSession (the file is the body, so iOS carries them on after
/// the app is suspended or killed), and BGAppRefresh / BGProcessing tasks
/// queue the next ones.
///
/// Identity: an asset's id on the server is the SHA-256 of its exact
/// original bytes. The phone hashes the same `PHAssetResource` it uploads,
/// once per asset version; hashes and what the server already has are kept
/// on disk, so a pass after the first only looks at what is new.
@MainActor
@Observable
final class BackupService: NSObject {
    static let shared = BackupService()

    enum Phase: Equatable {
        case idle
        case noAccess
        case scanning(done: Int, total: Int)
        case offline
        case failed(String)
    }

    /// What the status rows show.
    private(set) var phase: Phase = .idle
    /// Photos and videos of this iPhone whose content is not on atlas yet.
    private(set) var pending = 0
    private(set) var pendingBytes: Int64 = 0
    /// Uploads handed to iOS right now.
    private(set) var uploading = 0
    /// Uploads that failed since launch (they are retried on the next pass).
    private(set) var failed = 0
    private(set) var lastError: String?
    /// True once a pass has seen the whole library.
    private(set) var scanned = false
    private(set) var cleaning = false

    /// The Fotos timeline, for photos just taken (shown at once).
    @ObservationIgnored weak var library: Library?
    @ObservationIgnored private var host = ""
    @ObservationIgnored private var state = Persisted()
    @ObservationIgnored private var stateLoaded = false
    /// Hash → local id of contents still to upload, newest first.
    @ObservationIgnored private var queue: [(hash: String, localID: String)] = []
    /// Hashes with an upload task in the background session.
    @ObservationIgnored private var inflight: Set<String> = []
    @ObservationIgnored private var inflightBytes: [String: Int64] = [:]
    private var outboxBytes: Int64 { inflightBytes.values.reduce(0) { $0 + max($1, 0) } }
    private static let outboxLimit: Int64 = 2 << 30
    @ObservationIgnored private var failedThisRun: Set<String> = []
    @ObservationIgnored private var passTask: Task<Void, Never>?
    @ObservationIgnored private var fillTask: Task<Void, Never>?
    @ObservationIgnored private var passAgain = false
    @ObservationIgnored private var window = 4
    @ObservationIgnored private var watcher: Watcher?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var tasksRecovered = false
    /// Handed over by the app delegate when iOS wakes the app for finished
    /// background uploads; called once their events are delivered.
    @ObservationIgnored var backgroundEventsDone: (() -> Void)?

    @ObservationIgnored private let log = Logger(subsystem: "com.lukaloehr.Atlas", category: "Backup")

    static let sessionID = "com.lukaloehr.Atlas.upload"

    @ObservationIgnored private var madeSession: URLSession?
    private var session: URLSession {
        if let madeSession { return madeSession }
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.allowsConstrainedNetworkAccess = false
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.timeoutIntervalForRequest = 600
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        madeSession = s
        return s
    }

    nonisolated private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Backup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("outbox", isDirectory: true),
                                                 withIntermediateDirectories: true)
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return dir
    }()
    nonisolated private static var outbox: URL { directory.appendingPathComponent("outbox", isDirectory: true) }
    nonisolated private static var stateFile: URL { directory.appendingPathComponent("state.json") }

    // MARK: Persisted state

    private struct Persisted: Codable {
        struct Entry: Codable { var h: String; var m: Double }
        /// local id → content hash, and the modification time it was taken at
        var hashes: [String: Entry] = [:]
        /// hashes atlas is known to have
        var onServer: Set<String> = []
        /// photos created after this are shown in the grid before they upload
        var marker: Date?
    }

    private func loadState() async {
        guard !stateLoaded else { return }
        stateLoaded = true
        let loaded: Persisted? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: Self.stateFile) else { return nil }
            return try? JSONDecoder().decode(Persisted.self, from: data)
        }.value
        if let loaded { state = loaded }
    }

    private func saveState() {
        let snapshot = state
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.stateFile, options: .atomic)
        }
    }

    // MARK: Lifecycle

    /// Point the service at a server. Safe to call repeatedly.
    func configure(host: String) {
        guard host != self.host else { return }
        self.host = host
        _ = session   // reconnect to uploads iOS carried on while the app was gone
    }

    /// The app is in front: ask for photo access once, watch the library, and
    /// run a pass.
    func foreground() {
        guard !host.isEmpty else { return }
        #if targetEnvironment(simulator)
        // a simulator backs up its sample photos only when asked: ATLAS_BACKUP=1
        guard ProcessInfo.processInfo.environment["ATLAS_BACKUP"] == "1" else { return }
        #endif
        window = 4
        Task {
            guard await requestAccess() else { phase = .noAccess; return }
            startWatching()
            kick()
        }
    }

    /// The app goes away: hand iOS a bigger batch of uploads so they carry on
    /// while it is suspended.
    func background() {
        guard !host.isEmpty, isAuthorized else { return }
        window = 48
        let app = UIApplication.shared
        var id = UIBackgroundTaskIdentifier.invalid
        id = app.beginBackgroundTask(withName: "backup-handoff") {
            app.endBackgroundTask(id)
            id = .invalid
        }
        Task {
            await fill()
            if id != .invalid { app.endBackgroundTask(id); id = .invalid }
        }
    }

    /// A background task (refresh or processing): one pass, then as many
    /// uploads queued as fit. Returns false on failure.
    func runInBackground(window: Int) async -> Bool {
        guard !host.isEmpty, isAuthorized else { return false }
        self.window = window
        kick()
        await passTask?.value
        await fillTask?.value
        if case .failed = phase { return false }
        if case .offline = phase { return false }
        return true
    }

    func cancelBackgroundWork() {
        passTask?.cancel()
        fillTask?.cancel()
    }

    // MARK: Access and watching

    private var isAuthorized: Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: true
        default: false
        }
    }

    private func requestAccess() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let status = current == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .readWrite) : current
        return status == .authorized || status == .limited
    }

    private func startWatching() {
        guard watcher == nil else { return }
        let w = Watcher { [weak self] in self?.libraryChanged() }
        PHPhotoLibrary.shared().register(w)
        watcher = w
    }

    private func libraryChanged() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(3))   // a burst of changes is one pass
            guard !Task.isCancelled else { return }
            kick()
        }
    }

    private final class Watcher: NSObject, PHPhotoLibraryChangeObserver {
        let onChange: @MainActor () -> Void
        init(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
        nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
            Task { @MainActor [onChange] in onChange() }
        }
    }

    // MARK: Pass

    /// Starts a pass, or asks the running one to go again when it is done.
    func kick() {
        guard !host.isEmpty else { return }
        if passTask != nil { passAgain = true; return }
        passTask = Task {
            repeat {
                passAgain = false
                await pass()
            } while passAgain && !Task.isCancelled
            passTask = nil
        }
    }

    private func pass() async {
        guard isAuthorized else { phase = .noAccess; return }
        await loadState()
        await recoverTasks()
        let client = PhotoClient(host: host)

        // 1) the library, off the main thread: local id, modification time, created
        let items = await Task.detached(priority: .utility) { Self.listLibrary() }.value
        let present = Set(items.map(\.id))
        state.hashes = state.hashes.filter { present.contains($0.key) }

        // 2) photos just taken: into the grid at once, under their future id
        await showNew(items, client: client)

        // 3) hash what is new or was edited
        let toHash = items.filter { item in
            guard let e = state.hashes[item.id] else { return true }
            return e.m != item.modified
        }
        if !toHash.isEmpty { log.info("hashing \(toHash.count) of \(items.count)") }
        var done = 0
        for chunk in toHash.chunked(100) {
            if Task.isCancelled { return }
            phase = .scanning(done: done, total: toHash.count)
            let results = await Self.hashAll(chunk.map(\.id), limit: 6)
            for (id, hash) in results {
                if let item = chunk.first(where: { $0.id == id }) {
                    state.hashes[id] = .init(h: hash, m: item.modified)
                }
            }
            done += chunk.count
            saveState()
        }

        // 4) ask atlas which contents it does not have yet
        let unknown = Array(Set(state.hashes.values.map(\.h)).subtracting(state.onServer))
        do {
            for batch in unknown.chunked(200) {
                if Task.isCancelled { return }
                state.onServer.formUnion(try await client.exists(hashes: Array(batch)))
            }
        } catch {
            phase = .offline
            log.error("exists check failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        saveState()

        // 5) the queue: one local asset per missing content, newest first
        var seen = Set<String>()
        var next: [(hash: String, localID: String)] = []
        for item in items {   // newest first
            guard let h = state.hashes[item.id]?.h, !state.onServer.contains(h), seen.insert(h).inserted else { continue }
            next.append((h, item.id))
        }
        queue = next
        scanned = true
        updatePending()
        phase = .idle
        await fill()
    }

    private struct Item: Sendable {
        let id: String
        let modified: Double
        let created: Date?
    }

    nonisolated private static func listLibrary() -> [Item] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                     PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        opts.includeAssetSourceTypes = [.typeUserLibrary]
        let result = PHAsset.fetchAssets(with: opts)
        var out: [Item] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in
            out.append(Item(id: a.localIdentifier,
                            modified: (a.modificationDate ?? a.creationDate ?? .distantPast).timeIntervalSince1970,
                            created: a.creationDate))
        }
        return out
    }

    private func updatePending() {
        pending = queue.count
        let ids = queue.map(\.localID)
        Task.detached(priority: .utility) {
            let bytes = Self.estimatedBytes(Self.fetchAssets(ids))
            await MainActor.run { BackupService.shared.pendingBytes = bytes }
        }
    }

    /// Photos taken since the last look show up in the grid right away, with
    /// a local thumbnail, while their upload is still on its way.
    private func showNew(_ items: [Item], client: PhotoClient) async {
        guard let marker = state.marker else {
            state.marker = Date()   // first run: only photos taken from now on
            return
        }
        let fresh = items.filter { ($0.created ?? .distantPast) > marker }
        guard !fresh.isEmpty else { return }
        for item in fresh.prefix(30) {
            guard let asset = Self.fetchAssets([item.id]).first,
                  let resource = Self.primaryResource(asset),
                  let hash = try? await Self.sha256Hex(of: resource) else { continue }
            state.hashes[item.id] = .init(h: hash, m: item.modified)
            let isVideo = asset.mediaType == .video
            if let url = client.thumbURL(hash, 512), let img = await Self.localThumb(asset, side: 512) {
                ThumbLoader.shared.seed(url, image: img)
            }
            if let url = client.thumbURL(hash, 2048), let img = await Self.localThumb(asset, side: 1024) {
                ThumbLoader.shared.seed(url, image: img)
            }
            library?.insertLocally(Asset(id: hash, type: isVideo ? "video" : "photo", takenAt: asset.creationDate,
                                         width: asset.pixelWidth, height: asset.pixelHeight,
                                         durationS: isVideo ? asset.duration : nil, favorite: false))
        }
        state.marker = fresh.compactMap(\.created).max() ?? marker
        saveState()
    }

    // MARK: Uploads

    private struct Ticket: Codable {
        let hash: String
        let file: String
        let created: Double?
    }

    /// What iOS still uploads from an earlier run (also after a relaunch).
    private func recoverTasks() async {
        guard !tasksRecovered else { return }
        tasksRecovered = true
        let tasks = await session.allTasks
        var live = Set<String>()
        for t in tasks {
            guard let d = t.taskDescription?.data(using: .utf8),
                  let ticket = try? JSONDecoder().decode(Ticket.self, from: d) else { t.cancel(); continue }
            inflight.insert(ticket.hash)
            inflightBytes[ticket.hash] = t.countOfBytesExpectedToSend
            live.insert(ticket.file)
        }
        uploading = inflight.count
        // exported files whose task is gone
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: Self.outbox.path)) ?? [] where !live.contains(name) {
            try? fm.removeItem(at: Self.outbox.appendingPathComponent(name))
        }
    }

    /// Exports and hands to iOS as many uploads as the window allows.
    private func fill() async {
        if let fillTask { await fillTask.value; return }
        let task = Task {
            let client = PhotoClient(host: host)
            // exported files wait on disk until iOS has sent them: keep that bounded
            while inflight.count < window, outboxBytes < Self.outboxLimit, !Task.isCancelled,
                  let next = queue.first(where: { !inflight.contains($0.hash) && !failedThisRun.contains($0.hash) }) {
                guard let asset = Self.fetchAssets([next.localID]).first,
                      let resource = Self.primaryResource(asset) else {
                    queue.removeAll { $0.hash == next.hash }
                    continue
                }
                let ext = (resource.originalFilename as NSString).pathExtension
                let name = "\(next.hash).\(ext.isEmpty ? "bin" : ext)"
                let file = Self.outbox.appendingPathComponent(name)
                do {
                    try await Self.exportOriginal(resource, to: file)
                    guard let req = client.uploadRequest(filename: resource.originalFilename,
                                                         takenAt: asset.creationDate, hash: next.hash) else { break }
                    let task = session.uploadTask(with: req, fromFile: file)
                    let ticket = Ticket(hash: next.hash, file: name, created: asset.creationDate?.timeIntervalSince1970)
                    task.taskDescription = String(data: try JSONEncoder().encode(ticket), encoding: .utf8)
                    let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    task.countOfBytesClientExpectsToSend = size
                    task.resume()
                    inflightBytes[next.hash] = size
                    inflight.insert(next.hash)
                    uploading = inflight.count
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    failedThisRun.insert(next.hash)
                    failed += 1
                    lastError = error.localizedDescription
                    log.error("export \(next.hash, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        fillTask = task
        await task.value
        fillTask = nil
    }

    private func finished(_ task: URLSessionTask, error: Error?) {
        guard let d = task.taskDescription?.data(using: .utf8),
              let ticket = try? JSONDecoder().decode(Ticket.self, from: d) else { return }
        inflight.remove(ticket.hash)
        inflightBytes[ticket.hash] = nil
        uploading = inflight.count
        let file = Self.outbox.appendingPathComponent(ticket.file)
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if error == nil, (200..<300).contains(status) {
            state.onServer.insert(ticket.hash)
            queue.removeAll { $0.hash == ticket.hash }
            pending = queue.count
            saveState()
            // recently taken: the original stays on the phone (original cache)
            let recent = ticket.created.map { Date().timeIntervalSince1970 - $0 < 30 * 86400 } ?? false
            let ext = (ticket.file as NSString).pathExtension
            let hash = ticket.hash
            Task.detached(priority: .utility) {
                if !(recent && OriginalCache.shared.adopt(file, id: hash, kind: .original, ext: ext) != nil) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        } else {
            try? FileManager.default.removeItem(at: file)
            if (error as? URLError)?.code == .cancelled { return }
            failedThisRun.insert(ticket.hash)
            failed += 1
            lastError = error?.localizedDescription ?? "HTTP \(status)"
            log.error("upload \(ticket.hash, privacy: .public) failed: \(self.lastError ?? "", privacy: .public)")
        }
        if queue.isEmpty, inflight.isEmpty { updatePending() }
        Task { await fill() }
    }

    // MARK: Delete backed-up photos from the iPhone

    /// Deletes every photo and video of this iPhone whose content atlas has,
    /// re-checked with the server right before. iOS asks for confirmation.
    func deleteBackedUpFromDevice() {
        guard !cleaning else { return }
        cleaning = true
        Task {
            defer { cleaning = false }
            kick()
            await passTask?.value
            guard scanned else { return }
            let client = PhotoClient(host: host)
            var byHash: [String: [String]] = [:]
            for (id, e) in state.hashes where state.onServer.contains(e.h) { byHash[e.h, default: []].append(id) }
            var confirmed = Set<String>()
            do {
                for batch in Array(byHash.keys).chunked(200) {
                    confirmed.formUnion(try await client.exists(hashes: Array(batch)))
                }
            } catch {
                lastError = "atlas unreachable"
                return
            }
            let ids = byHash.filter { confirmed.contains($0.key) }.flatMap(\.value)
            let assets = Self.fetchAssets(ids).filter { $0.canPerform(.delete) }
            guard !assets.isEmpty else { return }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets as NSArray)
                }
            } catch let error as NSError {
                // the user saying no in the system dialog is not a failure
                if !(error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.userCancelled.rawValue) {
                    lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: PhotoKit helpers

    nonisolated static func fetchAssets(_ localIds: [String]) -> [PHAsset] {
        guard !localIds.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIds, options: nil)
        var out: [PHAsset] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in out.append(asset) }
        return out
    }

    /// The untouched original resource whose bytes define the atlas id.
    nonisolated static func primaryResource(_ asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let order: [PHAssetResourceType] = asset.mediaType == .video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
        for type in order {
            if let match = resources.first(where: { $0.type == type }) { return match }
        }
        return resources.first
    }

    nonisolated private static func hashAll(_ ids: [String], limit: Int) async -> [(String, String)] {
        let assets = fetchAssets(ids)
        return await withTaskGroup(of: (String, String)?.self) { group in
            var it = assets.makeIterator()
            func next() {
                guard let a = it.next() else { return }
                group.addTask {
                    guard let r = primaryResource(a), let h = try? await sha256Hex(of: r) else { return nil }
                    return (a.localIdentifier, h)
                }
            }
            for _ in 0..<limit { next() }
            var out: [(String, String)] = []
            for await r in group {
                if let r { out.append(r) }
                next()
            }
            return out
        }
    }

    /// SHA-256 (lowercase hex) of the resource's exact bytes, streamed;
    /// iCloud originals are fetched on demand.
    nonisolated static func sha256Hex(of resource: PHAssetResource) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            var hasher = SHA256()
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().requestData(for: resource, options: opts,
                dataReceivedHandler: { hasher.update(data: $0) },
                completionHandler: { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: hasher.finalize().map { String(format: "%02x", $0) }.joined()) }
                })
        }
    }

    /// Writes the exact original bytes to `url`.
    nonisolated static func exportOriginal(_ resource: PHAssetResource, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: opts) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: ()) }
            }
        }
    }

    nonisolated static func localThumb(_ asset: PHAsset, side: CGFloat) async -> UIImage? {
        await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFill, options: o) { img, info in
                // degraded first images are not delivered in this mode; guard anyway
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                cont.resume(returning: img)
            }
        }
    }

    /// PhotoKit has no public byte count; the resources' fileSize (KVC) is
    /// close enough for a status line.
    nonisolated static func estimatedBytes(_ assets: [PHAsset]) -> Int64 {
        var total: Int64 = 0
        for asset in assets {
            guard let r = primaryResource(asset) else { continue }
            if let n = r.value(forKey: "fileSize") as? Int64 { total += n }
            else if let n = r.value(forKey: "fileSize") as? Int { total += Int64(n) }
        }
        return total
    }
}

// MARK: - Background session events

extension BackupService: URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated { finished(task, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            // queue the next uploads before iOS suspends the app again
            _ = Task {
                await fill()
                backgroundEventsDone?()
                backgroundEventsDone = nil
            }
        }
    }
}

extension BackupService {
    /// One line for Einstellungen.
    var statusText: String {
        if cleaning { return "Checking…" }
        switch phase {
        case .noAccess: return "No Photo Access"
        case .offline: return "atlas Unreachable"
        case .failed(let m): return m
        case .scanning(let done, let total): return "Checking \(done.formatted()) / \(total.formatted())"
        case .idle:
            if !scanned { return "…" }
            if pending == 0 { return failed > 0 ? "\(failed) Failed" : "All Backed Up" }
            let bytes = pendingBytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: pendingBytes, countStyle: .file) : ""
            return "\(pending.formatted()) Pending" + bytes
        }
    }
}

extension PhotoClient {
    /// The upload request (PUT /v1/assets, the file as the body), for the
    /// background session.
    func uploadRequest(filename: String, takenAt: Date?, hash: String) -> URLRequest? {
        guard let url = url("/assets") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 3600)
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        AtlasAuth.apply(to: &req)
        // header values travel as latin-1: names with umlauts are percent-encoded
        let name = filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._"))) ?? "upload"
        req.setValue(name, forHTTPHeaderField: "X-Filename")
        req.setValue(hash, forHTTPHeaderField: "X-Content-Hash")
        req.setValue("iphone", forHTTPHeaderField: "X-Source")
        if let takenAt { req.setValue(String(Int(takenAt.timeIntervalSince1970)), forHTTPHeaderField: "X-Taken-At") }
        return req
    }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0 ..< Swift.min($0 + size, count)] }
    }
}
