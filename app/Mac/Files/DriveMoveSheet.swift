import SwiftUI
import AppKit

/// "Move to…": the folder tree, one level at a time.
struct DriveMoveSheet: View {
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
