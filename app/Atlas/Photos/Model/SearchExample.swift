import Foundation

/// The search field's example, made from the library itself: its two most
/// photographed people, its most photographed place and this year
/// ("Alex and Sam, Lyon 2026…"). An invented one only while the library has
/// none of those yet.
enum SearchExample {
    static let placeholder = "Alex and Sam, beach, Spain 2024…"

    static func make(client: PhotoClient) async -> String {
        async let people = try? client.persons()
        async let places = try? client.topPlaceName()
        let names = (await people ?? [])
            .filter { !$0.isPet && $0.name?.isEmpty == false }
            .sorted { $0.photos > $1.photos }
            .prefix(2)
            .compactMap(\.name)
        let place = await places
        guard !names.isEmpty || place != nil else { return placeholder }
        var parts: [String] = []
        if !names.isEmpty { parts.append(names.joined(separator: " and ")) }
        let year = String(Calendar.current.component(.year, from: .now))
        parts.append([place, year].compactMap { $0 }.joined(separator: " "))
        return parts.joined(separator: ", ") + "…"
    }
}

extension PhotoClient {
    /// The name of the most photographed place, if any photo has one.
    func topPlaceName() async throws -> String? {
        struct Place: Decodable { let name: String? }
        struct R: Decodable { let places: [Place] }
        let r: R = try await get("/places")
        return r.places.lazy.compactMap(\.name).first { !$0.isEmpty }
    }
}
