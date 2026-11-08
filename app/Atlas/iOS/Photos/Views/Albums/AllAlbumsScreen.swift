import SwiftUI

/// Every album as a two-column grid ("See All").
struct AllAlbumsScreen: View {
    var library: Library
    var albums: [Album]
    @State private var open: Album?

    private let cols = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, alignment: .leading, spacing: 20) {
                ForEach(albums) { album in
                    Button { open = album } label: { AlbumTile(library: library, album: album) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("My Albums")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $open) { album in
            AlbumScreen(library: library, album: album)
        }
    }
}
