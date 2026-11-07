import SwiftUI

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
                .inlineNavigationTitle()
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
