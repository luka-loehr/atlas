import SwiftUI
import QuickLook
import UniformTypeIdentifiers

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
                DriveIcon(symbol: "folder.fill", color: .blue, size: 17, weight: .medium)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.name)
                        .lineLimit(1)
                    Text("\(f.items) \(f.items == 1 ? "item" : "items") · \(f.bytes.fileSize)")
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
                DriveIcon(file: f.name)
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
        var parts = [f.size.fileSize]
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
