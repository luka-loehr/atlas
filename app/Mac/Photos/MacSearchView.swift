import SwiftUI

/// Photos search: people by name, then everything else by what is in the
/// picture, the moment the typing stops.
struct MacSearchView: View {
    let query: String
    @Environment(AppModel.self) private var model
    @Environment(MacWindowState.self) private var window
    @State private var result: PhotoClient.SearchResult?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let result {
                    // how the search was read, as the iPhone shows it: glass
                    // pills, people and pets with their faces, wrapping
                    MacPhotoBrowser(source: .search(query), given: result.items, header: AnyView(
                        VStack(spacing: 0) {
                            if !result.semantic {
                                Label("Searching by content is unavailable right now: names, places and albums only.",
                                      systemImage: "exclamationmark.triangle")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                            }
                            QueryChips(parts: result.understood, persons: result.persons, library: model.library,
                                       onPerson: { window.open($0) })
                        }))
                } else if failed {
                    ServerUnavailableView()
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await model.library.client.warmSearch() }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                result = try await model.library.client.search(query.trimmingCharacters(in: .whitespaces))
                failed = false
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}
