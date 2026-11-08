import SwiftUI
import QuickLook

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
