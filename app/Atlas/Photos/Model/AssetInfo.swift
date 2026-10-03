import Foundation

/// Full per-asset detail for the info sheet — GET /v1/assets/{id}.
/// `exif` carries the capture parameters the server's metadata stage
/// extracted.
struct AssetInfo: Decodable {
    var id: String
    var takenAt: Date?
    var origName: String?
    var camera: String?
    var width: Int?
    var height: Int?
    var sizeBytes: Int64?
    var lat: Double?
    var lon: Double?
    var place: String?
    var favorite: Bool?
    var durationS: Double?
    var tags: [String]?
    var exif: ExifBits?

    struct ExifBits: Codable {
        var iso: Int?
        var fNumber: Double?
        var exposureTime: String?    // "1/888"
        var focalLen: Double?        // mm
        var lens: String?

        enum CodingKeys: String, CodingKey {
            case iso
            case fNumber = "f_number"
            case exposureTime = "exposure_time"
            case focalLen = "focal_len"
            case lens
        }
    }

    private struct PlaceBits: Decodable {
        var name: String?
        var region: String?
    }

    enum CodingKeys: String, CodingKey {
        case id
        case takenAt = "taken_at"
        case origName = "name"
        case camera, width, height
        case sizeBytes = "size"
        case lat, lon, place, favorite
        case durationS = "duration"
        case tags, exif
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        takenAt = try c.decodeIfPresent(Date.self, forKey: .takenAt)
        origName = try c.decodeIfPresent(String.self, forKey: .origName)
        camera = try c.decodeIfPresent(String.self, forKey: .camera)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lon = try c.decodeIfPresent(Double.self, forKey: .lon)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite)
        durationS = try c.decodeIfPresent(Double.self, forKey: .durationS)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        exif = try c.decodeIfPresent(ExifBits.self, forKey: .exif)
        // the server sends the place as its parts; the sheet shows one line
        if let p = try c.decodeIfPresent(PlaceBits.self, forKey: .place) {
            place = [p.name, p.region].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            if place?.isEmpty == true { place = nil }
        }
    }
}

extension PhotoClient {
    /// Detail payload for the viewer info sheet.
    func assetInfo(_ id: String) async throws -> AssetInfo {
        try await get("/assets/\(id)")
    }
}
