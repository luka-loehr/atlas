import AppKit
import UniformTypeIdentifiers

/// A row of a Files table: a folder or a file.
struct DriveRow: Identifiable, Hashable {
    enum Item: Hashable { case folder(DriveFolder), file(DriveFile) }
    let item: Item

    var id: String {
        switch item {
        case .folder(let f): "d\(f.id)"
        case .file(let f): "f\(f.id)"
        }
    }
    var name: String {
        switch item {
        case .folder(let f): f.name
        case .file(let f): f.name
        }
    }
    var size: Int64 {
        switch item {
        case .folder(let f): f.bytes
        case .file(let f): f.size
        }
    }
    var modified: Date {
        if case .file(let f) = item { return f.modifiedAt ?? .distantPast }
        return .distantPast
    }
    var isFolder: Bool { if case .folder = item { true } else { false } }
    var file: DriveFile? { if case .file(let f) = item { f } else { nil } }
    var folder: DriveFolder? { if case .folder(let f) = item { f } else { nil } }

    var type: UTType {
        isFolder ? .folder : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
    }
    /// What the Finder calls it: "PDF document", "Folder".
    var kind: String {
        let text = type.localizedDescription ?? "Document"
        return text.prefix(1).uppercased() + text.dropFirst()
    }
    /// The Finder's own icon for the type.
    var icon: NSImage { NSWorkspace.shared.icon(for: type) }

    static func rows(_ listing: DriveListing) -> [DriveRow] {
        listing.folders.map { DriveRow(item: .folder($0)) } + listing.files.map { DriveRow(item: .file($0)) }
    }
}
