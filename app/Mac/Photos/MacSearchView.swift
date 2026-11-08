import SwiftUI

/// Photos search: people by name, then everything else by what is in the
/// picture, the moment the typing stops.
struct MacSearchView: View {
    let query: String
    @Environment(AppModel.self) private var model
    @Environment(MacWindowState.self) private var window
    @State private var result: PhotoClient.SearchResult?
    /// The query `result` answers. The browser is keyed by it, not by what
    /// is typed now: keyed by the typing, it took the previous result's
    /// photos the moment a key was pressed and never reloaded when the new
    /// result arrived (the iPhone keys its grid by each new result too).
    @State private var answered = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let result {
                    // how the search was read, as the iPhone shows it: glass
                    // pills, people and pets with their faces, wrapping
                    MacPhotoBrowser(source: .search(answered), given: result.items,
                                    header: result.semantic ? nil : AnyView(
                                        Label("Searching by content is unavailable right now: names, places and albums only.",
                                              systemImage: "exclamationmark.triangle")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .padding(8)
                                            .padding(.top, 52)),
                                    // a person's pill opens their page
                                    pills: AnyView(QueryChips(parts: result.understood, persons: result.persons,
                                                              library: model.library, onPerson: { window.open($0) },
                                                              oneLine: true)))
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
                let term = query.trimmingCharacters(in: .whitespaces)
                let found = try await model.library.client.search(term)
                guard !Task.isCancelled else { return }
                answered = term
                result = found
                failed = false
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}
