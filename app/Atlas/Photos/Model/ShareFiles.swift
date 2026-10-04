import Foundation

/// What Share hands to the share sheet: the originals, named after when the
/// photo was taken and who is on it ("Atlas 2026-09-28 20.56.heic",
/// "Atlas – Mia 2026-09-28 20.56.heic"), not after their content hashes.
@MainActor
enum ShareFiles {
    /// The named people of each asset (GET /v1/assets/{id}), asked for while
    /// the photo is on screen or its menu is open, so Share does not wait.
    private static var people: [String: [String]] = [:]
    private static var asking: [String: Task<[String]?, Never>] = [:]

    /// The photo is on screen (or its context menu is open): its people are
    /// looked up now, its original is on the way (`MediaCache`).
    static func prepare(_ asset: Asset, client: PhotoClient) {
        _ = lookup(asset.id, client)
    }

    private static func lookup(_ id: String, _ client: PhotoClient) -> Task<[String]?, Never>? {
        if people[id] != nil { return nil }
        if let t = asking[id] { return t }
        let t = Task<[String]?, Never> {
            guard let info = try? await client.assetInfo(id) else { return nil }
            var seen = Set<String>()
            return info.people.compactMap(\.name).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        asking[id] = t
        Task {
            let names = await t.value
            asking[id] = nil
            if people.count > 4000 { people.removeAll() }
            if let names { people[id] = names }
        }
        return t
    }

    /// The local files for `assets`, in their order. `waiting` runs when
    /// something has to come from the server first (at once when an original
    /// is missing), so progress shows only when it is real.
    static func files(for assets: [Asset], client: PhotoClient, waiting: @escaping () -> Void) async -> [URL] {
        let ids = assets.map(\.id)
        let local = await Task.detached(priority: .userInitiated) {
            ids.allSatisfy { MediaStore.shared.contains(.init(.original, $0)) }
        }.value
        let progress = Task {
            if local { try? await Task.sleep(for: .milliseconds(400)) }
            if !Task.isCancelled { waiting() }
        }
        defer { progress.cancel() }

        // names: whatever is known, the rest asked for now, for a moment
        let pending = ids.compactMap { id in lookup(id, client).map { (id, $0) } }
        if !pending.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                group.addTask { for (_, t) in pending { _ = await t.value } }
                await group.next()
                group.cancelAll()
            }
        }
        var names: [String] = []
        var used: [String: Int] = [:]
        for a in assets {
            let base = name(a, people: people[a.id] ?? [])
            let n = (used[base] ?? 0) + 1
            used[base] = n
            names.append(n == 1 ? base : "\(base) \(n)")
        }

        let folder = await Task.detached(priority: .userInitiated) { freshFolder() }.value
        guard let folder else { return [] }
        let jobs = assets.enumerated().compactMap { i, a in client.originalURL(a.id).map { (i, a.id, $0, a.isVideo) } }
        let files = await withTaskGroup(of: (Int, URL?).self) { group in
            for (i, id, url, video) in jobs {
                let name = names[i]
                group.addTask {
                    (i, await MediaCache.shared.shareableOriginal(id, from: url, named: name, in: folder, video: video))
                }
            }
            var out: [Int: URL] = [:]
            for await (i, url) in group { out[i] = url }
            return out
        }
        return files.sorted { $0.key < $1.key }.map(\.value)
    }

    /// "Atlas 2026-09-28 20.56", "Atlas – Mia 2026-09-28 20.56",
    /// "Atlas – Mia & Ben …", "Atlas – Mia, Ben & Lea …".
    static func name(_ asset: Asset, people: [String]) -> String {
        var parts = ["Atlas"]
        let who = people.prefix(3).map(safe).filter { !$0.isEmpty }
        if !who.isEmpty {
            let list = who.count == 1 ? who[0] : who.dropLast().joined(separator: ", ") + " & " + who.last!
            parts = ["Atlas –", list]
        }
        if let taken = asset.takenAt { parts.append(stamp.string(from: taken)) }
        return parts.joined(separator: " ")
    }

    /// The device's calendar and zone, as the app shows times everywhere.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()

    /// No path separators, colons or other characters file systems or
    /// receiving apps trip over; at most 40 characters.
    private static func safe(_ text: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        let cleaned = text.unicodeScalars.map { bad.contains($0) ? " " : String($0) }.joined()
            .split(separator: " ").joined(separator: " ")
        return String(cleaned.prefix(40)).trimmingCharacters(in: .whitespaces)
    }

    /// A new folder for one share, so names never clash with an earlier
    /// one; folders of shares over an hour old are removed.
    nonisolated private static func freshFolder() -> URL? {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
        let old = Date().addingTimeInterval(-3600)
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let made = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if made < old { try? fm.removeItem(at: dir) }
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }
        return folder
    }
}
