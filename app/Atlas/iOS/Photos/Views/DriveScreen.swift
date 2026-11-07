import SwiftUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - Dateien tab (drive)

/// Der Google-Drive-Teil der Atlas-Photos-App: Ordnerbaum + Dateien vom atlas
/// (content-addressed Blobs). Root trägt Suche + Papierkorb; jede Ebene kann
/// hochladen, anlegen, umbenennen, verschieben, löschen.
struct DriveScreen: View {
    var library: Library
    /// The search tab opened from Dateien: the root becomes a file search.
    var searchMode = false

    var body: some View {
        NavigationStack {
            DriveFolderScreen(client: DriveClient(host: library.host), isRoot: true, searchMode: searchMode)
                .navigationDestination(for: DriveFolder.self) { f in
                    DriveFolderScreen(client: DriveClient(host: library.host),
                                      folder: f.id, title: f.name)
                }
                .navigationDestination(for: DriveCrumb.self) { c in
                    DriveFolderScreen(client: DriveClient(host: library.host),
                                      folder: c.id, title: c.name)
                }
                .navigationDestination(for: DriveTrashRoute.self) { _ in
                    DriveTrashScreen(client: DriveClient(host: library.host))
                }
        }
    }
}

struct DriveTrashRoute: Hashable {}

/// Ziel einer Verschieben-Aktion (Datei oder Ordner) für den Picker-Sheet.
enum DriveMoveTarget: Identifiable {
    case file(DriveFile)
    case folder(DriveFolder)
    var id: String {
        switch self {
        case .file(let f): return "f\(f.id)"
        case .folder(let d): return "d\(d.id)"
        }
    }
}

struct DriveFolderScreen: View {
    let client: DriveClient
    var folder: Int? = nil
    var title: String = "Files"
    var isRoot: Bool = false
    var searchMode: Bool = false

    @State private var listing = DriveListing()
    @State private var loaded = false
    @State private var previewURL: URL?
    @State private var busyFileID: Int?
    @State private var shareBundle: ShareBundle?

    @State private var newFolderPrompt = false
    @State private var newFolderName = ""
    @State private var renamingFile: DriveFile?
    @State private var renamingFolder: DriveFolder?
    @State private var renameText = ""
    @State private var moveTarget: DriveMoveTarget?
    @State private var deletingFolder: DriveFolder?
    @State private var importing = false
    @State private var uploadDone = 0
    @State private var uploadTotal = 0
    @State private var changeFailed = false

    @State private var searchText = ""
    @State private var results: DriveListing?

