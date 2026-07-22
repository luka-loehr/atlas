import Foundation

/// Full per-asset detail for the info sheet — GET /api/assets/{id}/info.
/// `exif` carries the interesting capture parameters the pipeline's meta
/// worker extracted (subset of exiftool JSON, lowercase keys).
struct AssetInfo: Codable {
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

    enum CodingKeys: String, CodingKey {
        case id
        case takenAt = "taken_at"
        case origName = "orig_name"
        case camera, width, height
        case sizeBytes = "size_bytes"
        case lat, lon, place, favorite
        case durationS = "duration_s"
        case tags, exif
    }
}

extension PhotoClient {
    /// Detail payload for the viewer info sheet.
    func assetInfo(_ id: String) async throws -> AssetInfo {
        guard let url = URL(string: "http://\(host)/api/assets/\(id)/info") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        AtlasAuth.apply(to: &req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(AssetInfo.self, from: data)
    }

}
