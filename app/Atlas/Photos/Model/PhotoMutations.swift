import Foundation

// Write-path + curation endpoints of the Atlas server.
// Kept in its own file so PhotoClient.swift stays the read-only surface.

extension PhotoClient {

    // MARK: - Wire helpers

    private static let mutationEncoder = JSONEncoder()

    /// JSON request body: `{"ids":[...]}` and, when set, `"value":Bool`.
    /// `value == nil` is omitted (synthesized `encodeIfPresent`).
    private struct IDsBody: Encodable {
        let ids: [String]
        let value: Bool?
    }

    private struct HashesBody: Encodable {
        let hashes: [String]
    }

    private struct EmptyBody: Encodable {}

    /// Send a JSON body; returns the raw response data. Accepts any 2xx.
    @discardableResult
    func sendRaw<B: Encodable>(_ method: String = "POST", _ path: String, body: B) async throws -> Data {
        guard let url = url(path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        AtlasAuth.apply(to: &req)
        req.httpBody = try Self.mutationEncoder.encode(body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Shared shape for the `{ids, value?}` mutations.
    private func mutate(_ path: String, ids: [String], value: Bool? = nil) async throws {
        try await sendRaw("POST", path, body: IDsBody(ids: ids, value: value))
    }

    // MARK: - Mutations (POST, {"ids":[...], "value"?:Bool})

    func favorite(_ ids: [String], _ value: Bool) async throws {
        try await mutate("/assets/favorite", ids: ids, value: value)
    }

    func archive(_ ids: [String], _ value: Bool) async throws {
        try await mutate("/assets/archive", ids: ids, value: value)
    }

    func trash(_ ids: [String]) async throws {
        try await mutate("/assets/trash", ids: ids)
    }

    func restore(_ ids: [String]) async throws {
        try await mutate("/assets/restore", ids: ids)
    }

    func lock(_ ids: [String], _ value: Bool) async throws {
        try await mutate("/assets/lock", ids: ids, value: value)
    }

    func deletePermanent(_ ids: [String]) async throws {
        try await mutate("/assets/delete", ids: ids)
    }

    func emptyTrash() async throws {
        try await sendRaw("POST", "/library/trash/empty", body: EmptyBody())
    }

    // MARK: - Albums

    private struct TitleBody: Encodable { let title: String }
    private struct AssetIDsBody: Encodable { let ids: [String] }

    /// A title that exists already returns that album (titles are unique).
    func createAlbum(_ title: String) async throws -> Album {
        struct R: Decodable { let id: Int; let title: String }
        let data = try await sendRaw("POST", "/albums", body: TitleBody(title: title))
        let r = try Self.decoder.decode(R.self, from: data)
        return Album(id: r.id, title: r.title, count: 0, cover: nil)
    }

    func renameAlbum(_ id: Int, to title: String) async throws {
        try await sendRaw("PATCH", "/albums/\(id)", body: TitleBody(title: title))
    }

    /// The album only; its photos stay in the library.
    func deleteAlbum(_ id: Int) async throws {
        try await sendRaw("DELETE", "/albums/\(id)", body: EmptyBody())
    }

    func addToAlbum(_ id: Int, _ ids: [String]) async throws {
        try await sendRaw("POST", "/albums/\(id)/assets", body: AssetIDsBody(ids: ids))
    }

    func removeFromAlbum(_ id: Int, _ ids: [String]) async throws {
        try await sendRaw("DELETE", "/albums/\(id)/assets", body: AssetIDsBody(ids: ids))
    }

    // MARK: - Special-album listings

    func listArchive() async throws -> [Asset] { try await collection("/library/archive") }
    func listTrash() async throws -> [Asset] { try await collection("/library/trash") }
    func listLocked() async throws -> [Asset] { try await collection("/library/locked") }

    // MARK: - Dedup probe (POST {"hashes":[...]} → {"have":[...]})

    /// Returns the subset of `hashes` already present on the server.
    func exists(hashes: [String]) async throws -> Set<String> {
        struct R: Codable { let have: [String] }
        let data = try await sendRaw("POST", "/assets/exists", body: HashesBody(hashes: hashes))
        return Set(try Self.decoder.decode(R.self, from: data).have)
    }
}
