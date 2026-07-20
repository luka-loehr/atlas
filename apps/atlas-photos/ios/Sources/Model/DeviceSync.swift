import Foundation
import Observation
import Photos
import CryptoKit

/// Syncs the on-device photo library with the atlas server.
///
/// Two directions, one shared content-hash foundation:
///   • `backupNew()`  — export + upload originals that are not yet on atlas.
///   • `deleteBackedUpFromDevice()` — delete iPhone assets whose content is
///      already safely on atlas (iOS shows its own confirmation dialog).
///
/// Identity strategy: the server takes the id of an uploaded asset from the
/// hash the app sends (the `X-Content-Hash` header, set by `PhotoMutations`).
/// BLAKE3 has no native Swift implementation, so the device hash is the
/// **SHA256 of the exact original bytes** (`CryptoKit`). The *same*
/// `PHAssetResource` is used for both hashing and export, so the hash
/// byte-matches the uploaded bytes, and `exists(hashes:)` and `upload(...)`
/// always speak about the same id — the whole flow is idempotent.
///
/// Depends only on the `PhotoMutations` extension surface:
///   • `client.exists(hashes:) async throws -> Set<String>` (existing subset)
///   • `client.upload(data:filename:takenAt:hash:) async throws`
@MainActor
@Observable
final class DeviceSync {

    // MARK: Dependency

    var client: PhotoClient

    init(client: PhotoClient) { self.client = client }

    // MARK: Published state (observable)

    enum Phase: Equatable { case idle, scanning, backing, deleting, done, failed(String) }

    var phase: Phase = .idle
    var running = false
    var currentName = ""

    /// Total items targeted by the current backup run (unique missing contents).
    var total = 0
    /// Successfully uploaded in the current backup run.
    var uploaded = 0
    /// Assets hashed so far during a scan.
    var scanned = 0
    /// Total user-library assets on the device (set by `scan`).
    var deviceCount = 0
    /// Assets whose content is NOT yet on atlas.
    var missingCount = 0
    /// Assets whose content is already on atlas.
    var backedUpCount = 0
    /// Failures in the current run (hash/export/upload errors).
    var failed = 0
    /// Assets removed from the device by the last cleanup run.
    var deletedFromDevice = 0
    /// Best-effort estimate of storage reclaimed by the last cleanup (bytes).
    var reclaimedBytes: Int64 = 0
    var lastError: String?

    /// True once a scan has produced hashes (backup/delete reuse them).
    var hasScanned: Bool { !hashByLocalId.isEmpty }

    // MARK: Tunables

    /// Content-hash / precheck fan-out. Streaming hashes are light; keep it wide.
    var maxConcurrent = 20
    /// Byte-upload fan-out. Kept lower: each in-flight upload holds an exported
    /// temp file (a 4K video can be hundreds of MB) — avoid disk/thermal spikes.
    var maxConcurrentUploads = 4
    /// Ids per `/api/exists` round-trip.
    var precheckBatch = 200

    // MARK: Internal, non-observable state

    @ObservationIgnored private var hashByLocalId: [String: String] = [:]   // localId -> sha256 hex
    @ObservationIgnored private var serverHaveHashes: Set<String> = []       // hashes confirmed on atlas
    @ObservationIgnored private var cancelled = false

    // MARK: Authorization

