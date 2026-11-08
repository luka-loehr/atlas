import SwiftUI

/// The menu bar. Every action of a toolbar or a context menu is here too,
/// with its shortcut; items that do not apply right now are disabled, not
/// hidden, so the menus keep their shape (HIG, "The menu bar").
struct AtlasCommands: Commands {
    var model: AppModel

    @FocusedValue(\.photoActions) private var photos
    @FocusedValue(\.windowActions) private var window
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // File
        CommandGroup(after: .newItem) {
            Button("New Album…") { window?.newAlbum() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(window == nil || !model.session.isConnected)
            Button("New Folder") { window?.newFolder?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(window?.newFolder == nil)
            Divider()
            Button("Upload Files…") { window?.upload?() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(window?.upload == nil)
        }
        // Edit › Find: the search field, as Search does on the iPhone
        CommandGroup(after: .textEditing) {
            Button("Find") { window?.find() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(window == nil || !model.session.isConnected)
        }
        CommandGroup(replacing: .importExport) {
            Button(photos.map { $0.count == 1 ? "Export Original…" : "Export \($0.count.formatted()) Originals…" } ?? "Export Originals…") {
                photos?.export?()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(photos?.export == nil)
        }

        // Image: what Photos calls the menu for the selected photos
        CommandMenu("Image") {
            Button("Open") { photos?.open?() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(photos?.open == nil)
            Divider()
            // the grid and the viewer also take a bare "." (Photos' key), which
            // a menu item cannot have without eating it in text fields
            Button(photos?.allFavorite == true ? "Unfavorite" : "Favorite") { photos?.toggleFavorite?() }
                .disabled(photos?.toggleFavorite == nil)
            Button("Add to Album…") { photos?.addToAlbum?() }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .disabled(photos?.addToAlbum == nil)
            Button("Remove from Album") { photos?.removeFromAlbum?() }
                .disabled(photos?.removeFromAlbum == nil)
            Divider()
            Button("Share…") { photos?.share?() }
                .disabled(photos?.share == nil)
            Button("Share as Link…") { photos?.shareLink?() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(photos?.shareLink == nil)
            Divider()
            Button("Archive") { photos?.archive?() }
                .disabled(photos?.archive == nil)
            Button("Lock") { photos?.lock?() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(photos?.lock == nil)
            Button(photos?.restore?.title ?? "Recover") { photos?.restore?.run() }
                .disabled(photos?.restore == nil)
            Divider()
            Button(deleteTitle) { photos?.delete?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(photos?.delete == nil)
        }

        // View
        CommandGroup(before: .toolbar) {
            Button(window?.state.showInspector == true ? "Hide Info" : "Show Info") {
                window?.state.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(window == nil)
            Divider()
            Button("Zoom In") { withAnimation(.snappy) { window?.state.zoomIn() } }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(window == nil || window!.state.zoom >= GridZoom.sizes.count - 1)
            Button("Zoom Out") { withAnimation(.snappy) { window?.state.zoomOut() } }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(window == nil || window!.state.zoom <= 0)
            Divider()
            Button("Refresh") { window?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(window == nil || !model.session.isConnected)
            Divider()
        }
        SidebarCommands()
        ToolbarCommands()

        // Go: the sidebar's places, as in the Finder's Go menu
        CommandMenu("Go") {
            go("Library", .library, "1")
            go("People", .people, "2")
            go("Favorites", .special(.favorites), "3")
            go("Videos", .special(.videos), "4")
            Divider()
            go("Files", .files, "5")
            go("Shared Links", .sharedLinks, "6")
            go("Server", .server, "7")
            Divider()
            go("Archive", .special(.archive), nil)
            go("Locked", .special(.locked), nil)
            go("Recently Deleted", .special(.trash), nil)
        }

        // Window
        CommandGroup(before: .windowList) {
            Button("Terminal") { openWindow(id: "terminal") }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!model.session.isConnected)
            Divider()
        }

        // Help
        CommandGroup(replacing: .help) {
            Link("Atlas Help", destination: URL(string: "https://github.com/luka-loehr/atlas/blob/main/docs/SETUP.md")!)
            Link("Report an Issue", destination: URL(string: "https://github.com/luka-loehr/atlas/issues")!)
        }
    }

    private var deleteTitle: String {
        guard let photos else { return "Delete" }
        return photos.count == 1 ? "Delete 1 Item…" : "Delete \(photos.count.formatted()) Items…"
    }

    private func go(_ title: String, _ item: SidebarItem, _ key: KeyEquivalent?) -> some View {
        Group {
            if let key {
                Button(title) { window?.state.sidebar = item; window?.state.search = "" }
                    .keyboardShortcut(key, modifiers: .command)
            } else {
                Button(title) { window?.state.sidebar = item; window?.state.search = "" }
            }
        }
        .disabled(window == nil || !model.session.isConnected)
    }
}
