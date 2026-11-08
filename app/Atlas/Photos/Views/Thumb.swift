import SwiftUI

/// A thumbnail that shows at once from memory, else appears when loaded.
/// `maxPixel` downsamples the decode (longest side).
struct Thumb: View {
    let url: URL?
    var maxPixel: CGFloat? = nil
    // the inner view looks the cache up when it is made; behind this one
    // that happens only when the URL changes, not on every parent update
    var body: some View { ThumbInner(url: url, maxPixel: maxPixel) }
}

private struct ThumbInner: View {
    let url: URL?
    var maxPixel: CGFloat?
    @State private var image: PlatformImage?

    init(url: URL?, maxPixel: CGFloat?) {
        self.url = url
        self.maxPixel = maxPixel
        // a cached image is there in the very first frame, no grey flash
        _image = State(initialValue: url.flatMap { MediaCache.shared.cached($0, maxPixel: maxPixel) })
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.placeholderFill)
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .task(id: url) {
            guard let url else { return }
            if let c = MediaCache.shared.cached(url, maxPixel: maxPixel) {
                if image !== c { image = c }
                return
            }
            image = await MediaCache.shared.load(url, maxPixel: maxPixel)
        }
    }
}
