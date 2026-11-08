import Foundation
import ImageIO

/// Decoding, always off the main thread: one bounded queue, one ImageIO
/// pass that decodes, downsamples and orients.
extension MediaCache {
    nonisolated static func onDecodeQueue(_ priority: Operation.QueuePriority = .normal,
                                          _ work: @escaping @Sendable () -> PlatformImage?) async -> PlatformImage? {
        if Task.isCancelled { return nil }
        return await withCheckedContinuation { cont in
            let op = BlockOperation { cont.resume(returning: work()) }
            op.queuePriority = priority
            decodeQueue.addOperation(op)
        }
    }

    nonisolated static func decode(file: URL, maxPixel: CGFloat?, fill: Bool) -> PlatformImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(file as CFURL, opts) else { return nil }
        return decode(src, maxPixel: maxPixel, fill: fill)
    }

    nonisolated static func decode(data: Data, maxPixel: CGFloat?, fill: Bool) -> PlatformImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        return decode(src, maxPixel: maxPixel, fill: fill)
    }

    /// One pass: ImageIO decodes and downsamples together, applies the
    /// orientation, and the result is a finished bitmap, so nothing decodes
    /// at render time. `fill`: `maxPixel` is the SHORT side (an aspect-fill
    /// square cell), else the long side.
    nonisolated static func decode(_ src: CGImageSource, maxPixel: CGFloat?, fill: Bool) -> PlatformImage? {
        guard CGImageSourceGetCount(src) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let long = max(w, h), short = max(min(w, h), 1)
        var target = long > 0 ? long : 4096
        if let maxPixel {
            target = fill ? min(long, (maxPixel * long / short).rounded(.up)) : min(long, maxPixel)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target, 1),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return PlatformImage(cgImage: cg).preparedForDisplay()
    }
}
