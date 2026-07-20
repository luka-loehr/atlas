import SwiftUI

struct AlbumsScreen: View {
    var library: Library
    @State private var albums: [Album] = []
    @State private var loaded = false
    @State private var openAlbum: Album?
    @State private var authing = false

    private let cols = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 18) {
                        ForEach(albums) { album in
                            let locked = SpecialAlbum.isLocked(album.title)
                            Button {
                                open(album, locked: locked)
                            } label: {
                                AlbumCard(library: library, album: album, locked: locked)
                            }
                            .buttonStyle(.plain)
                            .disabled(authing)
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
            .navigationDestination(item: $openAlbum) { album in
                AlbumScreen(library: library, album: album)
            }
        }
        .task { await load() }
    }

    private func open(_ album: Album, locked: Bool) {
        guard locked else { openAlbum = album; return }
        authing = true
        Task {
            let ok = await Biometric.authenticate(reason: "Gesperrten Ordner entsperren")
            authing = false
            if ok { openAlbum = album }
        }
    }

    private func load() async {
        albums = (try? await library.client.albums()) ?? []
        loaded = true
    }
}

struct AlbumCard: View {
    var library: Library
    var album: Album
    var locked: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)     // square, fits column width
                .overlay {
                    if locked {
                        ZStack {
                            Rectangle().fill(Color.white.opacity(0.06))
                            Image(systemName: "lock.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    } else {
                        Thumb(url: album.cover.flatMap { library.client.thumbURL($0, 256) })
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 5) {
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                Text(album.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
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
