import SwiftUI

/// What the sidebar can show. Hashable and Codable, so the window restores
/// where it was (`SceneStorage`).
enum SidebarItem: Hashable, Codable {
    case library
    case people
    case special(SpecialKind)
    case album(Int)
    case files
    case filesTrash
    case sharedLinks
    case server

    var title: String {
        switch self {
        case .library: "Library"
        case .people: "People"
        case .special(let kind): kind.title
        case .album: "Album"
        case .files: "Files"
        case .filesTrash: "Deleted Files"
        case .sharedLinks: "Shared Links"
        case .server: "Server"
        }
    }

    var symbol: String {
        switch self {
        case .library: "photo.on.rectangle.angled"
        case .people: "person.crop.square"
        case .special(let kind): kind.icon
        case .album: "rectangle.stack"
        case .files: "folder"
        case .filesTrash: "trash"
        case .sharedLinks: "link"
        case .server: "server.rack"
        }
    }

    /// Searching from here searches files, everywhere else photos.
    var searchesFiles: Bool { self == .files || self == .filesTrash }
}

extension SpecialKind: Codable {}

/// One window's state: what it shows, its zoom and its inspector. Every
/// window has its own, so two windows can show two albums.
@MainActor @Observable
final class MacWindowState {
    var sidebar: SidebarItem? = .library
    var search = ""
    var showInspector = false
    /// Whether the sidebar shows. Collapsed, the window's buttons (close,
    /// minimize, zoom, the sidebar toggle) sit over the photos' top left.
    var columns: NavigationSplitViewVisibility = .all
    /// What floats at the photos' top left keeps clear of those buttons.
    var topLeadingClearance: CGFloat { columns == .detailOnly ? 150 : 0 }
    /// The photo the inspector describes: the viewer's, or the one photo
    /// selected in a grid.
    var inspected: Asset?
    /// Grid density, 0 (smallest) ... `GridZoom.sizes.count - 1`.
    var zoom = GridZoom.standard

    /// The People column's navigation: a person opened from the inspector
    /// lands here.
    var peoplePath: [Person] = []
    /// The Files column's navigation, folder by folder.
    var filesPath: [DriveCrumb] = []
    /// What the File menu's Upload and New Folder do in the folder shown.
    var upload: (() -> Void)?
    var newFolder: (() -> Void)?

    func open(_ person: Person) {
        search = ""
        sidebar = .people
        peoplePath = [person]
    }

    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    func zoomIn() { zoom = min(zoom + 1, GridZoom.sizes.count - 1) }
    func zoomOut() { zoom = max(zoom - 1, 0) }
}

/// The grid's cell sizes, in points: from a contact sheet to large tiles.
enum GridZoom {
    static let sizes: [CGFloat] = [56, 84, 120, 170, 240, 340]
    static let standard = 2
}

/// What the menu bar's Image menu acts on: the photos selected in the key
/// window, or the one its viewer shows. Published by the view that owns
/// the selection (`focusedSceneValue`), so the menu follows the key window.
struct PhotoActions {
    var count: Int
    /// Every one of them is a favorite: the item reads Unfavorite.
    var allFavorite: Bool
    var open: (() -> Void)?
    var toggleFavorite: (() -> Void)?
    var addToAlbum: (() -> Void)?
    var removeFromAlbum: (() -> Void)?
    var shareLink: (() -> Void)?
    var share: (() -> Void)?
    var export: (() -> Void)?
    var archive: (() -> Void)?
    var lock: (() -> Void)?
    /// Unarchive, Unlock, Recover: back to the library.
    var restore: (title: String, run: () -> Void)?
    var delete: (() -> Void)?
}

/// The commands of the window in front, for the View and Go menus.
struct WindowActions {
    var state: MacWindowState
    var newAlbum: () -> Void
    var upload: (() -> Void)?
    var newFolder: (() -> Void)?
    var refresh: () -> Void
    /// Edit › Find: into the toolbar's search field.
    var find: () -> Void = {}
}

extension FocusedValues {
    @Entry var photoActions: PhotoActions?
    @Entry var windowActions: WindowActions?
}
