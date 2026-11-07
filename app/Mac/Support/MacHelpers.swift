import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// An `NSMenuItem` that runs a closure: the grid's context menu is built
/// from the same actions as the menu bar.
final class BlockMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, symbol: String? = nil, destructive: Bool = false, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if destructive, #available(macOS 26.0, *) {
            // Delete reads as destructive, as SwiftUI's role does
            attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
        }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

extension NSMenu {
    convenience init(_ title: String = "", items: [NSMenuItem]) {
        self.init(title: title)
        // no runs of separators where items were left out
        var last: NSMenuItem?
        for item in items {
            if item.isSeparatorItem, last == nil || last!.isSeparatorItem { continue }
            addItem(item)
            last = item
        }
        if let tail = self.items.last, tail.isSeparatorItem { removeItem(tail) }
    }
}

/// Sharing originals from the Mac: the system's share menu (Mail, Messages,
/// AirDrop, Notes…) for the files, once they are on the Mac.
@MainActor
enum MacShare {
    /// Downloads what is missing, then shows the share menu at the pointer.
    static func share(_ assets: [Asset], client: PhotoClient, busy: @escaping (Bool) -> Void) {
        guard !assets.isEmpty else { return }
        let window = NSApp.keyWindow
        let point = window?.mouseLocationOutsideOfEventStream ?? .zero
        Task {
            let files = await ShareFiles.files(for: assets, client: client) { busy(true) }
            busy(false)
            guard !files.isEmpty, let view = window?.contentView else { return }
            let picker = NSSharingServicePicker(items: files)
            let local = view.convert(point, from: nil)
            picker.show(relativeTo: NSRect(origin: local, size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
        }
    }

    /// Asks for a folder, then copies the originals into it, named as the
    /// share menu names them ("Atlas 2026-09-28 20.56.heic").
    static func export(_ assets: [Asset], client: PhotoClient, busy: @escaping (Bool) -> Void) {
        guard !assets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = assets.count == 1 ? "Choose where to save the original."
            : "Choose where to save the \(assets.count.formatted()) originals."
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor in
                busy(true)
                defer { busy(false) }
                let files = await ShareFiles.files(for: assets, client: client) {}
                let access = folder.startAccessingSecurityScopedResource()
                defer { if access { folder.stopAccessingSecurityScopedResource() } }
                for file in files {
                    var dest = folder.appendingPathComponent(file.lastPathComponent)
                    var n = 2
                    while FileManager.default.fileExists(atPath: dest.path) {
                        dest = folder.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent) \(n).\(file.pathExtension)")
                        n += 1
                    }
                    try? FileManager.default.copyItem(at: file, to: dest)
                }
                NSWorkspace.shared.activateFileViewerSelecting(files.isEmpty ? [folder] : [folder])
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handler) }
        else { handler(panel.runModal()) }
    }
}

/// A small spinner in a rounded box, over the content while something runs.
struct BusyOverlay: View {
    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .transition(.opacity)
    }
}
