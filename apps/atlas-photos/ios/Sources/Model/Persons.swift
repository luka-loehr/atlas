import Foundation

/// A face-clustered person from the pipeline (GET /api/persons).
struct Person: Codable, Sendable, Identifiable, Hashable {
    let id: Int64
    var name: String?
    let coverFace: Int64?
    let photos: Int

    var displayName: String { name ?? "Unbenannt" }

    enum CodingKeys: String, CodingKey {
        case id, name, photos
        case coverFace = "cover_face"
    }
}

extension PhotoClient {
    func persons() async throws -> [Person] {
        struct R: Codable { let items: [Person] }
        guard let url = URL(string: "http://\(host)/api/persons") else {
            throw URLError(.badURL)
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(R.self, from: data).items
    }

    func personAssets(_ id: Int64) async throws -> [Asset] {
        struct R: Codable { let items: [Asset] }
        guard let url = URL(string: "http://\(host)/api/persons/\(id)/assets") else {
            throw URLError(.badURL)
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(R.self, from: data).items
    }

    func renamePerson(_ id: Int64, name: String) async throws {
        guard let url = URL(string: "http://\(host)/api/persons/\(id)/rename") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { let name: String }
        req.httpBody = try JSONEncoder().encode(Body(name: name))
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func faceCropURL(_ faceId: Int64) -> URL? {
        URL(string: "http://\(host)/api/faces/\(faceId)/crop")
    }
}
