import SwiftUI
import QuickLook

/// Files: the drive as the Finder's list view, folder by folder, with the
/// toolbar's back button to go up.
struct MacDriveView: View {
    @Environment(MacWindowState.self) private var window

    var body: some View {
        @Bindable var window = window
        NavigationStack(path: $window.filesPath) {
            MacDriveFolder(folder: nil, title: "Files")
                .navigationDestination(for: DriveCrumb.self) { crumb in
                    MacDriveFolder(folder: crumb.id, title: crumb.name)
                }
        }
    }
}

/// One folder: its folders first, then its files.
private struct MacDriveFolder: View {
    let folder: Int?
    let title: String

    @Environment(AppModel.self) private var model
    @Environment(MacWindowState.self) private var window
    @State private var listing = DriveListing()
    @State private var loaded = false
    @State private var failed = false
    @State private var selection: Set<String> = []
    @State private var sort = [KeyPathComparator(\DriveRow.name, comparator: .localizedStandard)]
    @State private var transfer = DriveTransfer()
    @State private var importing = false
    @State private var naming = false
    @State private var newName = ""
    @State private var renaming: DriveRow?
    @State private var moving: [DriveRow]?
    @State private var deletingFolder: DriveFolder?
    @State private var changeFailed = false
    @State private var dropping = false

    private var client: DriveClient { DriveClient(host: model.library.host) }
    private var rows: [DriveRow] {
        let all = DriveRow.rows(listing).sorted(using: sort)
        // folders first, as the Finder can be set to
        return all.filter(\.isFolder) + all.filter { !$0.isFolder }
    }

    var body: some View {
        // sorted once per update; the table, the overlay and the toolbar share it
        let rows = self.rows
        let selected = rows.filter { selection.contains($0.id) }
        DriveTable(rows: rows, selection: $selection, sort: $sort, transfer: transfer, client: client,
                   open: open, menu: menu)
            .overlay {
                if loaded && rows.isEmpty {
                    ContentUnavailableView("No Files", systemImage: "folder",
                                           description: Text("Drag files here from the Finder, or choose File › Upload Files…"))
                } else if !loaded {
                    if failed { ServerUnavailableView() } else { ProgressView() }
                }
            }
            .overlay(alignment: .bottom) { DriveTransferBar(transfer: transfer) }
            .overlay { if dropping { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3).padding(4) } }
            .dropDestination(for: URL.self) { urls, _ in
                upload(urls)
                return true
            } isTargeted: { dropping = $0 }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("New Folder", systemImage: "folder.badge.plus") { naming = true }
                        .help("New Folder")
                    Button("Upload Files", systemImage: "arrow.up.doc") { importing = true }
                        .help("Upload Files")
                    Button("Delete", systemImage: "trash") { delete(selected) }
                        .help("Move to Deleted Files")
                        .disabled(selected.isEmpty)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { upload(urls) }
            }
            .alert("New Folder", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    newName = ""
                    guard !name.isEmpty else { return }
                    change { try await client.createFolder(parent: folder, name: name) }
                }
                Button("Cancel", role: .cancel) { newName = "" }
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") { rename() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete “\(deletingFolder?.name ?? "")” Permanently?",
                                isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
                                titleVisibility: .visible, presenting: deletingFolder) { f in
                Button("Delete Permanently", role: .destructive) { change { try await client.deleteFolder(f.id) } }
            } message: { f in
                Text("The folder and the \(f.items) files in it will be deleted permanently.")
            }
            .sheet(item: Binding(get: { moving.map { MoveRequest(rows: $0) } }, set: { if $0 == nil { moving = nil } })) { request in
                DriveMoveSheet(client: client, moving: request.rows) { target in
                    let files = request.rows.compactMap { $0.file?.id }
                    let folders = request.rows.compactMap { $0.folder?.id }
                    change { try await client.move(files: files, folders: folders, to: target) }
                }
            }
            .quickLookPreview(Bindable(transfer).preview, in: transfer.previewItems)
            .changeFailedAlert($changeFailed)
            .task { await load() }
            .onAppear { publish() }
            .onChange(of: window.filesPath) { publish() }
    }

    private var subtitle: String {
        let folders = listing.folders.count, files = listing.files.count
        if !selection.isEmpty { return "\(selection.count) of \(folders + files) Selected" }
        guard loaded, folders + files > 0 else { return "" }
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? "1 Folder" : "\(folders) Folders") }
        if files > 0 { parts.append(files == 1 ? "1 File" : "\(files) Files") }
        return parts.joined(separator: ", ")
    }

    /// The File menu's Upload and New Folder act on the folder in front.
    private func publish() {
        let current = window.filesPath.last?.id
        guard current == folder else { return }
        window.upload = { importing = true }
        window.newFolder = { naming = true }
    }

    private func load() async {
        do {
            listing = try await client.list(folder: folder)
            loaded = true
            failed = false
        } catch {
            if !loaded { failed = true }
        }
    }

    private func open(_ row: DriveRow) {
        switch row.item {
        case .folder(let f):
            window.filesPath.append(DriveCrumb(id: f.id, name: f.name))
        case .file(let f):
            transfer.quickLook(f, among: listing.files, client: client)
        }
    }

    private func menu(_ ids: Set<String>) -> [DriveMenuItem] {
        let rows = self.rows.filter { ids.contains($0.id) }
        guard !rows.isEmpty else {
            return [.init("New Folder") { naming = true }, .init("Upload Files…") { importing = true }]
        }
        var items: [DriveMenuItem] = []
        if rows.count == 1 { items.append(.init("Open") { open(rows[0]) }) }
        let files = rows.compactMap(\.file)
        if !files.isEmpty {
            if files.count == 1 { items.append(.init("Quick Look") { transfer.quickLook(files[0], among: listing.files, client: client) }) }
            items.append(.init(files.count == 1 ? "Download" : "Download \(files.count) Files") { transfer.download(files, client: client) })
            items.append(.init("Share…") { transfer.share(files, client: client) })
        }
        items.append(.divider)
        if rows.count == 1 {
            items.append(.init("Rename…") { newName = rows[0].name; renaming = rows[0] })
        }
        items.append(.init("Move to…") { moving = rows })
        items.append(.divider)
        if !files.isEmpty, files.count == rows.count {
            items.append(.init("Move to Deleted Files", destructive: true) { delete(rows) })
        } else if rows.count == 1, let f = rows[0].folder {
            items.append(.init("Delete Folder Permanently…", destructive: true) { deletingFolder = f })
        }
        return items
    }

    private func rename() {
        guard let row = renaming else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != row.name else { return }
        change {
            switch row.item {
            case .file(let f): try await client.renameFile(f.id, to: name)
            case .folder(let f): try await client.renameFolder(f.id, to: name)
            }
        }
    }

    private func delete(_ rows: [DriveRow]) {
        let files = rows.compactMap { $0.file?.id }
        if files.count < rows.count, rows.count == 1, let f = rows[0].folder {
            deletingFolder = f
            return
        }
        guard !files.isEmpty else { return }
        change { try await client.trashFiles(files) }
    }

    private func upload(_ urls: [URL]) {
        Task {
            let failed = await transfer.upload(urls, to: folder, client: client)
            if failed { changeFailed = true }
            await load()
        }
    }

    private func change(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch { changeFailed = true }
            selection = []
            await load()
        }
    }
}

private struct MoveRequest: Identifiable {
    let rows: [DriveRow]
    var id: String { rows.map(\.id).joined(separator: ",") }
}
