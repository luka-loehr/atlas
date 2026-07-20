import SwiftUI
import UIKit
import AVKit

/// Full-screen pager: shows the 1024 thumb instantly (from grid cache, scaled),
/// loads the original over it, pinch-to-zoom, videos play via AVPlayer.
/// Presented as a zoom transition from the tapped thumbnail; swipe DOWN to
/// dismiss (no close button — like Apple Photos).
struct ViewerScreen: View {
    var library: Library
    var assets: [Asset]
    var start: Asset

    @State private var index: Int = 0

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(assets.enumerated()), id: \.element.id) { i, asset in
                    ViewerPage(library: library, asset: asset)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // date only — the zoom transition handles swipe-down-to-close
            if let d = assets[safe: index]?.takenAt {
                Text(d.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 8)
            }
        }
        .statusBarHidden()
        .onAppear {
            index = assets.firstIndex(of: start) ?? 0
            prefetchNeighbors(of: index)
        }
        .onChange(of: index) { _, new in prefetchNeighbors(of: new) }
    }

    /// Warms the 2048 previews of the neighboring pages (±1..3, nearest first)
    /// so the next swipe shows a sharp image instantly.
    private func prefetchNeighbors(of i: Int) {
        var urls: [URL] = []
        for offset in 1...3 {
            for j in [i + offset, i - offset] {
                guard let a = assets[safe: j], !a.isVideo,
                      let u = library.client.thumbURL(a.id, 2048) else { continue }
                urls.append(u)
            }
        }
        ThumbLoader.shared.prefetch(urls)
    }
}

private struct ViewerPage: View {
    var library: Library
    var asset: Asset

    var body: some View {
        if asset.isVideo {
            VideoPlayerView(url: library.client.streamURL(asset.id))
        } else {
            ZoomablePhoto(
                preview: library.client.thumbURL(asset.id, 2048),
                full: library.client.originalURL(asset.id)
            )
        }
    }
}

/// Loads the 1024 preview instantly (cached from the grid), swaps in the
/// full-res original, then hosts it in a UIScrollView for zoom. At zoom 1 the
/// scroll view doesn't consume drags, so the pager (horizontal) and the
/// zoom-transition dismiss (down) keep working — exactly like Apple Photos.
private struct ZoomablePhoto: View {
    let preview: URL?
    let full: URL?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableScrollView { image }
            } else {
                Thumb(url: preview)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .task(id: full) {
            // instant: the small 1024 preview (decoded off-main, quick)
            if image == nil, let p = preview, let img = await ThumbLoader.shared.load(p) {
                if image == nil { image = img }
            }
            // then the original, downsampled + decoded off-main so the swipe
            // between photos never stalls on a full-resolution main-thread decode
            if let f = full, let img = await ThumbLoader.shared.loadFull(f, maxPixel: 2800) {
                image = img
            }
        }
    }
}

/// UIScrollView-backed pinch/pan/double-tap zoom for one image.
private struct ZoomableScrollView: UIViewRepresentable {
    let image: UIImage
    init(image: () -> UIImage) { self.image = image() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 5
        scroll.minimumZoomScale = 1
        scroll.bounces = false                     // don't eat drags at zoom 1
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = false
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never

        let iv = context.coordinator.imageView
        iv.image = image
        iv.contentMode = .scaleAspectFit
        iv.frame = scroll.bounds
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(iv)

        let dt = UITapGestureRecognizer(target: context.coordinator,
                                        action: #selector(Coordinator.doubleTap(_:)))
        dt.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(dt)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let pt = g.location(in: imageView)
                let size = scroll.bounds.size
                let rect = CGRect(x: pt.x - size.width / 6, y: pt.y - size.height / 6,
                                  width: size.width / 3, height: size.height / 3)
                scroll.zoom(to: rect, animated: true)
            }
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
            // play sound even with the ringer/Focus on silent (like Photos/YouTube)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = AVPlayer(url: url)
            p.isMuted = false
            player = p
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
