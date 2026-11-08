import SwiftUI

/// A context-menu entry of a Files table.
struct DriveMenuItem: Identifiable {
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
struct DriveTable: View {
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
