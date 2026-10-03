import Foundation

/// The "dynamic original cache": originals and 2048 previews that were viewed
/// (or just taken on this iPhone) stay on the phone up to the size chosen in
/// Einstellungen, least recently used first out. The viewer opens a local
/// copy without touching the network.
///
/// Thread-safe; meant to be called from background tasks (the first call
/// reads the directory).
final class OriginalCache: @unchecked Sendable {
    static let shared = OriginalCache()

    enum Kind: String, Sendable { case original = "o", preview = "p" }

    /// UserDefaults key of the limit in GB; 0 = off.
    static let limitKey = "originals.cacheGB"
    static let choices = [0, 1, 5, 10, 25, 50]
    static let defaultGB = 5

    static var limitGB: Int {
        UserDefaults.standard.object(forKey: limitKey) as? Int ?? defaultGB
    }

    private struct Entry {
        var url: URL
        var bytes: Int64
        var used: Date
    }

    let directory: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var total: Int64 = 0
    private var indexed = false

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Originals", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func key(_ id: String, _ kind: Kind) -> String { "\(id).\(kind.rawValue)" }

    /// Lock held.
    private func indexIfNeeded() {
        guard !indexed else { return }
        indexed = true
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        for url in files {
            // "<id>.<kind>.<ext>"
            let parts = url.lastPathComponent.split(separator: ".")
            guard parts.count >= 2 else { continue }
            let v = try? url.resourceValues(forKeys: Set(keys))
            let e = Entry(url: url, bytes: Int64(v?.fileSize ?? 0), used: v?.contentModificationDate ?? .distantPast)
            entries["\(parts[0]).\(parts[1])"] = e
            total += e.bytes
        }
    }

    /// The local file, if there is one; marks it as just used.
    func file(_ id: String, _ kind: Kind) -> URL? {
        let hit: URL? = lock.withLock {
            indexIfNeeded()
            let k = Self.key(id, kind)
            guard var e = entries[k] else { return nil }
            e.used = Date()
            entries[k] = e
            return e.url
        }
        if let hit {
            // keep the LRU order across launches
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: hit.path)
        }
        return hit
    }

    /// Takes a downloaded (or just exported) file into the cache by moving it.
    /// Returns where it lives now, or nil when the cache is off (the file is
    /// then left where it was).
    @discardableResult
    func adopt(_ file: URL, id: String, kind: Kind, ext: String) -> URL? {
        let limit = Int64(Self.limitGB) << 30
        guard limit > 0 else { return nil }
        let clean = ext.isEmpty ? "bin" : ext.lowercased()
        let dest = directory.appendingPathComponent("\(id).\(kind.rawValue).\(clean)")
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        do { try fm.moveItem(at: file, to: dest) } catch { return nil }
        let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        lock.withLock {
            indexIfNeeded()
            let k = Self.key(id, kind)
            if let old = entries[k] {
                total -= old.bytes
                if old.url != dest { try? fm.removeItem(at: old.url) }
            }
            entries[k] = Entry(url: dest, bytes: size, used: Date())
            total += size
        }
        trim()
        return dest
    }

    /// Bytes the cache holds now.
    var usage: Int64 { lock.withLock { indexIfNeeded(); return total } }

    /// Evicts least recently used files until the cache fits its limit.
    func trim() {
        let limit = Int64(Self.limitGB) << 30
        let victims: [URL] = lock.withLock {
            indexIfNeeded()
            guard total > limit else { return [] }
            var out: [URL] = []
            for (k, e) in entries.sorted(by: { $0.value.used < $1.value.used }) {
                guard total > limit else { break }
                entries[k] = nil
                total -= e.bytes
                out.append(e.url)
            }
            return out
        }
        for url in victims { try? FileManager.default.removeItem(at: url) }
    }

    func clear() {
        let all: [URL] = lock.withLock {
            indexIfNeeded()
            let urls = entries.values.map(\.url)
            entries = [:]
            total = 0
            return urls
        }
        for url in all { try? FileManager.default.removeItem(at: url) }
    }
}
