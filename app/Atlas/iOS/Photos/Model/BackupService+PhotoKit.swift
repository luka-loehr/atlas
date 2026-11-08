import Foundation
import Photos
import CryptoKit
import UIKit

/// PhotoKit and file helpers of the backup: which assets there are, their
/// original resource, its hash and size, an export of its bytes.
extension BackupService {
    nonisolated static func fetchAssets(_ localIds: [String]) -> [PHAsset] {
        guard !localIds.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIds, options: nil)
        var out: [PHAsset] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in out.append(asset) }
        return out
    }

    /// The untouched original resource whose bytes define the atlas id.
    nonisolated static func primaryResource(_ asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let order: [PHAssetResourceType] = asset.mediaType == .video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
        for type in order {
            if let match = resources.first(where: { $0.type == type }) { return match }
        }
        return resources.first
    }

    nonisolated static func hashAll(_ ids: [String], limit: Int) async -> [(String, String)] {
        let assets = fetchAssets(ids)
        return await withTaskGroup(of: (String, String)?.self) { group in
            var it = assets.makeIterator()
            func next() {
                guard let a = it.next() else { return }
                group.addTask {
                    guard let r = primaryResource(a), let h = try? await sha256Hex(of: r) else { return nil }
                    return (a.localIdentifier, h)
                }
            }
            for _ in 0..<limit { next() }
            var out: [(String, String)] = []
            for await r in group {
                if let r { out.append(r) }
                next()
            }
            return out
        }
    }

    /// SHA-256 (lowercase hex) of the resource's exact bytes, streamed;
    /// iCloud originals are fetched on demand.
    nonisolated static func sha256Hex(of resource: PHAssetResource) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            var hasher = SHA256()
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().requestData(for: resource, options: opts,
                dataReceivedHandler: { hasher.update(data: $0) },
                completionHandler: { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: hasher.finalize().map { String(format: "%02x", $0) }.joined()) }
                })
        }
    }

    /// SHA-256 (lowercase hex) of a file, read in 4 MB pieces.
    nonisolated static func sha256Hex(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the exact original bytes to `url`.
    nonisolated static func exportOriginal(_ resource: PHAssetResource, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: opts) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: ()) }
            }
        }
    }

    nonisolated static func localThumb(_ asset: PHAsset, side: CGFloat) async -> UIImage? {
        await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFill, options: o) { img, info in
                // degraded first images are not delivered in this mode; guard anyway
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                cont.resume(returning: img)
            }
        }
    }

    /// PhotoKit has no public byte count; the resources' fileSize (KVC) is
    /// close enough for a status line.
    nonisolated static func estimatedBytes(_ assets: [PHAsset]) -> Int64 {
        assets.compactMap(primaryResource).reduce(0) { $0 + fileSize($1) }
    }

    nonisolated static func fileSize(_ resource: PHAssetResource) -> Int64 {
        if let n = resource.value(forKey: "fileSize") as? Int64 { return n }
        if let n = resource.value(forKey: "fileSize") as? Int { return Int64(n) }
        return 0
    }
}
