import SwiftUI

// Small views and values both interfaces use.

/// What the app calls the device it runs on, in messages.
enum Device {
    static var name: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
}

/// Shows a person's photos: the Mac's inspector asks the window for it.
struct OpenPersonAction {
    var run: @MainActor (Person) -> Void = { _ in }
    @MainActor func callAsFunction(_ person: Person) { run(person) }
}

extension EnvironmentValues {
    @Entry var openPerson = OpenPersonAction()
}

/// A spinner while a server screen loads; once the request has failed, the
/// same message the other server screens show.
struct LoadingOrUnavailable: View {
    let loaded: Bool
    var body: some View {
        if loaded {
            ServerUnavailableView()
        } else {
            ProgressView()
        }
    }
}

extension View {
    /// A change the server did not take: said, instead of looking as if it
    /// had worked.
    func changeFailedAlert(_ isPresented: Binding<Bool>) -> some View {
        alert("Couldn’t Save Change", isPresented: isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check that atlas is running and this \(Device.name) is on the tailnet.")
        }
    }
}

/// The server could not be reached.
struct ServerUnavailableView: View {
    var body: some View {
        ContentUnavailableView("atlas Unreachable", systemImage: "moon.zzz.fill",
                               description: Text("Check that atlas is running and this \(Device.name) is on the tailnet."))
    }
}

/// Round face-crop avatar with a fallback silhouette.
struct FaceCircle: View {
    var library: Library
    var person: Person

    var body: some View {
        ZStack {
            Circle().fill(Color.placeholderFill)
            if let f = person.coverFace {
                Thumb(url: library.client.faceCropURL(f))
            } else {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(22)
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// The album list as last fetched, so the tab opens complete and refreshes
/// behind it.
@MainActor
enum AlbumsMemo {
    static var albums: [Album] = []
    static var fetchedAt: Date?
}

enum SpecialKind: String, Identifiable, Hashable {
    case favorites, videos, locked, archive, trash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: return "Favorites"
        case .videos:    return "Videos"
        case .locked:    return "Locked"
        case .archive:   return "Archive"
        case .trash:     return "Recently Deleted"
        }
    }
    var icon: String {
        switch self {
        case .favorites: return "heart"
        case .videos:    return "video"
        case .locked:    return "lock"
        case .archive:   return "archivebox"
        case .trash:     return "trash"
        }
    }
}

extension Notification.Name {
    /// Re-tap on the Library tab: show the newest photos.
    static let atlasScrollToNewest = Notification.Name("atlas.scrollToNewest")
}
