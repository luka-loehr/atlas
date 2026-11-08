import SwiftUI

struct SearchScreen: View {
    var library: Library
    @State private var query = ""
    @State private var result = PhotoClient.SearchResult()
    @State private var searching = false
    /// Bumped with every new result, so the grid reloads (and goes to the top).
    @State private var revision = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    hint
                } else if result.items.isEmpty && result.persons.isEmpty {
                    if searching {
                        ProgressView()
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    // the library's own grid: pinch through 1/3/5/9 columns,
                    // the same tiles and prefetching, a tap opens exactly the
                    // photo under the finger, newest first
                    VStack(spacing: 0) {
                        QueryChips(parts: result.understood, persons: result.persons, library: library)
                        AssetGrid(library: library, assets: result.items, selection: nil,
                                  onRefresh: { await run(query) })
                            .id(revision)
                            .ignoresSafeArea(edges: .bottom)
                    }
                }
            }
            .navigationTitle("Search")
            .navigationDestination(for: Person.self) { p in
                PersonDetailScreen(library: library, person: p)
            }
        }
        .searchable(text: $query, prompt: "Alex and Sam, beach, Spain 2024…")
        // the model unloads after ten idle minutes: load it while the
        // query is being typed, not after it was sent
        .task { await library.client.warmSearch() }
        .onChange(of: query) { old, q in
            if old.isEmpty, !q.isEmpty { Task { await library.client.warmSearch() } }
            Task { await run(q) }
        }
    }

    private func run(_ q: String) async {
        let term = q.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { result = PhotoClient.SearchResult(); searching = false; return }
        searching = true
        try? await Task.sleep(for: .milliseconds(250))   // debounce
        guard term == query.trimmingCharacters(in: .whitespaces) else { return }
        let found = (try? await library.client.search(term)) ?? PhotoClient.SearchResult()
        guard term == query.trimmingCharacters(in: .whitespaces) else { return }
        result = found
        revision &+= 1
        searching = false
    }

    private var hint: some View {
        ContentUnavailableView("Search Photos", systemImage: "magnifyingglass",
                               description: Text("People, places, things or a year"))
    }
}
