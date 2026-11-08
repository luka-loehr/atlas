import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Downloads, uploads, Quick Look and drags of one Files view.
@MainActor @Observable
final class DriveTransfer {
    var busy: Set<String> = []
    var uploading: (done: Int, total: Int)?
    var preview: URL?
    var previewItems: [URL] = []

    func quickLook(_ file: DriveFile, among files: [DriveFile], client: DriveClient) {
        run(file) { url in
            self.previewItems = [url]
            self.preview = url
        }
    }

    /// Into Downloads, then shown in the Finder.
    func download(_ files: [DriveFile], client: DriveClient) {
        Task {
            var saved: [URL] = []
            for file in files {
                busy.insert("f\(file.id)")
                defer { busy.remove("f\(file.id)") }
                guard let tmp = try? await client.download(file),
                      let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { continue }
                var dest = downloads.appendingPathComponent(file.name)
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    let base = (file.name as NSString).deletingPathExtension, ext = (file.name as NSString).pathExtension
                    dest = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                    n += 1
                }
                if (try? FileManager.default.copyItem(at: tmp, to: dest)) != nil { saved.append(dest) }
            }
            if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
        }
    }

    func share(_ files: [DriveFile], client: DriveClient) {
        let window = NSApp.keyWindow
        let point = window?.mouseLocationOutsideOfEventStream ?? .zero
        Task {
            var urls: [URL] = []
            for file in files {
                busy.insert("f\(file.id)")
                if let url = try? await client.download(file) { urls.append(url) }
                busy.remove("f\(file.id)")
            }
            guard !urls.isEmpty, let view = window?.contentView else { return }
            let picker = NSSharingServicePicker(items: urls)
            picker.show(relativeTo: NSRect(origin: view.convert(point, from: nil), size: CGSize(width: 1, height: 1)),
                        of: view, preferredEdge: .minY)
        }
    }

    /// Uploads one after another; true if any failed.
    func upload(_ urls: [URL], to folder: Int?, client: DriveClient) async -> Bool {
        guard !urls.isEmpty else { return false }
        uploading = (0, urls.count)
        defer { uploading = nil }
        var failed = false
        for (i, url) in urls.enumerated() {
            uploading = (i, urls.count)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { failed = true; continue }
            do { try await client.upload(file: url, name: url.lastPathComponent, folder: folder) } catch { failed = true }
        }
        return failed
    }

    /// A file dragged into the Finder: downloaded when it is dropped.
    func dragProvider(_ file: DriveFile, client: DriveClient) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.name
        let type = UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            let task = Task {
                do { done(try await client.download(file), false, nil) } catch { done(nil, false, error) }
            }
            let progress = Progress(totalUnitCount: 1)
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }

    private func run(_ file: DriveFile, _ then: @escaping (URL) -> Void) {
        let key = "f\(file.id)"
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            if let url = try? await DriveClient(host: AppModel.shared.library.host).download(file) { then(url) }
        }
    }
}

/// "Uploading 2 of 5…" at the bottom of the table while files go up.
struct DriveTransferBar: View {
    var transfer: DriveTransfer

    var body: some View {
        if let up = transfer.uploading {
            HStack(spacing: 10) {
                ProgressView(value: Double(up.done), total: Double(max(up.total, 1))).frame(width: 140)
                Text("Uploading \(min(up.done + 1, up.total)) of \(up.total)…")
                    .font(.callout)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
