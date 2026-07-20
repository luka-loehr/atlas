import SwiftUI
import AVKit

/// Full-screen pager: shows the 1024 thumb instantly (from grid cache, scaled),
/// loads the original over it, pinch-to-zoom, videos play via AVPlayer.
struct ViewerScreen: View {
    var library: Library
    var assets: [Asset]
    var start: Asset

    @State private var index: Int = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(assets.enumerated()), id: \.element.id) { i, asset in
                    ViewerPage(library: library, asset: asset)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    Spacer()
                    if let d = assets[safe: index]?.takenAt {
                        Text(d.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                    Color.clear.frame(width: 38, height: 38)
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                Spacer()
            }
        }
        .statusBarHidden()
        .onAppear { index = assets.firstIndex(of: start) ?? 0 }
    }
}

private struct ViewerPage: View {
    var library: Library
    var asset: Asset

    var body: some View {
        if asset.isVideo {
            VideoPlayerView(url: library.client.streamURL(asset.id))
        } else {
            ZoomableImage(
                preview: library.client.thumbURL(asset.id, 1024),
                full: library.client.originalURL(asset.id)
            )
        }
    }
}

/// Shows the preview immediately, swaps in the full-res original, pinch-zoom.
private struct ZoomableImage: View {
    let preview: URL?
    let full: URL?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            AsyncImage(url: full, transaction: .init(animation: .default)) { phase in
                switch phase {
                case .success(let img):
                    zoomable(img, geo)
                default:
                    Thumb(url: preview)   // instant, cached from the grid
                        .scaledToFit()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func zoomable(_ img: Image, _ geo: GeometryProxy) -> some View {
        img.resizable().scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { scale = max(1, $0) }
                    .onEnded { _ in if scale < 1.05 { withAnimation { scale = 1; offset = .zero } } }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { if scale > 1 { offset = $0.translation } }
                    .onEnded { _ in if scale <= 1 { withAnimation { offset = .zero } } }
            )
            .onTapGesture(count: 2) {
                withAnimation { scale = scale > 1 ? 1 : 2.5; offset = .zero }
            }
    }
}

private struct VideoPlayerView: View {
    let url: URL?
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            guard let url else { return }
            player = AVPlayer(url: url)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
