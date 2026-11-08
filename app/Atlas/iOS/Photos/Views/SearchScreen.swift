import SwiftUI

struct SearchScreen: View {
    var library: Library
    @State private var query = ""
    @State private var result = PhotoClient.SearchResult()
    @State private var searching = false
    /// Bumped with every new result, so the grid reloads (and goes to the top).
    @State private var revision = 0
    /// From the library: its top people, place and this year.
    @State private var example = SearchExample.placeholder

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                if query.isEmpty {
                    SearchHome(library: library) { query = $0 }
                } else if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    Color.clear
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
                    // the photos run under the status bar and the pills of
                    // how the search was read, which float over them
                    AssetGrid(library: library, assets: result.items, selection: nil,
                              onRefresh: { await run(query) }, underBar: true)
                        .id(revision)
                        .overlay(alignment: .top) {
                            QueryChips(parts: result.understood, persons: result.persons, library: library)
                        }
                }
            }
            .navigationTitle("Search")
            // the people, right above the search field, until a letter is typed
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if query.isEmpty {
                    SearchPeopleBar(library: library) { query = $0 }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.smooth(duration: 0.25), value: query.isEmpty)
            .navigationDestination(for: Person.self) { p in
                PersonDetailScreen(library: library, person: p)
            }
        }
        .searchable(text: $query, prompt: example)
        // the model unloads after ten idle minutes: load it while the
        // query is being typed, not after it was sent
        .task {
            #if targetEnvironment(simulator)
            // ATLAS_QUERY=... opens a simulator with that search (with ATLAS_TAB=search)
            if let q = ProcessInfo.processInfo.environment["ATLAS_QUERY"], query.isEmpty { query = q }
            #endif
            example = await SearchExample.make(client: library.client)
            await library.client.warmSearch()
        }
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

}
