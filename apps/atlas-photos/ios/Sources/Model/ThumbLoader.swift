import SwiftUI
import UIKit
import ImageIO

/// Two-tier cache for images: decoded bitmaps in RAM (instant re-scroll), bytes
/// on disk via URLCache (immutable URLs = never invalidated). Both the network
/// fetch AND the decode happen off the main thread — a lazily-decoded UIImage
/// would otherwise decode on the main thread at render time and stall scrolling
/// / the full-screen pager (that was the "swipe blocks while the photo loads"
/// bug). Full-screen images are downsampled to a zoom-sufficient size so the
/// main thread never touches a 40-megapixel bitmap.
@MainActor
final class ThumbLoader {
    static let shared = ThumbLoader()

    private let ram = NSCache<NSURL, UIImage>()
    private let session: URLSession

    private init() {
        ram.countLimit = 500
        ram.totalCostLimit = 320 << 20        // ~320 MB of decoded pixels
        let cache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 2 << 30, directory: nil)
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = cache
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)
    }

    func cached(_ url: URL) -> UIImage? { ram.object(forKey: url as NSURL) }

    /// Grid thumbnails: fetched and fully decoded off-main.
    func load(_ url: URL) async -> UIImage? { await fetch(url, maxPixel: nil) }

    /// Full-screen viewer image: downsampled to `maxPixel` and decoded off-main
    /// so paging between photos never blocks on a huge main-thread decode.
    func loadFull(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        await fetch(url, maxPixel: maxPixel)
    }

    private func fetch(_ url: URL, maxPixel: CGFloat?) async -> UIImage? {
        let key = url as NSURL
        if let img = ram.object(forKey: key) { return img }
        guard let data = try? await session.data(from: url).0 else { return nil }
        let img = await Task.detached(priority: .userInitiated) {
            Self.decode(data, maxPixel: maxPixel)
        }.value
        guard let img else { return nil }
        ram.setObject(img, forKey: key, cost: img.decodedCost)
        return img
    }

    /// Off-main decode. With `maxPixel`, ImageIO decodes + downsamples in one
    /// pass (`ShouldCacheImmediately` forces the decode now); otherwise the small
    /// thumb is prepared for display so nothing decodes at render time.
    nonisolated private static func decode(_ data: Data, maxPixel: CGFloat?) -> UIImage? {
        if let maxPixel {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            if let src = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                return UIImage(cgImage: cg)
            }
        }
        return UIImage(data: data)?.preparingForDisplay()
    }
}

private extension UIImage {
    /// Approx decoded byte cost for NSCache accounting.
    var decodedCost: Int { (cgImage?.bytesPerRow ?? 0) * (cgImage?.height ?? 0) }
}

/// A thumbnail cell that shows instantly from cache, else fades in on load.
struct Thumb: View {
    let url: URL?
    var body: some View {
        ThumbInner(url: url)
    }
}

private struct ThumbInner: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.06))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipped()   // scaledToFill must never bleed past the cell
        .contentShape(Rectangle())
        .task(id: url) {
            guard let url else { return }
            if let c = ThumbLoader.shared.cached(url) { image = c; return }
            image = await ThumbLoader.shared.load(url)
        }
    }
}
