import Foundation

/// A face-clustered person from the model worker (GET /v1/people).
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

/// One detected face on an asset, resolved to its person.
struct AssetFace: Codable, Sendable, Identifiable, Hashable {
    let face: Int64
    let person: Int64
    let name: String?

    var id: Int64 { face }
    var displayName: String { name ?? "Unbenannt" }

    enum CodingKeys: String, CodingKey {
        case face, name
        case person = "id"
    }
}

extension PhotoClient {
    func persons() async throws -> [Person] {
        struct R: Codable { let people: [Person] }
        let r: R = try await get("/people")
        return r.people
    }

    func personAssets(_ id: Int64) async throws -> [Asset] {
        try await collection("/people/\(id)")
    }

    func renamePerson(_ id: Int64, name: String) async throws {
        struct Body: Encodable { let name: String }
        try await sendRaw("PATCH", "/people/\(id)", body: Body(name: name))
    }

    /// The faces on one asset come with the asset's detail.
    func assetFaces(_ assetId: String) async throws -> [AssetFace] {
        struct R: Codable { let people: [AssetFace] }
        let r: R = try await get("/assets/\(assetId)")
        return r.people
    }

    /// Make one concrete face crop the person's avatar everywhere.
    func setPersonCover(_ personId: Int64, faceId: Int64) async throws {
        struct Body: Encodable { let cover_face: Int64 }
        try await sendRaw("PATCH", "/people/\(personId)", body: Body(cover_face: faceId))
    }

    func faceCropURL(_ faceId: Int64) -> URL? { url("/faces/\(faceId)/crop") }
}
