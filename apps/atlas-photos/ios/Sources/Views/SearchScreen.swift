import SwiftUI

struct SearchScreen: View {
    var library: Library
    @State private var query = ""
    @State private var results: [Asset] = []
    @State private var searching = false
    @State private var pick: Asset?

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if query.isEmpty {
                    hint
                } else if results.isEmpty && !searching {
                    Text("nichts gefunden für \(query)")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    ScrollView {
                        LazyVGrid(columns: cols, spacing: 2) {
                            ForEach(results) { asset in
                                Color.clear.aspectRatio(1, contentMode: .fill)
                                    .overlay { Thumb(url: library.client.thumbURL(asset.id, 256)).clipped() }
                                    .clipped()
                                    .onTapGesture { pick = asset }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationTitle("Suche")
        }
        .searchable(text: $query, prompt: "Name, Album, Jahr …")
        .onChange(of: query) { _, q in
            Task { await run(q) }
        }
        .fullScreenCover(item: $pick) { a in
            ViewerScreen(library: library, assets: results, start: a)
        }
    }

    private func run(_ q: String) async {
        let term = q.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { results = []; return }
        searching = true
        try? await Task.sleep(for: .milliseconds(250))   // debounce
        guard term == query.trimmingCharacters(in: .whitespaces) else { return }
        results = (try? await library.client.search(term)) ?? []
        searching = false
    }

    private var hint: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.25))
            Text("Suche in deiner Bibliothek")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text("nach Dateiname, Album oder Jahr — semantische Suche folgt")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }
}
