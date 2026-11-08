import SwiftUI
import UniformTypeIdentifiers

/// The sidebar, grouped as in Photos and the Finder. Library, People,
/// Favorites and Videos stay at the top and the server at the bottom; only
/// the albums, utilities and files between them scroll. Photos dragged from
/// a grid onto an album are added to it.
struct MacSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(MacWindowState.self) private var window
    @Binding var newAlbum: Bool
    @AppStorage("sidebar.albums.expanded") private var albumsExpanded = true
    @State private var renaming: Album?
    @State private var deleting: Album?
    @State private var dropTarget: Int?
    @State private var changeFailed = false

    var body: some View {
        // a stack, not insets on the list: the list only gets the space
        // between the fixed rows, so nothing scrolls under them
        VStack(spacing: 0) {
            VStack(spacing: 1) {
                FixedRow(item: .library)
                FixedRow(item: .people)
                FixedRow(item: .special(.favorites))
                FixedRow(item: .special(.videos))
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 6)
            list
            VStack(spacing: 1) {
                Divider().padding(.horizontal, 6).padding(.bottom, 6)
                if model.library.sharing { FixedRow(item: .sharedLinks) }
                FixedRow(item: .server)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
    }

    private var list: some View {
        @Bindable var window = window
        return List(selection: $window.sidebar) {
            Section("Albums", isExpanded: $albumsExpanded) {
                ForEach(model.userAlbums) { album in
                    Label(album.title, systemImage: "rectangle.stack")
                        .badge(album.count)
                        .tag(SidebarItem.album(album.id))
                        .listItemTint(dropTarget == album.id ? .accentColor : nil)
                        .contextMenu {
                            if model.library.sharing {
                                Button("Share Album as Link…") { window.sidebar = .album(album.id) }
                            }
                            Button("Rename Album…") { renaming = album }
                            Divider()
                            Button("Delete Album…", role: .destructive) { deleting = album }
                        }
                        .onDrop(of: [.atlasAssetIDs], isTargeted: Binding(
                            get: { dropTarget == album.id },
                            set: { dropTarget = $0 ? album.id : (dropTarget == album.id ? nil : dropTarget) })) { providers in
                            drop(providers, on: album)
                        }
                }
                Button { newAlbum = true } label: {
                    Label("New Album…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Section("Utilities") {
                row(.special(.archive))
                row(.special(.locked))
                row(.special(.trash))
            }
            Section("Files") {
                row(.files)
                row(.filesTrash)
            }
        }
        .listStyle(.sidebar)
        .albumNameAlert("Rename Album", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                        initial: renaming?.title ?? "") { title in
            guard let album = renaming, !title.isEmpty else { return }
            change { try await model.library.client.renameAlbum(album.id, to: title) }
        }
        .confirmationDialog("Delete Album “\(deleting?.title ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { album in
            Button("Delete Album", role: .destructive) {
                if window.sidebar == .album(album.id) { window.sidebar = .library }
                change { try await model.library.client.deleteAlbum(album.id) }
            }
        } message: { _ in
            Text("The photos stay in your library.")
        }
        .changeFailedAlert($changeFailed)
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.symbol).tag(item)
    }

    private func change(_ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                await model.loadAlbums()
                NotificationCenter.default.post(name: .atlasAlbumsChanged, object: nil)
            } catch {
                changeFailed = true
            }
        }
    }

    private func drop(_ providers: [NSItemProvider], on album: Album) -> Bool {
        let type = UTType.atlasAssetIDs.identifier
        let wanted = providers.filter { $0.hasItemConformingToTypeIdentifier(type) }
        guard !wanted.isEmpty else { return false }
        Task {
            var ids: [String] = []
            for provider in wanted {
                if let data = try? await provider.loadData(type), let id = String(data: data, encoding: .utf8) {
                    ids.append(id)
                }
            }
            guard !ids.isEmpty else { return }
            change {
                try await model.library.client.addToAlbum(album.id, ids)
                NSSound(named: "Pop")?.play()
            }
        }
        return true
    }
}

/// A sidebar row that stays put while the albums scroll: drawn like the
/// list's own rows (accent icon, the selection a filled rounded rectangle)
/// and selecting through the same binding.
private struct FixedRow: View {
    let item: SidebarItem
    @Environment(MacWindowState.self) private var window
    @Environment(\.appearsActive) private var active
    @State private var hovering = false

    private var selected: Bool { (window.sidebar ?? .library) == item && !window.isSearching }

    var body: some View {
        Button {
            window.search = ""
            window.sidebar = item
        } label: {
            Label {
                Text(item.title)
            } icon: {
                Image(systemName: item.symbol)
                    .font(.system(size: 15))
                    .frame(width: 22)
                    .foregroundStyle(selected && active ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            }
            .foregroundStyle(selected && active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            // as tall and as large as the list's rows (32 pt apart)
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: 31)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? AnyShapeStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                          : AnyShapeStyle(hovering ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear)))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension NSItemProvider {
    func loadData(_ type: String) async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            _ = loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: data) }
            }
        }
    }
}
