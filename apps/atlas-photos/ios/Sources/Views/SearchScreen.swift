import SwiftUI

struct SearchScreen: View {
    var library: Library
    @State private var query = ""
    @State private var result = PhotoClient.SearchResult()
    @State private var searching = false
    @State private var pick: Asset?

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                if query.isEmpty {
                    hint
                } else if result.items.isEmpty && result.persons.isEmpty && !searching {
                    Text("nichts gefunden für \(query)")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        if !result.persons.isEmpty {
                            personsRow
                        }
                        LazyVGrid(columns: cols, spacing: 2) {
                            ForEach(result.items) { asset in
                                Color.clear.aspectRatio(1, contentMode: .fill)
                                    .overlay { Thumb(url: library.client.thumbURL(asset.id, 512)).clipped() }
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
            .navigationDestination(for: Person.self) { p in
                PersonDetailScreen(library: library, person: p)
            }
        }
        .searchable(text: $query, prompt: "Person, Ort, Hund, 2019 …")
        .onChange(of: query) { _, q in
            Task { await run(q) }
        }
        .fullScreenCover(item: $pick) { a in
            ViewerScreen(library: library, assets: result.items, start: a)
        }
    }

    /// Matching persons as tappable face chips above the photo grid.
    private var personsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(result.persons) { p in
                    NavigationLink(value: p) {
                        VStack(spacing: 5) {
                            FaceCircle(library: library, person: p)
                                .frame(width: 64, height: 64)
                            Text(p.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(p.photos) Fotos")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(width: 76)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func run(_ q: String) async {
        let term = q.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { result = PhotoClient.SearchResult(); return }
        searching = true
        try? await Task.sleep(for: .milliseconds(250))   // debounce
        guard term == query.trimmingCharacters(in: .whitespaces) else { return }
        result = (try? await library.client.search(term)) ?? PhotoClient.SearchResult()
        searching = false
    }

    private var hint: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Suche in deiner Bibliothek")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Personen, Orte, Dinge — z. B. Mia, Kroatien, Hund, 2019")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }
}
