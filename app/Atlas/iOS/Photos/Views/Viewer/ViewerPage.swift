import SwiftUI
import UIKit

/// One page of the viewer: a zoomable photo or a video.
struct ViewerPage: View {
    var library: Library
    var asset: Asset
    var chrome: Bool
    var bottomInset: CGFloat = 150
    var onTap: () -> Void

    var body: some View {
        if asset.isVideo {
            ViewerVideo(id: asset.id, url: library.client.streamURL(asset.id),
                        poster: library.client.thumbURL(asset.id, 512),
                        chrome: chrome, bottomInset: bottomInset, onTap: onTap)
        } else {
            ZoomablePhoto(
                thumb: library.client.thumbURL(asset.id, 512),
                preview: library.client.thumbURL(asset.id, 2048),
                full: library.client.originalURL(asset.id),
                previewPixels: MediaCache.viewerPixels(asset),
                onTap: onTap
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(asset.spokenDescription)
            .accessibilityAddTraits(.isImage)
        }
    }
}

/// Shows the 2048 preview at once (the viewer's look-ahead decoded it before
/// the swipe; else the grid's thumbnail first), swaps in the downsampled
/// original, then hosts it in a UIScrollView for zoom. At zoom 1
/// the scroll view doesn't consume drags, so the pager (horizontal) and the
/// zoom-transition dismiss (down) keep working — exactly like Apple Photos.
struct ZoomablePhoto: View {
    let thumb: URL?      // 512, cached from the grid → instant, offline-safe
    let preview: URL?    // 2048
    let full: URL?       // original
    /// The size the preview is decoded at, the same as the look-ahead's.
    var previewPixels: CGFloat
    var onTap: () -> Void = {}
    @State private var image: UIImage?

    init(thumb: URL?, preview: URL?, full: URL?, previewPixels: CGFloat, onTap: @escaping () -> Void = {}) {
        self.thumb = thumb
        self.preview = preview
        self.full = full
        self.previewPixels = previewPixels
        self.onTap = onTap
        // a decoded preview (or the thumbnail) is there in the very first
        // frame of the page, also while it slides in
        let cache = MediaCache.shared
        _image = State(initialValue: preview.flatMap { cache.cached($0, maxPixel: previewPixels) }
                       ?? thumb.flatMap { cache.cached($0) })
    }

    var body: some View {
        Group {
            if let image {
                ZoomableScrollView(image: { image }, onSingleTap: onTap)
            } else {
                Thumb(url: thumb)
                    .aspectRatio(contentMode: .fit)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap() }
            }
        }
        .task(id: full) {
            // 1) the grid's 512 thumb is already cached → show the photo (blurry)
            //    INSTANTLY instead of a grey wait, even on bad internet / offline
            if image == nil, let t = thumb {
                if let c = MediaCache.shared.cached(t) { image = c }
                else if let img = await MediaCache.shared.load(t), image == nil { image = img }
            }
            // 2) sharpen to the 2048 preview
            if let p = preview {
                if let c = MediaCache.shared.cached(p, maxPixel: previewPixels) {
                    if image !== c { image = c }
                } else if let img = await MediaCache.shared.load(p, maxPixel: previewPixels) {
                    image = img
                }
            }
            // full quality ONLY when the user actually settles on this photo:
            // while scrubbing through the strip each page lives < 600ms, its
            // task gets cancelled here and no original is ever downloaded
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            if let f = full, let img = await MediaCache.shared.loadFull(f, maxPixel: 2800) {
                image = img
            }
        }
    }
}

/// UIScrollView-backed pinch/pan/double-tap zoom for one image.
/// Single tap (only fires when the double-tap fails) toggles the chrome.
struct ZoomableScrollView: UIViewRepresentable {
    let image: UIImage
    var onSingleTap: () -> Void = {}
    init(image: () -> UIImage, onSingleTap: @escaping () -> Void = {}) {
        self.image = image()
        self.onSingleTap = onSingleTap
    }

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

        let st = UITapGestureRecognizer(target: context.coordinator,
                                        action: #selector(Coordinator.singleTap(_:)))
        st.numberOfTapsRequired = 1
        st.require(toFail: dt)
        scroll.addGestureRecognizer(st)

        context.coordinator.onSingleTap = onSingleTap
        // at zoom 1 the photo's own pan stays out of the way: the pager (left,
        // right) and swipe-to-close (down) get every drag at once
        scroll.panGestureRecognizer.isEnabled = false
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        // the chrome toggling re-renders every page; only a new image is news
        if context.coordinator.imageView.image !== image { context.coordinator.imageView.image = image }
        context.coordinator.onSingleTap = onSingleTap
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        var onSingleTap: () -> Void = {}

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // panning around only makes sense while zoomed in
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > 1.01
        }

        @objc func singleTap(_ g: UITapGestureRecognizer) { onSingleTap() }

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
