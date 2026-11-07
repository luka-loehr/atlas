import Foundation

/// A face-clustered person, or a pet, from the model worker
/// (GET /v1/people).
struct Person: Codable, Sendable, Identifiable, Hashable {
    let id: Int64
    var name: String?
    let coverFace: Int64?
    let photos: Int
    /// "person", or a pet's species ("dog", "cat", "horse", "bird")
    var kind: String = "person"

    var isPet: Bool { kind != "person" }
    var displayName: String { name ?? (isPet ? "Unnamed \(kind.capitalized)" : "Unnamed") }

    enum CodingKeys: String, CodingKey {
        case id, name, photos, kind
        case coverFace = "cover_face"
    }

    init(id: Int64, name: String?, coverFace: Int64?, photos: Int, kind: String = "person") {
        self.id = id
        self.name = name
        self.coverFace = coverFace
        self.photos = photos
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        coverFace = try c.decodeIfPresent(Int64.self, forKey: .coverFace)
        photos = try c.decode(Int.self, forKey: .photos)
        // servers before 0.5 send no kind: everyone is a person
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "person"
    }
}

/// The last people list the server sent (the cache warmer fetches it at
/// launch), so the People views show their faces in the first frame and
/// refresh behind it.
@MainActor
enum PeopleMemo {
    static var people: [Person] = []
}

/// One detected face on an asset, resolved to its person.
struct AssetFace: Codable, Sendable, Identifiable, Hashable {
    let face: Int64
    let person: Int64
    let name: String?
    var kind: String? = nil

    var id: Int64 { face }
    var isPet: Bool { (kind ?? "person") != "person" }
    var displayName: String { name ?? (isPet ? "Unnamed \((kind ?? "").capitalized)" : "Unnamed") }

    enum CodingKeys: String, CodingKey {
        case face, name, kind
        case person = "id"
    }
}

extension PhotoClient {
    /// People and pets; the hidden ones instead with `hidden`.
    func persons(hidden: Bool = false) async throws -> [Person] {
        struct R: Codable { let people: [Person] }
        let r: R = try await get(hidden ? "/people?hidden=true" : "/people")
        return r.people
    }

    /// Out of People, search and the info panel (or back).
    func setPersonHidden(_ id: Int64, _ hidden: Bool) async throws {
        struct Body: Encodable { let hidden: Bool }
        try await sendRaw("PATCH", "/people/\(id)", body: Body(hidden: hidden))
    }

    /// Hides the unnamed people in these photos (a group photo of
    /// strangers); named people stay.
    func hideFaces(inAssets ids: [String]) async throws {
        struct Body: Encodable { let assets: [String] }
        try await sendRaw("POST", "/faces/hide", body: Body(assets: ids))
    }

    func personAssets(_ id: Int64) async throws -> [Asset] {
        try await collection("/people/\(id)")
    }

    func renamePerson(_ id: Int64, name: String) async throws {
        struct Body: Encodable { let name: String }
        try await sendRaw("PATCH", "/people/\(id)", body: Body(name: name))
    }

    /// Make one concrete face crop the person's avatar everywhere.
    func setPersonCover(_ personId: Int64, faceId: Int64) async throws {
        struct Body: Encodable { let cover_face: Int64 }
        try await sendRaw("PATCH", "/people/\(personId)", body: Body(cover_face: faceId))
    }

    func faceCropURL(_ faceId: Int64) -> URL? { url("/faces/\(faceId)/crop") }
}
