import SwiftUI

struct AlbumsScreen: View {
    var library: Library
    @State private var albums: [Album] = []
    @State private var loaded = false

    private let cols = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 18) {
                        ForEach(albums) { album in
                            NavigationLink {
                                AlbumScreen(library: library, album: album)
                            } label: {
                                AlbumCard(library: library, album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    if albums.isEmpty && loaded {
                        Text("keine Alben")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.top, 60)
                    }
                }
                .scrollIndicators(.hidden)
                .refreshable { await load() }
            }
            .navigationTitle("Alben")
            .toolbarBackground(.black, for: .navigationBar)
        }
        .task { await load() }
    }

    private func load() async {
        albums = (try? await library.client.albums()) ?? []
        loaded = true
    }
}

struct AlbumCard: View {
    var library: Library
    var album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Thumb(url: album.cover.flatMap { library.client.thumbURL($0, 256) })
                .aspectRatio(1, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(album.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(album.count)")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// One album's photos (reuses the grid + viewer).
struct AlbumScreen: View {
    var library: Library
    var album: Album
    @State private var assets: [Asset] = []
    @State private var pick: Asset?
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                LazyVGrid(columns: cols, spacing: 2) {
                    ForEach(assets) { asset in
                        Color.clear.aspectRatio(1, contentMode: .fill)
                            .overlay { Thumb(url: library.client.thumbURL(asset.id, 256)).clipped() }
                            .clipped()
                            .onTapGesture { pick = asset }
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { assets = (try? await library.client.albumAssets(album.id)) ?? [] }
        .fullScreenCover(item: $pick) { a in
            ViewerScreen(library: library, assets: assets, start: a)
        }
    }
}