    var body: some View {
        Group {
            if searchMode {
                content.searchable(text: $searchText, prompt: "Search Files")
            } else {
                content
            }
        }
        .navigationTitle(searchMode ? "Search" : title)
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .toolbar { if !searchMode { toolbar } }
        .task { if !searchMode { await load() } }
        .task(id: searchText) {
            guard searchMode else { return }
            guard !searchText.isEmpty else { results = nil; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = try? await client.search(searchText)
        }
        .quickLookPreview($previewURL)
        .sheet(item: $shareBundle) { bundle in
            ShareSheet(items: bundle.urls).presentationDetents([.medium, .large])
        }
        .sheet(item: $moveTarget) { target in
            DriveMovePicker(client: client, target: target) {
                Task { await load() }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { handleImport($0) }
        .alert("New Folder", isPresented: $newFolderPrompt) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                newFolderName = ""
                guard !name.isEmpty else { return }
                change { try await client.createFolder(parent: folder, name: name) }
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Rename", isPresented: isRenaming) {
            TextField("Name", text: $renameText)
            Button("Save") { applyRename() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deletingFolder?.name ?? "")” Permanently?",
            isPresented: Binding(get: { deletingFolder != nil },
                                 set: { if !$0 { deletingFolder = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                guard let f = deletingFolder else { return }
                change { try await client.deleteFolder(f.id) }
            }
        } message: {
            Text("The folder and the \(deletingFolder?.items ?? 0) files in it will be deleted permanently.")
        }
        .changeFailedAlert($changeFailed)
    }

    private var content: some View {
        List {
            if let results {
                searchSections(results)
            } else {
                if !listing.folders.isEmpty {
                    Section {
                        ForEach(listing.folders) { f in folderRow(f) }
                    }
                }
                if !listing.files.isEmpty {
                    Section {
                        ForEach(listing.files) { f in fileRow(f) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollIndicators(.hidden)
        .refreshable { await load() }
        .overlay {
            if uploadTotal > 0 {
                VStack(spacing: 10) {
                    ProgressView(value: Double(uploadDone), total: Double(uploadTotal))
                        .frame(width: 160)
                    Text("Uploading \(min(uploadDone + 1, uploadTotal)) of \(uploadTotal)…")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(20)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            } else if searchMode {
                if searchText.isEmpty {
                    ContentUnavailableView("Search Files", systemImage: "magnifyingglass",
                                           description: Text("Names and contents of documents"))
                } else if let results, results.folders.isEmpty && results.files.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            } else if loaded && listing.folders.isEmpty && listing.files.isEmpty {
                ContentUnavailableView("No Files", systemImage: "folder")
            }
        }
    }

    @ViewBuilder
    private func searchSections(_ r: DriveListing) -> some View {
        if !r.folders.isEmpty {
            Section("Folders") {
                ForEach(r.folders) { f in
                    NavigationLink(value: DriveCrumb(id: f.id, name: f.name)) {
                        Label(f.name, systemImage: "folder.fill")
                    }
                }
            }
        }
        if !r.files.isEmpty {
            Section("Files") {
                ForEach(r.files) { f in fileRow(f, showFolder: true) }
            }
        }
    }

    // MARK: rows

    private func folderRow(_ f: DriveFolder) -> some View {
        NavigationLink(value: f) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.name)
                        .lineLimit(1)
                    Text("\(f.items) \(f.items == 1 ? "item" : "items") · \(bytes(f.bytes))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            Button { renamingFolder = f; renameText = f.name } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button { moveTarget = .folder(f) } label: {
                Label("Move", systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) { deletingFolder = f } label: {
                Label("Delete Permanently", systemImage: "trash.slash")
            }
        }
    }

    private func fileRow(_ f: DriveFile, showFolder: Bool = false) -> some View {
        Button { open(f) } label: {
            HStack(spacing: 12) {
                let icon = driveIcon(for: f.name)
                Image(systemName: icon.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(icon.color)
                    .frame(width: 34, height: 34)
                    .background(icon.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle(f, showFolder: showFolder))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let snippet = f.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.footnote)
                            .italic()
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if busyFileID == f.id { ProgressView() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { share(f) } label: { Label("Share", systemImage: "square.and.arrow.up") }
            Button { renamingFile = f; renameText = f.name } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button { moveTarget = .file(f) } label: {
                Label("Move", systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) { trash(f) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { trash(f) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func subtitle(_ f: DriveFile, showFolder: Bool) -> String {
        var parts = [bytes(f.size)]
        if let d = f.modifiedAt {
            parts.append(d.formatted(date: .numeric, time: .omitted))
        }
        if showFolder, let folder = f.folder {
            parts.append(folder)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isRoot {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: DriveTrashRoute()) {
                    Label("Trash", systemImage: "trash")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("Add", systemImage: "plus") {
                Button { importing = true } label: {
                    Label("Upload Files", systemImage: "square.and.arrow.up")
                }
                Button { newFolderPrompt = true } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
        }
    }

    // MARK: actions

    private var isRenaming: Binding<Bool> {
        Binding(get: { renamingFile != nil || renamingFolder != nil },
                set: { if !$0 { renamingFile = nil; renamingFolder = nil } })
    }

    private func applyRename() {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        let file = renamingFile
        let dir = renamingFolder
        renamingFile = nil
        renamingFolder = nil
        guard !name.isEmpty else { return }
        change {
            if let file { try await client.renameFile(file.id, to: name) }
            if let dir { try await client.renameFolder(dir.id, to: name) }
        }
    }

    /// A change on the server, then the folder as it is now.
    private func change(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch { changeFailed = true }
            await load()
        }
    }

    private func open(_ f: DriveFile) {
        guard busyFileID == nil else { return }
        busyFileID = f.id
        Task {
            defer { busyFileID = nil }
            if let url = try? await client.download(f) { previewURL = url }
        }
    }

    private func share(_ f: DriveFile) {
        busyFileID = f.id
        Task {
            defer { busyFileID = nil }
            if let url = try? await client.download(f) { shareBundle = ShareBundle(urls: [url]) }
        }
    }

    private func trash(_ f: DriveFile) {
        Task {
            do {
                try await client.trashFiles([f.id])
                withAnimation(.snappy) { listing.files.removeAll { $0.id == f.id } }
                results?.files.removeAll { $0.id == f.id }
            } catch {
                changeFailed = true
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        Task {
            uploadDone = 0
            uploadTotal = urls.count
            var failed = false
            for url in urls {
                // Kopie in tmp, damit der Upload nach Ende des Security-Scope
                // noch aus der Datei streamen kann; kopiert wird abseits des
                // Main-Threads (ein Video sind Gigabytes)
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        try FileManager.default.copyItem(at: url, to: tmp)
                    }.value
                    try await client.upload(file: tmp, name: url.lastPathComponent, folder: folder)
                } catch {
                    failed = true
                }
                try? FileManager.default.removeItem(at: tmp)
                uploadDone += 1
            }
            uploadTotal = 0
            if failed { changeFailed = true }
            await load()
        }
    }

    private func load() async {
        // a failed reload keeps what is shown
        if let fresh = try? await client.list(folder: folder) { listing = fresh }
        loaded = true
    }
}

// MARK: - Papierkorb

struct DriveTrashScreen: View {
    let client: DriveClient
    @State private var files: [DriveFile] = []
    @State private var loaded = false
    @State private var confirmEmpty = false
    @State private var deleting: DriveFile?
    @State private var changeFailed = false

    var body: some View {
        List {
            ForEach(files) { f in
                HStack(spacing: 12) {
                    let icon = driveIcon(for: f.name)
                    Image(systemName: icon.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(icon.color)
                        .frame(width: 34, height: 34)
                        .background(icon.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name)
                            .lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button { restore(f) } label: {
                        Label("Recover", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing) {
                    Button { deleting = f } label: {
                        Label("Delete Permanently", systemImage: "trash.slash")
                    }
                    .tint(.red)
                }
                .contextMenu {
                    Button { restore(f) } label: {
                        Label("Recover", systemImage: "arrow.uturn.backward")
                    }
                    Button(role: .destructive) { deleting = f } label: {
                        Label("Delete Permanently", systemImage: "trash.slash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !files.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button("Empty Trash", role: .destructive) { confirmEmpty = true }
                        .confirmationDialog("Empty Trash?", isPresented: $confirmEmpty, titleVisibility: .visible) {
                            Button("Delete Permanently", role: .destructive) {
                                Task {
                                    do { try await client.emptyTrash() } catch { changeFailed = true }
                                    await load()
                                }
                            }
                        } message: {
                            Text("All \(files.count) files will be deleted permanently.")
                        }
                }
            }
        }
        .overlay {
            if files.isEmpty && loaded {
                ContentUnavailableView("Trash Is Empty", systemImage: "trash")
            }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")” Permanently?",
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                if let f = deleting { delete(f) }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .changeFailedAlert($changeFailed)
    }

    private func restore(_ f: DriveFile) {
        remove(f) { try await client.restore([f.id]) }
    }

    private func delete(_ f: DriveFile) {
        remove(f) { try await client.deletePermanent([f.id]) }
    }

    /// The file leaves the trash once the server agreed.
    private func remove(_ f: DriveFile, _ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                withAnimation(.snappy) { files.removeAll { $0.id == f.id } }
            } catch {
                changeFailed = true
            }
        }
    }

    private func load() async {
        // a failed reload keeps what is shown
        if let fresh = try? await client.trash() { files = fresh }
        loaded = true
    }
}

// MARK: - Verschieben-Picker

/// Ordner-Browser im Sheet: hineinnavigieren (System-Zurück), dann
/// „Verschieben“. Der Server verhindert Zyklen (Ordner in sich selbst).
struct DriveMovePicker: View {
    let client: DriveClient
    let target: DriveMoveTarget
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var moveFailed = false

    var body: some View {
        NavigationStack {
            DriveMoveLevel(client: client, target: target, folder: nil, title: "Files", move: move)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .navigationDestination(for: DriveCrumb.self) { c in
                    DriveMoveLevel(client: client, target: target, folder: c.id, title: c.name, move: move)
                }
        }
        .presentationDetents([.medium, .large])
        .changeFailedAlert($moveFailed)
    }

    private func move(to folder: Int?) async {
        do {
            switch target {
            case .file(let f): try await client.move(files: [f.id], to: folder)
            case .folder(let d): try await client.move(folders: [d.id], to: folder)
            }
        } catch {
            moveFailed = true
            return
        }
        onDone()
        dismiss()
    }
}

/// Eine Ebene im Verschieben-Sheet.
private struct DriveMoveLevel: View {
    let client: DriveClient
    let target: DriveMoveTarget
    let folder: Int?
    let title: String
    let move: (Int?) async -> Void

    @State private var folders: [DriveFolder] = []
    @State private var busy = false

    var body: some View {
        List {
            ForEach(folders.filter { !isMoving($0) }) { f in
                NavigationLink(value: DriveCrumb(id: f.id, name: f.name)) {
                    Label(f.name, systemImage: "folder.fill")
                        .lineLimit(1)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if busy {
                    ProgressView()
                } else {
                    Button("Move") {
                        busy = true
                        Task { await move(folder); busy = false }
                    }
                }
            }
        }
        .task { folders = (try? await client.list(folder: folder))?.folders ?? [] }
    }

    private func isMoving(_ f: DriveFolder) -> Bool {
        if case .folder(let d) = target { return d.id == f.id }
        return false
    }
}

// MARK: - Icons

private func driveIcon(for name: String) -> (symbol: String, color: Color) {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "pdf": return ("doc.richtext.fill", .red)
    case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tif", "tiff":
        return ("photo.fill", .teal)
    case "mp3", "m4a", "aac", "wav", "ogg", "oga", "opus", "flac", "aiff":
        return ("waveform", .purple)
    case "mp4", "mov", "m4v", "webm", "mkv", "avi": return ("play.rectangle.fill", .indigo)
    case "zip", "7z", "tar", "gz", "rar": return ("doc.zipper", .brown)
    case "txt", "md", "rtf", "log": return ("doc.text.fill", .gray)
    case "csv", "xls", "xlsx", "numbers": return ("tablecells.fill", .green)
    case "doc", "docx", "pages", "goodnotes": return ("doc.fill", .blue)
    case "ppt", "pptx", "key": return ("rectangle.stack.fill", .orange)
    case "json", "xml", "html", "js", "py", "swift", "rs":
        return ("chevron.left.forwardslash.chevron.right", .cyan)
    default: return ("doc.fill", Color(.systemGray))
    }
}

private func bytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}
