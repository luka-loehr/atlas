import SwiftUI

/// Which photos a browser shows.
enum PhotoSource: Hashable {
    case library
    case special(SpecialKind)
    case album(Album)
    case person(Person)
    case search(String)
}

/// What an empty browser says, by what it shows.
struct PhotoSourceEmpty: View {
    let source: PhotoSource
    /// The server answered the last time the library asked.
    let online: Bool

    var body: some View {
        switch source {
        case .library:
            if !online {
                ServerUnavailableView()
            } else {
                ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                       description: Text("Photos backed up from your iPhone appear here."))
            }
        case .special(.favorites):
            ContentUnavailableView("No Favorites", systemImage: "heart",
                                   description: Text("Press . on a photo, or choose Image › Favorite, to add it here."))
        case .special(.videos): ContentUnavailableView("No Videos", systemImage: "video")
        case .special(.trash): ContentUnavailableView("No Recently Deleted Items", systemImage: "trash")
        case .special(.archive): ContentUnavailableView("No Archived Items", systemImage: "archivebox")
        case .special(.locked): ContentUnavailableView("No Locked Items", systemImage: "lock")
        case .album:
            ContentUnavailableView("No Photos", systemImage: "rectangle.stack",
                                   description: Text("Drag photos from the library onto the album in the sidebar, or choose Image › Add to Album."))
        case .person: ContentUnavailableView("No Photos", systemImage: "person.crop.square")
        case .search(let q): ContentUnavailableView.search(text: q)
        }
    }
}
