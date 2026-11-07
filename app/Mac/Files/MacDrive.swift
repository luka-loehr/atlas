import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLook

/// A row of a Files table: a folder or a file.
private struct DriveRow: Identifiable, Hashable {
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
    private var selected: [DriveRow] { rows.filter { selection.contains($0.id) } }

    var body: some View {
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
        if !selection.isEmpty { return "\(selection.count) of \(rows.count) Selected" }
        let folders = listing.folders.count, files = listing.files.count
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

/// A context-menu entry of a Files table.
private struct DriveMenuItem: Identifiable {
    let id = UUID()
    let title: String
    var destructive = false
    let run: (() -> Void)?

    init(_ title: String, destructive: Bool = false, _ run: @escaping () -> Void) {
        self.title = title
        self.destructive = destructive
        self.run = run
    }

    private init() { title = ""; run = nil }
    static var divider: DriveMenuItem { DriveMenuItem() }
}

/// The Finder's list view: icon and name, date, size, kind; sortable;
/// Return or a double click opens, Space shows Quick Look; files drag out
/// into the Finder.
private struct DriveTable: View {
    let rows: [DriveRow]
    @Binding var selection: Set<String>
    @Binding var sort: [KeyPathComparator<DriveRow>]
    var transfer: DriveTransfer
    let client: DriveClient
    var showFolder = false
    let open: (DriveRow) -> Void
    let menu: (Set<String>) -> [DriveMenuItem]

    var body: some View {
        Table(of: DriveRow.self, selection: $selection, sortOrder: $sort) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                HStack(spacing: 6) {
                    Image(nsImage: row.icon).resizable().frame(width: 18, height: 18)
                    Text(row.name).lineLimit(1)
                    if transfer.busy.contains(row.id) { ProgressView().controlSize(.mini) }
                }
                .help(row.file?.snippet ?? row.name)
            }
            .width(min: 200, ideal: 340)
            if showFolder {
                TableColumn("Folder") { row in Text(row.file?.folder ?? "").foregroundStyle(.secondary) }
                    .width(min: 80, ideal: 140)
            }
            TableColumn("Date Modified", value: \.modified) { row in
                Text(row.modified == .distantPast ? "--" : row.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Size", value: \.size) { row in
                Text(row.isFolder ? (row.folder.map { $0.items == 1 ? "1 item" : "\($0.items) items" } ?? "--") : row.size.fileSize)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 90)
            TableColumn("Kind") { row in Text(row.kind).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 140)
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    .itemProvider { row.file.map { transfer.dragProvider($0, client: client) } }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            ForEach(menu(ids)) { item in
                if let run = item.run {
                    Button(item.title, role: item.destructive ? .destructive : nil, action: run)
                } else {
                    Divider()
                }
            }
        } primaryAction: { ids in
            for row in rows where ids.contains(row.id) { open(row) }
        }
        .onKeyPress(.space) {
            guard let row = rows.first(where: { selection.contains($0.id) }), let file = row.file else { return .ignored }
            transfer.quickLook(file, among: rows.compactMap(\.file), client: client)
            return .handled
        }
    }
}

// MARK: - Search and Deleted Files

/// Files search: names and the contents of documents.
struct MacDriveSearch: View {
    let query: String
    @Environment(AppModel.self) private var model
    @Environment(MacWindowState.self) private var window
    @State private var results: DriveListing?
    @State private var selection: Set<String> = []
    @State private var sort = [KeyPathComparator(\DriveRow.name, comparator: .localizedStandard)]
    @State private var transfer = DriveTransfer()

    private var client: DriveClient { DriveClient(host: model.library.host) }

    var body: some View {
        NavigationStack {
            DriveTable(rows: results.map { DriveRow.rows($0).sorted(using: sort) } ?? [], selection: $selection, sort: $sort,
                       transfer: transfer, client: client, showFolder: true,
                       open: { row in
                           if let f = row.folder {
                               window.search = ""
                               window.sidebar = .files
                               window.filesPath = [DriveCrumb(id: f.id, name: f.name)]
                           } else if let f = row.file {
                               transfer.quickLook(f, among: results?.files ?? [], client: client)
                           }
                       },
                       menu: { ids in
                           let files = (results?.files ?? []).filter { ids.contains("f\($0.id)") }
                           guard !files.isEmpty else { return [] }
                           return [.init("Quick Look") { transfer.quickLook(files[0], among: files, client: client) },
                                   .init("Download") { transfer.download(files, client: client) },
                                   .init("Share…") { transfer.share(files, client: client) }]
                       })
                .overlay {
                    if let results, results.folders.isEmpty && results.files.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else if results == nil {
                        ProgressView()
                    }
                }
                .quickLookPreview(Bindable(transfer).preview, in: transfer.previewItems)
                .navigationTitle("Search Files")
                .navigationSubtitle("“\(query)”")
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = (try? await client.search(query.trimmingCharacters(in: .whitespaces))) ?? DriveListing()
        }
    }
}

/// Deleted files: recovered or deleted for good.
struct MacDriveTrash: View {
    @Environment(AppModel.self) private var model
    @State private var files: [DriveFile] = []
    @State private var loaded = false
    @State private var selection: Set<Int> = []
    @State private var confirmEmpty = false
    @State private var confirmDelete: [Int]?
    @State private var changeFailed = false

