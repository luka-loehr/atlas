import SwiftUI
import UIKit

/// Two-tier cache for thumbnails: decoded images in RAM (instant re-scroll),
/// bytes on disk via URLCache (immutable URLs = never invalidated). Backed by
/// a shared URLSession with a generous cache.
@MainActor
final class ThumbLoader {
    static let shared = ThumbLoader()

    private let ram = NSCache<NSURL, UIImage>()
    private let session: URLSession

    private init() {
        ram.countLimit = 800
        let cache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 2 << 30, directory: nil)
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = cache
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)
    }

    func cached(_ url: URL) -> UIImage? { ram.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let img = ram.object(forKey: url as NSURL) { return img }
        do {
            let (data, _) = try await session.data(from: url)
            guard let img = UIImage(data: data) else { return nil }
            ram.setObject(img, forKey: url as NSURL, cost: data.count)
            return img
        } catch {
            return nil
        }
    }
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
        .task(id: url) {
            guard let url else { return }
            if let c = ThumbLoader.shared.cached(url) { image = c; return }
            image = await ThumbLoader.shared.load(url)
        }
    }
}
