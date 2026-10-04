import Foundation
import os

/// Every on-device copy of server media, on disk: the one store behind
/// `MediaCache` (images), `VideoCache` (video bytes) and `ThumbFill`.
///
/// Two tiers:
///   • the 512 grid thumbnails, pinned: every one of them ends up on the
///     phone (`ThumbFill`) and none is ever evicted. They are the whole
///     library, about 850 MB, in Application Support.
///   • everything else (2048 previews, originals, video bytes, face crops,
///     drive thumbnails) shares one fixed budget of 15 GB in Caches and is
///     evicted least valuable first, see `trim()`.
///
/// Media URLs are content-addressed and immutable, so a file, once written,
/// is valid forever. Thread-safe: the indexes sit behind a lock, the file
/// system is touched only from the callers' threads, which are never the
/// main thread.
final class MediaStore: @unchecked Sendable {
    static let shared = MediaStore()

    /// What a file is. The raw value names its directory.
    enum Kind: String, CaseIterable, Sendable {
        case thumb = "thumb"            // 512 grid thumbnail, pinned
        case preview = "preview"        // 2048
        case original = "original"
        case video = "video"            // sparse: the head, or what was streamed
        case face = "face"              // /faces/{id}/crop
        case driveThumb = "drive"       // /drive/files/{id}/thumb

        /// How fast an unused entry loses its value: eviction ranks entries
        /// by idle time × weight. Small things that make whole screens open
        /// instantly (faces, drive thumbnails) age slowest, big originals
        /// fastest.
        var weight: Double {
            switch self {
            case .thumb: 0
            case .face, .driveThumb: 0.2
            case .preview: 1
            case .video: 1.5
            case .original: 2
            }
        }
    }

    struct Key: Hashable, Sendable {
        let kind: Kind
        let id: String
        init(_ kind: Kind, _ id: String) { self.kind = kind; self.id = id }
        var name: String { "\(kind.rawValue)/\(id)" }
    }

    /// The budget of everything but the grid thumbnails. Fixed on purpose:
    /// the cache looks after itself, there is nothing to set.
    static let budget: Int64 = 15 << 30

    private struct Entry {
        var url: URL
        var bytes: Int64
        var used: Date
    }

    /// Where the pinned grid thumbnails live (unchanged since the first
    /// thumbnail store, so no phone downloads them twice).
    let thumbDirectory: URL
    /// The budgeted part.
    let directory: URL

    private let lock = NSLock()
    private var thumbs: Set<String> = []
    private var thumbBytes: Int64 = 0
    private var thumbShards: Set<String> = []
    private var thumbIndexTask: Task<Void, Never>?

    private var entries: [Key: Entry] = [:]
    private var total: Int64 = 0
    private var indexed = false
    private var dirs: Set<String> = []
    /// Entries in use right now (a video playing); never evicted.
    private var leases: [Key: Int] = [:]
    /// Assets taken in the last weeks: their files are kept longest.
    private var recent: Set<String> = []

    private let trimQueue = DispatchQueue(label: "atlas.media.trim", qos: .utility)
    private var trimScheduled = false
    private let log = Logger(subsystem: "com.lukaloehr.atlas", category: "MediaStore")

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        thumbDirectory = support.appendingPathComponent("Thumbs512", isDirectory: true)
        directory = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Media", isDirectory: true)
        for var dir in [thumbDirectory, directory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
    }

    // MARK: Paths

    private static func safe(_ id: String) -> String {
        String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
    }

    /// 256 shard directories keep each directory small.
    private static func shard(_ id: String) -> String { String(safe(id).prefix(2)) }

    /// Where the grid thumbnail of `id` lives (whether or not it is there yet).
    func thumbURL(_ id: String) -> URL {
        thumbDirectory.appendingPathComponent(Self.shard(id), isDirectory: true)
            .appendingPathComponent(id + ".webp")
    }

    private func budgetedURL(_ key: Key, ext: String) -> URL {
        directory.appendingPathComponent(key.kind.rawValue, isDirectory: true)
            .appendingPathComponent(Self.shard(key.id), isDirectory: true)
            .appendingPathComponent("\(Self.safe(key.id)).\(ext)")
    }

