import SwiftUI

extension Notification.Name {
    /// An album was created, renamed, deleted or had photos added or removed:
    /// the Albums tab reads the list again.
    static let atlasAlbumsChanged = Notification.Name("atlas.albumsChanged")
}

extension View {
    /// The name prompt for a new or renamed album: Save stays off while the
    /// name is empty.
    func albumNameAlert(_ title: String, isPresented: Binding<Bool>, initial: String = "",
                        save: @escaping (String) -> Void) -> some View {
        modifier(AlbumNameAlert(title: title, isPresented: isPresented, initial: initial, save: save))
    }
}

private struct AlbumNameAlert: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let initial: String
    let save: (String) -> Void
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: $isPresented) {
                TextField("Title", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") { save(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .onChange(of: isPresented) { _, shown in if shown { name = initial } }
    }
}

/// "Add to Album": a new album at the top, then every album; one tap adds
/// the photos and closes the sheet.
struct AddToAlbumSheet: View {
    var library: Library
    let ids: [String]
    var added: (Album) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var albums: [Album] = AlbumsMemo.albums.filter(AddToAlbumSheet.isUserAlbum)
    @State private var naming = false
    @State private var busy = false
    @State private var failed = false

    static func isUserAlbum(_ a: Album) -> Bool {
        !SpecialAlbum.isLocked(a.title) && !SpecialAlbum.isTrash(a.title)
    }

    var body: some View {
        NavigationStack {
            List {
                Button { naming = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "plus")
                            .font(.title2)
                            .frame(width: 56, height: 56)
                            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text("New Album…").foregroundStyle(.tint)
                    }
                }
                ForEach(albums) { album in
                    Button { add(to: album) } label: {
                        HStack(spacing: 14) {
                            AlbumThumb(library: library, id: album.cover)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.title).foregroundStyle(.primary).lineLimit(1)
                                Text(album.count, format: .number)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .disabled(busy)
            .overlay { if busy { ProgressView() } }
            .navigationTitle(ids.count == 1 ? "Add 1 Item" : "Add \(ids.count.formatted()) Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .albumNameAlert("New Album", isPresented: $naming) { title in
                run { try await library.client.createAlbum(title) }
            }
            .changeFailedAlert($failed)
            .task {
                guard let fresh = try? await library.client.albums() else { return }
                AlbumsMemo.albums = fresh
                albums = fresh.filter(Self.isUserAlbum)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(to album: Album) { run { album } }

    /// Finds or makes the album, adds the photos, closes.
    private func run(_ target: @escaping () async throws -> Album) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let album = try await target()
                try await library.client.addToAlbum(album.id, ids)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                NotificationCenter.default.post(name: .atlasAlbumsChanged, object: nil)
                added(album)
                dismiss()
            } catch {
                failed = true
            }
        }
    }
}

/// A small album cover from the grid thumbnail.
private struct AlbumThumb: View {
    var library: Library
    var id: String?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemFill))
            if let id {
                Thumb(url: library.client.thumbURL(id, 512))
            } else {
                Image(systemName: "photo.on.rectangle").foregroundStyle(.tertiary)
            }
        }
        .clipped()
    }
}

/// Photos from the library for an album: the Library grid, picking.
struct PhotoPickerSheet: View {
    var library: Library
    let title: String
    let pick: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection = Selection()
    @State private var proxy = PhotoGridProxy()

    var body: some View {
        NavigationStack {
            PhotoGrid(library: library, assets: library.assets, revision: library.revision,
                      selecting: true, selected: selection.ids, proxy: proxy, titleShade: false, contextMenus: false,
                      onTop: { _ in },
                      onToggle: { asset in withAnimation(.snappy(duration: 0.26)) { selection.toggle(asset.id) } },
                      menu: { _ in UIMenu(children: []) },
                      onRefresh: { await library.refresh() })
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(selection.isEmpty ? title
                                 : selection.count == 1 ? "1 Item Selected" : "\(selection.count) Items Selected")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add", systemImage: "checkmark") {
                            pick(Array(selection.ids))
                            dismiss()
                        }
                        .disabled(selection.isEmpty)
                    }
                }
                .onAppear { selection.enter() }
        }
    }
}

/// Photos on their way into an album, for `.sheet(item:)`.
struct AlbumAdd: Identifiable {
    let id = UUID()
    let ids: [String]
}
