import AppIntents
import WidgetKit

/// An album the Album widget can show, as the widget's picker lists it:
/// "Recent Photos", then the albums the app last saw on the server.
struct AlbumEntity: AppEntity {
    /// `WidgetData.recents` or "album:<id>".
    let id: String
    let title: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Album"
    static let defaultQuery = AlbumQuery()
    static let recents = AlbumEntity(id: WidgetData.recents, title: "Recent Photos")

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct AlbumQuery: EntityQuery {
    func entities(for identifiers: [AlbumEntity.ID]) async throws -> [AlbumEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AlbumEntity] { all() }

    func defaultResult() async -> AlbumEntity? { .recents }

    private func all() -> [AlbumEntity] {
        let albums = WidgetData.read()?.albums ?? []
        return [.recents] + albums.map { AlbumEntity(id: WidgetData.setKey(album: $0.id), title: $0.title) }
    }
}

/// The Album widget's configuration: which album it shows.
struct AlbumWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Album"
    static let description = IntentDescription("Shows photos from an album you choose.")

    @Parameter(title: "Album")
    var album: AlbumEntity?

    init() {}

    init(album: AlbumEntity?) { self.album = album }
}
