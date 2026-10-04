import Foundation

/// What the app hands the Album widget, in the App Group container: a small
/// manifest and downsampled JPEGs. The widget reads only this, so it never
/// needs the network or the token.
///
///   Widget/manifest.json   the albums (for the picker) and the photo sets
///   Widget/p-<id>.jpg      a photo of a set, about 1000 px on its short side
///   Widget/c-<id>.jpg      an album cover, shown until its set is there
enum WidgetData {
    static let group = "group.com.lukaloehr.Atlas"
    static let kind = "AlbumWidget"
    /// The set of the newest photos, for a widget with no album chosen.
    static let recents = "recents"

    static func setKey(album id: Int) -> String { "album:\(id)" }
    static func albumID(of key: String) -> Int? {
        key.hasPrefix("album:") ? Int(key.dropFirst(6)) : nil
    }

    struct Manifest: Codable, Equatable {
        var albums: [AlbumInfo] = []
        /// Photo sets by key ("recents", "album:<id>"), in showing order.
        var sets: [String: [Photo]] = [:]
    }

    struct AlbumInfo: Codable, Equatable, Hashable {
        let id: Int
        let title: String
        let count: Int
        /// The cover's file in the folder, once staged.
        var cover: String?
    }

    struct Photo: Codable, Equatable, Hashable {
        let id: String
        let file: String
        let taken: Date?
    }

    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Widget", isDirectory: true)
    }

    static func file(_ name: String) -> URL? { folder?.appendingPathComponent(name) }

    static func read() -> Manifest? {
        guard let url = file("manifest.json"), let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(Manifest.self, from: data)
    }

    static func write(_ manifest: Manifest) throws {
        guard let folder, let url = file("manifest.json") else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        try e.encode(manifest).write(to: url, options: .atomic)
    }
}
