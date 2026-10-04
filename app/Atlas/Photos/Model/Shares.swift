import Foundation

/// A link to photos on atlas-share (GET /v1/shares). atlas uploads the files
/// on its own; the link can be handed out at once (it says "almost ready"
/// until they are there). An album has one link, which follows the album.
struct Share: Codable, Sendable, Identifiable, Hashable {
    enum State: String, Codable, Sendable { case uploading, ready, failed }

    let id: String
    let title: String
    let url: URL
    let createdAt: Date
    let expiresAt: Date
    let state: State
    let doneBytes: Int64
    let totalBytes: Int64
    let count: Int
    let cover: String?
    let albumID: Int?
    let allowDownload: Bool
    let hasPassword: Bool
    let error: String?
    /// The link's password, kept on atlas while the link lives.
    var password: String? = nil
    /// The link opens (atlas has finished at least one upload).
    var live: Bool? = nil

    /// 0…1, or nil while the total is not known yet.
    var progress: Double? {
        totalBytes > 0 ? min(Double(doneBytes) / Double(totalBytes), 1) : nil
    }

    enum CodingKeys: String, CodingKey {
        case id, title, url, state, count, cover, error, password, live
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case doneBytes = "done_bytes"
        case totalBytes = "total_bytes"
        case albumID = "album_id"
        case allowDownload = "allow_download"
        case hasPassword = "has_password"
    }
}

enum ShareError: Error {
    /// 503: atlas-share is not configured on the server.
    case notSetUp
}

extension PhotoClient {

    /// Whether the server has atlas-share set up (`sharing` of GET /v1/server).
    func sharingAvailable() async throws -> Bool {
        struct R: Decodable { let sharing: Bool? }
        let r: R = try await get("/server")
        return r.sharing ?? false
    }

    /// Live shares, newest first.
    func shares() async throws -> [Share] {
        struct R: Decodable { let shares: [Share] }
        let r: R = try await get("/shares")
        return r.shares
    }

    func share(_ id: String) async throws -> Share {
        try await get("/shares/\(id)")
    }

    private struct NewShare: Encodable {
        let title: String
        let ids: [String]?
        let album: Int?
        let days: Int
        let allow_download: Bool
        let password: String?
    }

    /// Photos by id or a whole album; the server answers at once with the
    /// share `uploading` and keeps going on its own. An album that has a
    /// link already gets that one back.
    func createShare(title: String, ids: [String]? = nil, album: Int? = nil, days: Int = 7,
                     allowDownload: Bool = false, password: String? = nil) async throws -> Share {
        guard let url = url("/shares") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        AtlasAuth.apply(to: &req)
        req.httpBody = try JSONEncoder().encode(NewShare(title: title, ids: ids, album: album, days: days,
                                                         allow_download: allowDownload, password: password))
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 503 { throw ShareError.notSetUp }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try Self.decoder.decode(Share.self, from: data)
    }

    /// The files leave atlas-share and the link stops working.
    func stopSharing(_ id: String) async throws {
        struct Empty: Encodable {}
        try await sendRaw("DELETE", "/shares/\(id)", body: Empty())
    }
}
