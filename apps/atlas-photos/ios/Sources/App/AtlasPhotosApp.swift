import SwiftUI

@main
struct AtlasPhotosApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @State private var library = Library()
    @AppStorage("photos.host") private var host = "atlas.your-tailnet.ts.net:8788"

    var body: some View {
        TabView {
            Tab("Fotos", systemImage: "photo.on.rectangle.angled") {
                PhotosScreen(library: library)
            }
            Tab("Alben", systemImage: "rectangle.stack") {
                AlbumsScreen(library: library)
            }
            Tab(role: .search) {
                SearchScreen(library: library)
            }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .task {
            library.host = host
            await library.start()
        }
    }
}
