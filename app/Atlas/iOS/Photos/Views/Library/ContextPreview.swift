import SwiftUI

/// The large preview of the context menu: the cached grid thumbnail at once,
/// the sharp 2048 version over it as soon as it is there.
struct ContextPreview: View {
    let asset: Asset
    let client: PhotoClient
    @State private var sharp: UIImage?

    private var size: CGSize { Self.size(for: asset) }

    static func size(for asset: Asset) -> CGSize {
        let ratio = CGFloat(asset.width ?? 1) / CGFloat(max(asset.height ?? 1, 1))
        let maxW: CGFloat = 360, maxH: CGFloat = 480
        return ratio >= maxW / maxH ? CGSize(width: maxW, height: maxW / ratio)
                                    : CGSize(width: maxH * ratio, height: maxH)
    }

    var body: some View {
        ZStack {
            Thumb(url: client.thumbURL(asset.id, 512))
            if let sharp {
                Image(uiImage: sharp).resizable().scaledToFill()
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task {
            guard let url = client.thumbURL(asset.id, 2048) else { return }
            sharp = await MediaCache.shared.loadFull(url, maxPixel: 1400)
        }
    }
}
