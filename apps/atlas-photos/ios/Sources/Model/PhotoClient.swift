import Foundation

// Payloads from the atlas-photos server.

struct Asset: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let type: String
    let takenAt: Date?
    let width: Int?
    let height: Int?
    let durationS: Double?
    // optional so JSON cached before the server started sending it still decodes
    var favorite: Bool? = nil

    var isVideo: Bool { type == "video" }
    var isFavorite: Bool { favorite ?? false }

    enum CodingKeys: String, CodingKey {
        case id, type, width, height, favorite
        case takenAt = "taken_at"
        case durationS = "duration_s"
    }
}

struct MonthBucket: Codable, Sendable, Identifiable {
    let month: String            // "2024-07"
    let count: Int
    var id: String { month }
}

struct Album: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let title: String
    let count: Int
    let cover: String?
}

struct LibraryStats: Codable, Sendable {
    let total: Int
    let videos: Int
    let bytes: Int64
    let oldest: Date?
    let newest: Date?
    let albums: Int
}

/// Optional bearer-token auth for the atlas-photos server. The token lives in
/// UserDefaults under "photos.token" (set in Einstellungen / Account sheet,
/// "Token (optional)"). Empty (the default) means no auth — matching a server
/// that runs without a token. When set, every request carries
/// "Authorization: Bearer <token>".
enum AtlasAuth {
    static var token: String {
        (UserDefaults.standard.string(forKey: "photos.token") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds the Authorization header when a token is configured.
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

/// Talks to the atlas-photos server over the tailnet.
struct PhotoClient: Sendable {
    var host: String   // e.g. "atlas.your-tailnet.ts.net:8788"

    /// Constructing ISO8601DateFormatter is expensive — hoist it out of the
    /// per-page timeline hot path.
    private static let iso = ISO8601DateFormatter()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "http://\(host)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        AtlasAuth.apply(to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    func stats() async throws -> LibraryStats { try await get("/api/stats") }

    func summary() async throws -> [MonthBucket] {
        struct R: Codable { let months: [MonthBucket] }
        let r: R = try await get("/api/timeline/summary")
        return r.months
    }

    func timeline(before: Date?, limit: Int = 300) async throws -> [Asset] {
        struct R: Codable { let items: [Asset] }
        var path = "/api/timeline?limit=\(limit)"
        if let before {
            let iso = Self.iso.string(from: before)
            path += "&before=\(iso.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? iso)"
        }
        let r: R = try await get(path)
        return r.items
    }

    func albums() async throws -> [Album] {
        struct R: Codable { let albums: [Album] }
        let r: R = try await get("/api/albums")
        return r.albums
    }

    func albumAssets(_ id: Int) async throws -> [Asset] {
        struct R: Codable { let items: [Asset] }
        let r: R = try await get("/api/albums/\(id)/assets")
        return r.items
    }

    struct DayCount: Codable {
        let d: String   // "yyyy-MM-dd"
        let n: Int
    }

    /// GitHub-Style-Aktivität: Fotos pro Tag, letzte ~53 Wochen.
    func heatmap() async throws -> [DayCount] {
        struct R: Codable { let items: [DayCount] }
        let r: R = try await get("/api/heatmap")
        return r.items
    }

    struct SearchResult {
        var persons: [Person] = []
        var items: [Asset] = []
    }

    func search(_ q: String) async throws -> SearchResult {
        struct R: Codable {
            let items: [Asset]
            let persons: [Person]?
        }
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let r: R = try await get("/api/search?q=\(enc)")
        return SearchResult(persons: r.persons ?? [], items: r.items)
    }

    // content-addressed, immutable URLs — safe to cache forever
    func thumbURL(_ id: String, _ size: Int) -> URL? {
        // v2: cache-buster after the ICC-profile fix — thumb URLs are cached
        // immutable, so recolored thumbnails need a new cache identity
        URL(string: "http://\(host)/api/assets/\(id)/thumb/\(size)?v=2")
    }
    func originalURL(_ id: String) -> URL? {
        URL(string: "http://\(host)/api/assets/\(id)/original")
    }
    func streamURL(_ id: String) -> URL? {
        URL(string: "http://\(host)/api/assets/\(id)/stream")
    }
}
