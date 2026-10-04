import Foundation

// Payloads from the Atlas server.

struct Asset: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let type: String
    let takenAt: Date?
    let width: Int?
    let height: Int?
    let durationS: Double?
    // optional so cached JSON without the key still decodes
    var favorite: Bool? = nil

    var isVideo: Bool { type == "video" }
    var isFavorite: Bool { favorite ?? false }

    enum CodingKeys: String, CodingKey {
        case id, type, width, height, favorite
        case takenAt = "taken_at"
        case durationS = "duration_s"
    }
}

/// An asset list as the server sends it: one array per field, index-aligned.
/// A third the size of an array of objects, and it compresses far better.
struct AssetColumns: Codable, Sendable {
    var id: [String] = []
    /// wall-clock seconds where the photo was taken, encoded as UTC; 0 = undated
    var t: [Int] = []
    var w: [Int] = []
    var h: [Int] = []
    var v: [Int] = []
    var d: [Double] = []
    var f: [Int] = []

    /// The app shows times with the device calendar, so the wall clock the
    /// server sends is turned into the instant that reads the same here: a
    /// photo taken at 18:00 in Bangkok shows 18:00, wherever the phone is.
    var assets: [Asset] {
        let zone = TimeZone.current
        return id.indices.map { i in
            let wall = TimeInterval(t[i])
            let taken: Date? = t[i] > 0
                ? Date(timeIntervalSince1970: wall - TimeInterval(zone.secondsFromGMT(for: Date(timeIntervalSince1970: wall))))
                : nil
            return Asset(id: id[i], type: v[i] == 1 ? "video" : "photo", takenAt: taken,
                         width: w[i] > 0 ? w[i] : nil, height: h[i] > 0 ? h[i] : nil,
                         durationS: v[i] == 1 ? d[i] : nil, favorite: f[i] == 1)
        }
    }
}

struct Album: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let title: String
    let count: Int
    let cover: String?
}

/// Bearer-token auth for the Atlas server. The token lives in the keychain
/// (see `Session`); it is mirrored here once so the thousands of thumbnail
/// requests of a scroll do not each go to the keychain.
enum AtlasAuth {
    nonisolated(unsafe) static var token = ""

    /// Adds the Authorization header.
    static func apply(to req: inout URLRequest) {
        let t = token
        guard !t.isEmpty else { return }
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
    }

    /// Ready-made GET request for direct URLSession downloads.
    static func request(_ url: URL, timeoutInterval: TimeInterval = 60) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeoutInterval)
        apply(to: &req)
        return req
    }

    /// AVURLAsset options carrying the header (video streaming).
    static var avAssetOptions: [String: Any] {
        let t = token
        guard !t.isEmpty else { return [:] }
        return ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Bearer \(t)"]]
    }
}

/// Talks to the Atlas server over the tailnet.
struct PhotoClient: Sendable {
    /// Server base URL, e.g. "http://atlas.your-tailnet.ts.net:8787".
    var host: String

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func url(_ path: String) -> URL? { URL(string: "\(host)/v1\(path)") }

    func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = url(path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        AtlasAuth.apply(to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    // MARK: Timeline (month buckets)

    /// One month of the timeline as the index names it. `etag` changes exactly
    /// when the month's content does, so an unchanged month is never fetched
    /// twice.
    struct TimelineBucket: Codable, Sendable, Equatable {
        let key: String          // "2024-07", or "undated"
        let count: Int
        let etag: String
    }

    /// Every month with its count, newest first: the full shape of the
    /// library in one small response.
    func timelineIndex() async throws -> [TimelineBucket] {
        struct R: Codable { let buckets: [TimelineBucket] }
        let r: R = try await get("/timeline")
        return r.buckets
    }

    /// The assets of one month, newest first.
    func timelineBucket(_ key: String) async throws -> AssetColumns {
        try await get("/timeline/\(key)")
    }

    func albums() async throws -> [Album] {
        struct R: Codable { let albums: [Album] }
        let r: R = try await get("/albums")
        return r.albums
    }

    private struct Collection: Codable { let assets: AssetColumns }

    func albumAssets(_ id: Int) async throws -> [Asset] {
        let r: Collection = try await get("/albums/\(id)")
        return r.assets.assets
    }

    func collection(_ path: String) async throws -> [Asset] {
        let r: Collection = try await get(path)
        return r.assets.assets
    }

    struct SearchResult {
        var persons: [Person] = []
        var items: [Asset] = []
        /// false when the model worker is down and only names, places and
        /// albums were searched
        var semantic = true
    }

    func search(_ q: String) async throws -> SearchResult {
        struct R: Codable {
            let assets: AssetColumns
            let people: [Person]?
            let semantic: String?
        }
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(.init(charactersIn: "&+="))) ?? q
        let r: R = try await get("/search?q=\(enc)")
        return SearchResult(persons: r.people ?? [], items: r.assets.assets, semantic: r.semantic != "unavailable")
    }

    // content-addressed, immutable URLs — safe to cache forever
    func thumbURL(_ id: String, _ size: Int) -> URL? { url("/assets/\(id)/thumb/\(size)") }
    func originalURL(_ id: String) -> URL? { url("/assets/\(id)/original") }
    /// The streaming rendition where the server made one, else the original.
    func streamURL(_ id: String) -> URL? { url("/assets/\(id)/video") }
}