    private func makeParent(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if lock.withLock({ dirs.contains(parent.path) }) { return }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        lock.withLock { _ = dirs.insert(parent.path) }
    }

    // MARK: Lookup

    /// Whether the file is on the phone, without marking it used.
    func contains(_ key: Key) -> Bool {
        lock.withLock {
            if key.kind == .thumb { return thumbs.contains(key.id) }
            indexIfNeeded()
            return entries[key] != nil
        }
    }

    /// The local file, if there is one; marks it as just used.
    func file(_ key: Key) -> URL? {
        if key.kind == .thumb { return contains(key) ? thumbURL(key.id) : nil }
        let now = Date()
        let hit: (URL, Bool)? = lock.withLock {
            indexIfNeeded()
            guard var e = entries[key] else { return nil }
            // the modification date carries the use across launches; it is
            // written at most once an hour per file
            let persist = now.timeIntervalSince(e.used) > 3600
            e.used = now
            entries[key] = e
            return (e.url, persist)
        }
        guard let (url, persist) = hit else { return nil }
        if persist { try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path) }
        return url
    }

    // MARK: Writing

    /// Takes a downloaded (or just exported) file in by moving it. Returns
    /// where it lives now, or nil when it could not be moved (the file is
    /// then left where it was).
    @discardableResult
    func adopt(_ file: URL, _ key: Key, ext: String) -> URL? {
        let fm = FileManager.default
        if key.kind == .thumb {
            let dest = thumbURL(key.id)
            do {
                let shard = Self.shard(key.id)
                if !lock.withLock({ thumbShards.contains(shard) }) {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    lock.withLock { _ = thumbShards.insert(shard) }
                }
                // a finished file is moved in, so a crash never leaves a
                // truncated thumbnail that would decode as garbage
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: file, to: dest)
            } catch {
                return nil
            }
            let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            lock.withLock { if thumbs.insert(key.id).inserted { thumbBytes += size } }
            return dest
        }
        let clean = ext.isEmpty ? "bin" : ext.lowercased()
        let dest = budgetedURL(key, ext: clean)
        do {
            try makeParent(of: dest)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: file, to: dest)
        } catch {
            log.error("could not keep \(key.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let size = Int64((try? dest.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        let stale: URL? = lock.withLock {
            indexIfNeeded()
            let old = entries[key]
            if let old { total -= old.bytes }
            entries[key] = Entry(url: dest, bytes: size, used: Date())
            total += size
            return old.flatMap { $0.url != dest ? $0.url : nil }
        }
        if let stale { try? fm.removeItem(at: stale) }
        scheduleTrim()
        return dest
    }

    /// A file that failed to decode is removed so it is fetched again.
    func remove(_ key: Key) {
        if key.kind == .thumb {
            let url = thumbURL(key.id)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: url)
            lock.withLock { if thumbs.remove(key.id) != nil { thumbBytes = max(thumbBytes - size, 0) } }
            return
        }
        let gone: Entry? = lock.withLock {
            indexIfNeeded()
            guard let e = entries.removeValue(forKey: key) else { return nil }
            total -= e.bytes
            return e
        }
        if let gone { Self.delete(gone.url) }
    }

    /// Removes a file and what belongs to it (a video's range list).
    private static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if url.pathExtension == "vdata" {
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("vmeta"))
        }
    }

    // MARK: Videos (written in place, range by range)

    /// The sparse data file of a video and its range list. The entry is
    /// leased while open, see `lease`.
    func videoFiles(_ id: String) throws -> (data: URL, meta: URL) {
        let key = Key(.video, id)
        let data = lock.withLock { () -> URL? in indexIfNeeded(); return entries[key]?.url } ?? budgetedURL(key, ext: "vdata")
        try makeParent(of: data)
        return (data, data.deletingPathExtension().appendingPathExtension("vmeta"))
    }

    /// The bytes of a video on disk changed (more of it was streamed).
    func noteVideo(_ id: String, file: URL, bytes: Int64) {
        let key = Key(.video, id)
        lock.withLock {
            indexIfNeeded()
            if let old = entries[key] { total -= old.bytes }
            entries[key] = Entry(url: file, bytes: bytes, used: Date())
            total += bytes
        }
        scheduleTrim()
    }

    /// While leased an entry is never evicted (a video being played).
    func lease(_ key: Key) { lock.withLock { leases[key, default: 0] += 1 } }

    func release(_ key: Key) {
        lock.withLock {
            let n = (leases[key] ?? 1) - 1
            leases[key] = n > 0 ? n : nil
        }
    }

    // MARK: State

    /// Grid thumbnails on the phone.
    var thumbStats: (count: Int, bytes: Int64) { lock.withLock { (thumbs.count, thumbBytes) } }

    /// Bytes of the budgeted part by kind (Settings' storage bar).
    var bytesByKind: [Kind: Int64] {
        lock.withLock {
            indexIfNeeded()
            var out: [Kind: Int64] = [:]
            for (key, e) in entries { out[key.kind, default: 0] += e.bytes }
            return out
        }
    }

    /// Bytes of the budgeted part (everything but the grid thumbnails).
    var cacheBytes: Int64 { lock.withLock { indexIfNeeded(); return total } }

    /// The assets taken in the last weeks; their previews, originals and
    /// videos are evicted last.
    func setRecent(_ ids: Set<String>) { lock.withLock { recent = ids } }

    /// How many bytes the cache may hold now: the budget, less whatever the
    /// device needs back when its free space runs low.
    func target() -> (bytes: Int64, roomy: Bool) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let free = v?.volumeAvailableCapacityForImportantUsage ?? Int64.max
        let capacity = Int64(v?.volumeTotalCapacity ?? 0)
        // keep 5 % of the device free, at least 2 GB and at most 6 GB
        let reserve = min(max(capacity / 20, 2 << 30), 6 << 30)
        let current = cacheBytes
        var bytes = Self.budget
        if free < reserve {
            bytes = min(bytes, max(current - (reserve - free), 256 << 20))
        }
        return (bytes, free > reserve * 2)
    }

    // MARK: Eviction

    /// Trims a little later, once, however many files arrive meanwhile.
    func scheduleTrim() {
        let go: Bool = lock.withLock {
            guard !trimScheduled else { return false }
            trimScheduled = true
            return true
        }
        guard go else { return }
        trimQueue.asyncAfter(deadline: .now() + 2) { [self] in
            lock.withLock { trimScheduled = false }
            trim()
        }
    }

    /// Evicts until the cache fits its target, least valuable first. An
    /// entry's cost of keeping is its idle time × its kind's weight, cut to
    /// a quarter for assets taken recently; entries in use or used in the
    /// last minute (on screen) stay. Shrinks to 90 % of the target, so it
    /// does not run again for every new file.
    func trim() {
        let (limit, _) = target()
        let now = Date()
        let victims: [URL] = lock.withLock {
            indexIfNeeded()
            guard total > limit else { return [] }
            let goal = limit / 10 * 9
            let ranked = entries.filter { k, e in leases[k] == nil && now.timeIntervalSince(e.used) > 60 }
                .map { k, e -> (Key, Double) in
                    let idle = max(now.timeIntervalSince(e.used), 1)
                    return (k, idle * k.kind.weight * (recent.contains(k.id) ? 0.25 : 1))
                }
                .sorted { $0.1 > $1.1 }
            var out: [URL] = []
            for (k, _) in ranked {
                guard total > goal else { break }
                guard let e = entries.removeValue(forKey: k) else { continue }
                total -= e.bytes
                out.append(e.url)
            }
            return out
        }
        guard !victims.isEmpty else { return }
        for url in victims { Self.delete(url) }
        log.info("cache trimmed: \(victims.count) files out, \(self.cacheBytes) bytes left (limit \(limit))")
    }

    // MARK: Index

    /// Reads which grid thumbnails are on disk (once per launch, off the
    /// main thread). Also moves over the files of the old optional offline
    /// cache.
    func loadThumbIndex() async {
        let task = lock.withLock { () -> Task<Void, Never> in
            if let thumbIndexTask { return thumbIndexTask }
            let t = Task.detached(priority: .utility) { [self] in self.scanThumbs() }
            thumbIndexTask = t
            return t
        }
        await task.value
    }

    /// Reads the budgeted part early, so the first lookup does not wait.
    func warmUp() {
        Task.detached(priority: .utility) { [self] in
            _ = cacheBytes
            trim()
        }
    }

    private func scanThumbs() {
        migrateLegacyThumbs()
        let fm = FileManager.default
        var found: Set<String> = []
        var bytes: Int64 = 0
        var shards: Set<String> = []
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        if let e = fm.enumerator(at: thumbDirectory, includingPropertiesForKeys: keys) {
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true { shards.insert(url.lastPathComponent); continue }
                guard url.pathExtension == "webp" else { continue }
                found.insert(url.deletingPathExtension().lastPathComponent)
                bytes += Int64(v?.fileSize ?? 0)
            }
        }
        lock.withLock {
            thumbs.formUnion(found)
            thumbBytes = max(thumbBytes, bytes)
            thumbShards.formUnion(shards)
        }
    }

    /// Lock held. The first lookup reads the directory (about a second for
    /// 15 GB of previews; `warmUp` does it at launch, off the main thread).
    private func indexIfNeeded() {
        guard !indexed else { return }
        indexed = true
        migrateLegacyOriginals()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isDirectoryKey]
        for kind in Kind.allCases where kind != .thumb {
            let root = directory.appendingPathComponent(kind.rawValue, isDirectory: true)
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true { dirs.insert(url.path); continue }
                if url.pathExtension == "vmeta" { continue }
                let key = Key(kind, url.deletingPathExtension().lastPathComponent)
                let entry = Entry(url: url, bytes: Int64(v?.totalFileAllocatedSize ?? 0),
                                  used: v?.contentModificationDate ?? .distantPast)
                entries[key] = entry
                total += entry.bytes
            }
        }
    }

    /// The former "Offline-Cache" kept thumbnails under a mangled URL name in
    /// Application Support/ThumbCache. Its 512s are moved over, the rest
    /// (2048s) is dropped, and the directory goes away.
    private func migrateLegacyThumbs() {
        let fm = FileManager.default
        let legacy = thumbDirectory.deletingLastPathComponent().appendingPathComponent("ThumbCache", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: legacy.path) else { return }
        for name in names {
            // "_v1_assets_<id>_thumb_512_.thmb"
            let parts = name.components(separatedBy: "_")
            if let i = parts.firstIndex(of: "assets"), parts.count > i + 3, parts[i + 2] == "thumb", parts[i + 3] == "512" {
                let id = parts[i + 1]
                try? fm.createDirectory(at: thumbURL(id).deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: legacy.appendingPathComponent(name), to: thumbURL(id))
            }
        }
        try? fm.removeItem(at: legacy)
    }

    /// Lock held. The former original cache ("Application Support/Originals",
    /// "<id>.<o|p>.<ext>", sized by a setting) moves into the budget, and the
    /// URL cache that held face crops goes away.
    private func migrateLegacyOriginals() {
        let fm = FileManager.default
        UserDefaults.standard.removeObject(forKey: "originals.cacheGB")
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: caches.appendingPathComponent("ImageURLCache", isDirectory: true))
        let legacy = thumbDirectory.deletingLastPathComponent().appendingPathComponent("Originals", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: legacy.path) else { return }
        for name in names {
            let parts = name.split(separator: ".")
            guard parts.count >= 2 else { continue }
            let kind: Kind = parts[1] == "p" ? .preview : .original
            let dest = budgetedURL(Key(kind, String(parts[0])), ext: parts.count > 2 ? String(parts[2]) : "bin")
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: legacy.appendingPathComponent(name), to: dest)
        }
        try? fm.removeItem(at: legacy)
    }
}