    private var client: DriveClient { DriveClient(host: model.library.host) }

    var body: some View {
        NavigationStack {
            Table(files, selection: $selection) {
                TableColumn("Name") { f in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (f.name as NSString).pathExtension) ?? .data))
                            .resizable().frame(width: 18, height: 18)
                        Text(f.name).lineLimit(1)
                    }
                }
                .width(min: 200, ideal: 360)
                TableColumn("Size") { f in Text(f.size.fileSize).foregroundStyle(.secondary).monospacedDigit() }
                    .width(min: 60, ideal: 90)
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                if !ids.isEmpty {
                    Button("Recover") { change(Array(ids)) { try await client.restore(Array(ids)) } }
                    Button("Delete Permanently…", role: .destructive) { confirmDelete = Array(ids) }
                }
            }
            .overlay {
                if loaded && files.isEmpty {
                    ContentUnavailableView("No Deleted Files", systemImage: "trash")
                } else if !loaded {
                    ProgressView()
                }
            }
            .navigationTitle("Deleted Files")
            .navigationSubtitle(files.isEmpty ? "" : "\(files.count) \(files.count == 1 ? "File" : "Files")")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Recover", systemImage: "arrow.uturn.backward") {
                        change(Array(selection)) { try await client.restore(Array(selection)) }
                    }
                    .help("Recover")
                    .disabled(selection.isEmpty)
                    Button("Empty…") { confirmEmpty = true }
                        .disabled(files.isEmpty)
                }
            }
            .confirmationDialog("Delete All Deleted Files Permanently?", isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    change(files.map(\.id)) { try await client.emptyTrash() }
                }
            } message: {
                Text("All \(files.count) files will be deleted permanently. This can’t be undone.")
            }
            .confirmationDialog("Delete Permanently?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible, presenting: confirmDelete) { ids in
                Button("Delete Permanently", role: .destructive) { change(ids) { try await client.deletePermanent(ids) } }
            } message: { _ in
                Text("This can’t be undone.")
            }
            .changeFailedAlert($changeFailed)
            .task { await load() }
        }
    }

    private func load() async {
        if let fresh = try? await client.trash() { files = fresh }
        loaded = true
    }

    private func change(_ ids: [Int], _ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                let gone = Set(ids)
                withAnimation { files.removeAll { gone.contains($0.id) } }
                selection.subtract(gone)
            } catch {
                changeFailed = true
            }
        }
    }
}

// MARK: - Moving

/// "Move to…": the folder tree, one level at a time.
private struct DriveMoveSheet: View {
    let client: DriveClient
    let moving: [DriveRow]
    let move: (Int?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [DriveCrumb] = []
    @State private var folders: [DriveFolder] = []

    private var movingFolders: Set<Int> { Set(moving.compactMap { $0.folder?.id }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(moving.count == 1 ? "Move “\(moving[0].name)” to:" : "Move \(moving.count) items to:")
                .font(.headline)
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 8)
            HStack(spacing: 4) {
                Button("Files") { path = [] }.buttonStyle(.link)
                ForEach(Array(path.enumerated()), id: \.offset) { i, crumb in
                    Image(systemName: "chevron.forward").font(.caption2).foregroundStyle(.secondary)
                    Button(crumb.name) { path = Array(path.prefix(i + 1)) }.buttonStyle(.link)
                }
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            List(folders.filter { !movingFolders.contains($0.id) }) { f in
                Button { path.append(DriveCrumb(id: f.id, name: f.name)) } label: {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 18, height: 18)
                        Text(f.name)
                        Spacer()
                        Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .padding(.horizontal, 20)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move Here") {
                    move(path.last?.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 440, height: 420)
        .task(id: path) { folders = (try? await client.list(folder: path.last?.id))?.folders ?? [] }
    }
}

// MARK: - Transfers

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
private struct DriveTransferBar: View {
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
