import SwiftUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - Dateien tab (drive)

/// Der Google-Drive-Teil der Storage-App: Ordnerbaum + Dateien vom atlas
/// (content-addressed Blobs). Root trägt Suche + Papierkorb; jede Ebene kann
/// hochladen, anlegen, umbenennen, verschieben, löschen.
struct DriveScreen: View {
    var library: Library

    var body: some View {
        NavigationStack {
            DriveFolderScreen(client: DriveClient(host: library.host), isRoot: true)
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
    var title: String = "Dateien"
    var isRoot: Bool = false

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

    @State private var searchText = ""
    @State private var results: DriveListing?

    var body: some View {
        Group {
            if isRoot {
                content.searchable(text: $searchText, prompt: "In Dateien suchen")
            } else {
                content
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .toolbar { toolbar }
        .task { await load() }
        .task(id: searchText) {
            guard isRoot else { return }
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
        .alert("Neuer Ordner", isPresented: $newFolderPrompt) {
            TextField("Name", text: $newFolderName)
            Button("Erstellen") {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                newFolderName = ""
                guard !name.isEmpty else { return }
                Task { try? await client.createFolder(parent: folder, name: name); await load() }
            }
            Button("Abbrechen", role: .cancel) { newFolderName = "" }
        }
        .alert("Umbenennen", isPresented: isRenaming) {
            TextField("Name", text: $renameText)
            Button("Sichern") { applyRename() }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog(
            "„\(deletingFolder?.name ?? "")“ endgültig löschen?",
            isPresented: Binding(get: { deletingFolder != nil },
                                 set: { if !$0 { deletingFolder = nil } }),
            titleVisibility: .visible
        ) {
            Button("Endgültig löschen", role: .destructive) {
                guard let f = deletingFolder else { return }
                Task { try? await client.deleteFolder(f.id); await load() }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Ordner und \(deletingFolder?.items ?? 0) enthaltene Dateien werden dauerhaft von atlas entfernt.")
        }
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
                    Text("Hochladen \(uploadDone + 1)/\(uploadTotal)…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            } else if loaded && results == nil && listing.folders.isEmpty && listing.files.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Keine Dateien")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func searchSections(_ r: DriveListing) -> some View {
        if !r.folders.isEmpty {
            Section("Ordner") {
                ForEach(r.folders) { f in
                    NavigationLink(value: DriveCrumb(id: f.id, name: f.name)) {
                        Label(f.name, systemImage: "folder.fill")
                    }
                }
            }
        }
        if !r.files.isEmpty {
            Section("Dateien") {
                ForEach(r.files) { f in fileRow(f, showFolder: true) }
            }
        }
        if r.folders.isEmpty && r.files.isEmpty {
            Text("Keine Treffer")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.name)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    Text("\(f.items) \(f.items == 1 ? "Objekt" : "Objekte") · \(bytes(f.bytes))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            Button { renamingFolder = f; renameText = f.name } label: {
                Label("Umbenennen", systemImage: "pencil")
            }
            Button { moveTarget = .folder(f) } label: {
                Label("Verschieben", systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) { deletingFolder = f } label: {
                Label("Löschen", systemImage: "trash")
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle(f, showFolder: showFolder))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if busyFileID == f.id { ProgressView() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { share(f) } label: { Label("Teilen", systemImage: "square.and.arrow.up") }
            Button { renamingFile = f; renameText = f.name } label: {
                Label("Umbenennen", systemImage: "pencil")
            }
            Button { moveTarget = .file(f) } label: {
                Label("Verschieben", systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) { trash(f) } label: {
                Label("In den Papierkorb", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { trash(f) } label: {
                Label("Papierkorb", systemImage: "trash")
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
                    Image(systemName: "trash")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { importing = true } label: {
                    Label("Dateien hochladen", systemImage: "square.and.arrow.up")
                }
                Button { newFolderPrompt = true } label: {
                    Label("Neuer Ordner", systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
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
        Task {
            if let file { try? await client.renameFile(file.id, to: name) }
            if let dir { try? await client.renameFolder(dir.id, to: name) }
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
            try? await client.trashFiles([f.id])
            withAnimation(.snappy) { listing.files.removeAll { $0.id == f.id } }
            results?.files.removeAll { $0.id == f.id }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        Task {
            uploadDone = 0
            uploadTotal = urls.count
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                // Kopie in tmp, damit der Upload nach Ende des Security-Scope
                // noch aus der Datei streamen kann
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: url, to: tmp)
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    try await client.upload(file: tmp, name: url.lastPathComponent, folder: folder)
                } catch {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                try? FileManager.default.removeItem(at: tmp)
                uploadDone += 1
            }
            uploadTotal = 0
            await load()
        }
    }

    private func load() async {
        listing = (try? await client.list(folder: folder)) ?? DriveListing()
        loaded = true
    }
}

// MARK: - Papierkorb

struct DriveTrashScreen: View {
    let client: DriveClient
    @State private var files: [DriveFile] = []
    @State private var loaded = false
    @State private var confirmEmpty = false

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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button { restore(f) } label: {
                        Label("Wiederherstellen", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { delete(f) } label: {
                        Label("Löschen", systemImage: "trash.slash")
                    }
                }
                .contextMenu {
                    Button { restore(f) } label: {
                        Label("Wiederherstellen", systemImage: "arrow.uturn.backward")
                    }
                    Button(role: .destructive) { delete(f) } label: {
                        Label("Endgültig löschen", systemImage: "trash.slash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Papierkorb")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !files.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) { confirmEmpty = true } label: {
                        Label("Papierkorb leeren", systemImage: "trash.slash")
                    }
                }
            }
        }
        .overlay {
            if files.isEmpty && loaded {
                VStack(spacing: 12) {
                    Image(systemName: "trash").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Papierkorb ist leer")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Papierkorb leeren?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Endgültig löschen", role: .destructive) {
                Task { try? await client.emptyTrash(); await load() }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle \(files.count) Dateien werden dauerhaft von atlas entfernt.")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func restore(_ f: DriveFile) {
        Task {
            try? await client.restore([f.id])
            withAnimation(.snappy) { files.removeAll { $0.id == f.id } }
        }
    }

    private func delete(_ f: DriveFile) {
        Task {
            try? await client.deletePermanent([f.id])
            withAnimation(.snappy) { files.removeAll { $0.id == f.id } }
        }
    }

    private func load() async {
        files = (try? await client.trash()) ?? []
        loaded = true
    }
}

// MARK: - Verschieben-Picker

/// Eigener kleiner Ordner-Browser (Sheet): rein navigieren, unten "Hierher
/// verschieben". Der Server verhindert Zyklen (Ordner in sich selbst).
struct DriveMovePicker: View {
    let client: DriveClient
    let target: DriveMoveTarget
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stack: [DriveCrumb] = []
    @State private var folders: [DriveFolder] = []
    @State private var busy = false

    private var current: Int? { stack.last?.id }

    var body: some View {
        NavigationStack {
            List {
                ForEach(folders.filter { !isMoving($0) }) { f in
                    Button {
                        stack.append(DriveCrumb(id: f.id, name: f.name))
                        Task { await load() }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill").foregroundStyle(.blue)
                            Text(f.name).foregroundStyle(.primary).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(stack.last?.name ?? "Dateien")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if stack.isEmpty {
                        Button("Abbrechen") { dismiss() }
                    } else {
                        Button {
                            stack.removeLast()
                            Task { await load() }
                        } label: { Image(systemName: "chevron.left") }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        move()
                    } label: {
                        if busy {
                            ProgressView()
                        } else {
                            Text("Hierher verschieben").fontWeight(.semibold)
                        }
                    }
                    .disabled(busy)
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func isMoving(_ f: DriveFolder) -> Bool {
        if case .folder(let d) = target { return d.id == f.id }
        return false
    }

    private func move() {
        busy = true
        Task {
            defer { busy = false }
            switch target {
            case .file(let f): try? await client.move(files: [f.id], to: current)
            case .folder(let d): try? await client.move(folders: [d.id], to: current)
            }
            onDone()
            dismiss()
        }
    }

    private func load() async {
        folders = (try? await client.list(folder: current))?.folders ?? []
    }
}

// MARK: - Icons

func driveIcon(for name: String) -> (symbol: String, color: Color) {
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