    /// Requests read/write access (covers enumeration, export and delete).
    /// Returns true for `.authorized` and `.limited`.
    func requestAccess() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let status = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            : current
        switch status {
        case .authorized, .limited:
            return true
        default:
            lastError = "Kein Fotozugriff"
            return false
        }
    }

    private var isUsable: Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return true
        default: return false
        }
    }

    /// Requests that any in-flight scan/backup/delete stop as soon as possible.
    func cancel() { cancelled = true }

    /// Clears cached hashes and counters (e.g. after external library changes).
    func reset() {
        guard !running else { return }
        hashByLocalId.removeAll()
        serverHaveHashes.removeAll()
        scanned = 0; deviceCount = 0; missingCount = 0; backedUpCount = 0
        total = 0; uploaded = 0; failed = 0
        deletedFromDevice = 0; reclaimedBytes = 0
        lastError = nil
        phase = .idle
    }

    // MARK: Flow A.1 — Scan

    /// Enumerates the device library, hashes every asset (streaming SHA256) and
    /// asks atlas which contents are missing. Publishes progress via
    /// `scanned` / `deviceCount` / `missingCount` / `backedUpCount`.
    func scan() async {
        guard !running else { return }
        guard isUsable else { fail("Kein Fotozugriff"); return }

        running = true
        cancelled = false
        phase = .scanning
        lastError = nil
        scanned = 0; missingCount = 0; backedUpCount = 0; failed = 0
        hashByLocalId.removeAll()
        serverHaveHashes.removeAll()

        let fetch = Self.fetchAllAssets()
        deviceCount = fetch.count
        var localIds: [String] = []
        localIds.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in localIds.append(asset.localIdentifier) }

        for start in stride(from: 0, to: localIds.count, by: precheckBatch) {
            if cancelled { break }
            let slice = Array(localIds[start ..< min(start + precheckBatch, localIds.count)])
            let assets = Self.fetchAssets(slice)

            // 1) Hash the slice with bounded concurrency.
            let pairs = await mapConcurrent(assets, limit: maxConcurrent) { [weak self] asset -> (String, String)? in
                await self?.hashAsset(asset) ?? nil
            }
            for (lid, hash) in pairs { hashByLocalId[lid] = hash }
            scanned = min(scanned + slice.count, deviceCount)

            // 2) Ask the server which of these contents already exist.
            let ids = Array(Set(pairs.map { $0.1 }))
            guard !ids.isEmpty else { continue }
            do {
                let existing = try await client.exists(hashes: ids)   // subset already on atlas
                serverHaveHashes.formUnion(existing)
            } catch {
                fail("Server nicht erreichbar")
                running = false
                return
            }
            recomputeCounts()   // live update as batches complete
        }

        recomputeCounts()
        running = false
        phase = cancelled ? .idle : .done
    }

    /// Recomputes asset-level backed-up / missing counts from the current caches.
    private func recomputeCounts() {
        var have = 0, miss = 0
        for hash in hashByLocalId.values {
            if serverHaveHashes.contains(hash) { have += 1 } else { miss += 1 }
        }
        backedUpCount = have
        missingCount = miss
        total = missingByHash().count
    }

    // MARK: Flow A.2 — Backup

    /// Exports and uploads every original that atlas does not yet have.
    /// Scans first if no hashes are cached. Publishes `uploaded` / `total`.
    func backupNew() async {
        if !hasScanned {
            await scan()
            if case .failed = phase { return }
        }
        guard !running else { return }
        guard isUsable else { fail("Kein Fotozugriff"); return }

        running = true
        cancelled = false
        phase = .backing
        lastError = nil
        uploaded = 0; failed = 0

        // One representative asset per missing content (dedupes identical photos).
        let targets = Self.fetchAssets(Array(missingByHash().values))
        total = targets.count
        guard total > 0 else { running = false; phase = .done; return }

        await forEachConcurrent(targets, limit: maxConcurrentUploads) { [weak self] in
            await self?.uploadOne($0)
        }

        running = false
        phase = cancelled ? .idle : (failed > 0 ? .failed("\(failed) fehlgeschlagen") : .done)
    }

    /// Exports one original to a temp file, then uploads its exact bytes. The
    /// exported bytes are byte-identical to what was hashed, so `hash` (sent as
    /// `X-Content-Hash`) is the authoritative server id. The temp file is
    /// memory-mapped rather than fully read into RAM, keeping 4K videos cheap.
    private func uploadOne(_ asset: PHAsset) async {
        if cancelled { return }
        guard let hash = hashByLocalId[asset.localIdentifier],
              let resource = Self.primaryResource(asset) else { failed += 1; return }

        let ext = (resource.originalFilename as NSString).pathExtension
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-upload-\(hash).\(ext.isEmpty ? "bin" : ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        currentName = resource.originalFilename
        do {
            try await Self.exportOriginal(resource, to: tmp)
            let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
            try await client.upload(
                data: data,
                filename: resource.originalFilename,
                takenAt: asset.creationDate,
                hash: hash
            )   // idempotent: server keys on X-Content-Hash == hash
            uploaded += 1
            serverHaveHashes.insert(hash)   // now safely on atlas
        } catch {
            failed += 1
            lastError = error.localizedDescription
        }
    }

    // MARK: Flow B — Delete backed-up assets from the device

    /// Collects device assets whose content is *freshly re-verified* on atlas and
    /// deletes them in a single `performChanges` (one system confirmation dialog).
    /// Publishes the result via `deletedFromDevice` / `reclaimedBytes`.
    func deleteBackedUpFromDevice() async {
        if !hasScanned {
            await scan()
            if case .failed = phase { return }
        }
        guard !running else { return }
        guard isUsable else { fail("Kein Fotozugriff"); return }

        running = true
        cancelled = false
        phase = .deleting
        lastError = nil
        deletedFromDevice = 0; reclaimedBytes = 0

        // Candidate assets: known hash + locally deletable.
        var assetsByHash: [String: [PHAsset]] = [:]
        for asset in Self.fetchAssets(Array(hashByLocalId.keys)) {
            guard let hash = hashByLocalId[asset.localIdentifier], asset.canPerform(.delete) else { continue }
            assetsByHash[hash, default: []].append(asset)
        }
        let candidateHashes = Array(assetsByHash.keys)
        guard !candidateHashes.isEmpty else { running = false; phase = .done; return }

        // Re-verify against the server NOW — never trust the cached confirmation,
        // so an asset the server dropped meanwhile is not deleted locally.
        var confirmed: Set<String> = []
        for start in stride(from: 0, to: candidateHashes.count, by: precheckBatch) {
            if cancelled { running = false; phase = .idle; return }
            let slice = Array(candidateHashes[start ..< min(start + precheckBatch, candidateHashes.count)])
            do {
                let existing = try await client.exists(hashes: slice)
                confirmed.formUnion(existing)
            } catch {
                fail("Server nicht erreichbar")
                running = false
                return
            }
        }
        serverHaveHashes.formUnion(confirmed)

        var toDelete: [PHAsset] = []
        for (hash, assets) in assetsByHash where confirmed.contains(hash) {
            toDelete.append(contentsOf: assets)
        }
        guard !toDelete.isEmpty else { running = false; phase = .done; return }

        let estimate = Self.estimatedBytes(toDelete)

        // One change request → one system dialog naming the count. Deleted assets
        // land in "Zuletzt gelöscht" (30-day recovery) — an extra safety net.
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
            }
            deletedFromDevice = toDelete.count
            reclaimedBytes = estimate
            for asset in toDelete { hashByLocalId.removeValue(forKey: asset.localIdentifier) }
            recomputeCounts()
            phase = .done
        } catch let error as NSError {
            if error.domain == PHPhotosErrorDomain, error.code == PHPhotosError.userCancelled.rawValue {
                phase = .idle   // user declined the dialog — not a failure
            } else {
                fail(error.localizedDescription)
            }
        }
        running = false
    }

    // MARK: Content hashing

    /// SHA256 (hex) of one asset's canonical original bytes, or nil on error.
    private func hashAsset(_ asset: PHAsset) async -> (String, String)? {
        if cancelled { return nil }
        guard let resource = Self.primaryResource(asset) else { failed += 1; return nil }
        do {
            let hex = try await Self.sha256Hex(of: resource)
            return (asset.localIdentifier, hex)
        } catch {
            failed += 1
            return nil
        }
    }

    /// Missing contents deduped to one representative localId each.
    private func missingByHash() -> [String: String] {
        var out: [String: String] = [:]
        for (lid, hash) in hashByLocalId where !serverHaveHashes.contains(hash) {
            if out[hash] == nil { out[hash] = lid }
        }
        return out
    }

    private func fail(_ message: String) {
        lastError = message
        phase = .failed(message)
    }

    // MARK: PhotoKit helpers (stateless)

    /// Photos + videos from the user's own library, newest first (matches the
    /// server timeline order).
    static func fetchAllAssets() -> PHFetchResult<PHAsset> {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                     PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        opts.includeAssetSourceTypes = [.typeUserLibrary]
        return PHAsset.fetchAssets(with: opts)
    }

    static func fetchAssets(_ localIds: [String]) -> [PHAsset] {
        guard !localIds.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIds, options: nil)
        var out: [PHAsset] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in out.append(asset) }
        return out
    }

    /// The canonical original resource whose bytes define the atlas id. Prefers
    /// the untouched original over rendered/edited variants.
    static func primaryResource(_ asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let order: [PHAssetResourceType] = asset.mediaType == .video
            ? [.video, .fullSizeVideo]
            : [.photo, .fullSizePhoto]
        for type in order {
            if let match = resources.first(where: { $0.type == type }) { return match }
        }
        return resources.first
    }

    /// Streams the resource's exact bytes and returns their SHA256 as lowercase
    /// hex. `isNetworkAccessAllowed` pulls iCloud originals down on demand.
    static func sha256Hex(of resource: PHAssetResource) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            var hasher = SHA256()
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: opts,
                dataReceivedHandler: { chunk in hasher.update(data: chunk) },
                completionHandler: { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                        cont.resume(returning: hex)
                    }
                }
            )
        }
    }

    /// Writes the exact original bytes to `url` (HEIC stays HEIC, video stays
    /// untranscoded), downloading from iCloud if needed.
    static func exportOriginal(_ resource: PHAssetResource, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: opts) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: ()) }
            }
        }
    }

    /// Best-effort byte estimate for a set of assets, summed over their resources.
    /// PHAsset exposes no public byte count, so this reads the resource fileSize
    /// via KVC; unavailable values contribute 0. Fine for a self-hosted app.
    static func estimatedBytes(_ assets: [PHAsset]) -> Int64 {
        var total: Int64 = 0
        for asset in assets {
            for resource in PHAssetResource.assetResources(for: asset) {
                if let n = resource.value(forKey: "fileSize") as? Int64 { total += n }
                else if let n = resource.value(forKey: "fileSize") as? Int { total += Int64(n) }
            }
        }
        return total
    }

    // MARK: Bounded-concurrency primitives

    /// Maps `items` with at most `limit` tasks in flight, dropping nil results.
    private func mapConcurrent<T: Sendable>(
        _ items: [PHAsset], limit: Int,
        _ transform: @escaping (PHAsset) async -> T?
    ) async -> [T] {
        guard !items.isEmpty else { return [] }
        let window = max(1, limit)
        return await withTaskGroup(of: T?.self) { group in
            var results: [T] = []
            var index = 0
            while index < min(window, items.count) {
                let asset = items[index]; index += 1
                group.addTask { await transform(asset) }
            }
            while let result = await group.next() {
                if let result { results.append(result) }
                if index < items.count {
                    let asset = items[index]; index += 1
                    group.addTask { await transform(asset) }
                }
            }
            return results
        }
    }

    /// Runs `body` over `items` with at most `limit` tasks in flight.
    private func forEachConcurrent(
        _ items: [PHAsset], limit: Int,
        _ body: @escaping (PHAsset) async -> Void
    ) async {
        guard !items.isEmpty else { return }
        let window = max(1, limit)
        await withTaskGroup(of: Void.self) { group in
            var index = 0
            while index < min(window, items.count) {
                let asset = items[index]; index += 1
                group.addTask { await body(asset) }
            }
            while await group.next() != nil {
                if index < items.count {
                    let asset = items[index]; index += 1
                    group.addTask { await body(asset) }
                }
            }
        }
    }
}
