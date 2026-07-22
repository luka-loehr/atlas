import Foundation

// Write-path + curation endpoints for the atlas-photos server.
// Kept in its own file so PhotoClient.swift stays the read-only surface.
// These helpers are self-contained (own decoder/encoder + POST/GET helpers)
// and do not depend on PhotoClient's file-private members.

extension PhotoClient {

    // MARK: - Wire helpers

    private static let mutationDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

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

    /// POST a JSON body; returns the raw response data. Accepts any 2xx.
    @discardableResult
    private func postRaw<B: Encodable>(_ path: String, body: B) async throws -> Data {
        guard let url = URL(string: "http://\(host)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
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

    /// GET a JSON payload (mirrors PhotoClient.get, private to this file).
    private func fetch<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "http://\(host)\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        AtlasAuth.apply(to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try Self.mutationDecoder.decode(T.self, from: data)
    }

    /// Shared shape for the `{ids, value?}` mutations.
    private func mutate(_ path: String, ids: [String], value: Bool? = nil) async throws {
        try await postRaw(path, body: IDsBody(ids: ids, value: value))
    }

    // MARK: - Mutations (POST, {"ids":[...], "value"?:Bool})

    func favorite(_ ids: [String], _ value: Bool) async throws {
        try await mutate("/api/mutate/favorite", ids: ids, value: value)
    }

    func archive(_ ids: [String], _ value: Bool) async throws {
        try await mutate("/api/mutate/archive", ids: ids, value: value)
    }

    func trash(_ ids: [String]) async throws {
        try await mutate("/api/mutate/trash", ids: ids)
    }

    func restore(_ ids: [String]) async throws {
        try await mutate("/api/mutate/restore", ids: ids)
    }

    func lock(_ ids: [String], _ value: Bool) async throws {
        try await mutate("/api/mutate/lock", ids: ids, value: value)
    }

    func deletePermanent(_ ids: [String]) async throws {
        try await mutate("/api/mutate/delete", ids: ids)
    }

    func emptyTrash() async throws {
        try await postRaw("/api/trash/empty", body: EmptyBody())
    }

    // MARK: - Special-album listings (GET → {"items":[Asset]})

    func listArchive() async throws -> [Asset] {
        struct R: Codable { let items: [Asset] }
        let r: R = try await fetch("/api/archive")
        return r.items
    }

    func listTrash() async throws -> [Asset] {
        struct R: Codable { let items: [Asset] }
        let r: R = try await fetch("/api/trash")
        return r.items
    }

    func listLocked() async throws -> [Asset] {
        struct R: Codable { let items: [Asset] }
        let r: R = try await fetch("/api/locked")
        return r.items
    }

    // MARK: - Dedup probe (POST {"hashes":[...]} → {"have":[...]})

    /// Returns the subset of `hashes` already present on the server.
    func exists(hashes: [String]) async throws -> Set<String> {
        struct R: Codable { let have: [String] }
        let data = try await postRaw("/api/exists", body: HashesBody(hashes: hashes))
        let r = try Self.mutationDecoder.decode(R.self, from: data)
        return Set(r.have)
    }

    // MARK: - Upload (POST /api/upload, raw body + headers)

    /// Uploads one asset's bytes. `hash` is the SHA-256 content id the server
    /// keys on; `takenAt` (unix seconds) is sent only when known.
    func upload(data: Data, filename: String, takenAt: Date?, hash: String) async throws {
        guard let url = URL(string: "http://\(host)/api/upload") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        AtlasAuth.apply(to: &req)
        req.setValue(filename, forHTTPHeaderField: "X-Filename")
        req.setValue(hash, forHTTPHeaderField: "X-Content-Hash")
        if let takenAt {
            req.setValue(String(Int(takenAt.timeIntervalSince1970)), forHTTPHeaderField: "X-Taken-At")
        }
        req.httpBody = data
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
