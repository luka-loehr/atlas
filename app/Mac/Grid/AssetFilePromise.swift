import AppKit
import UniformTypeIdentifiers

// MARK: - Dragging out

/// A photo dragged out of the grid: its original, written where it is
/// dropped (the Finder, Mail, …) once downloaded, and its id for drops onto
/// an album in the sidebar.
final class AssetFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    static let idType = NSPasteboard.PasteboardType(UTType.atlasAssetIDs.identifier)

    let asset: Asset
    let client: PhotoClient

    init(asset: Asset, client: PhotoClient) {
        self.asset = asset
        self.client = client
        super.init()
        fileType = (asset.isVideo ? UTType.movie : UTType.image).identifier
        delegate = self
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [Self.idType] + super.writableTypes(for: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == Self.idType ? asset.id : super.pasteboardPropertyList(forType: type)
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == Self.idType ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        let base = ShareFiles.name(asset, people: [])
        return "\(base).\(asset.isVideo ? "mov" : "jpg")"
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let asset = asset, client = client
        Task {
            guard let source = client.originalURL(asset.id) else { completionHandler(URLError(.badURL)); return }
            do {
                let file = try await MediaFetch.shared.file(.init(.original, asset.id), from: source, priority: .visible)
                // the real extension, once the original is here (HEIC, PNG, MP4…)
                let ext = file.pathExtension.lowercased()
                var dest = url
                if !ext.isEmpty, ext != "bin", ext != url.pathExtension.lowercased() {
                    dest = url.deletingPathExtension().appendingPathExtension(ext)
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: file, to: dest)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }
}

extension UTType {
    /// Photos dragged within Atlas (onto an album): their ids.
    static let atlasAssetIDs = UTType(exportedAs: "com.lukaloehr.atlas.asset-id")
}
