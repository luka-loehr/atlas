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
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    hint
                } else if result.items.isEmpty && result.persons.isEmpty {
                    if searching {
                        ProgressView()
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
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
                                    .assetAccessibility(asset)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationTitle("Search")
            .navigationDestination(for: Person.self) { p in
                PersonDetailScreen(library: library, person: p)
            }
        }
        .searchable(text: $query, prompt: "Person, place, dog, 2019…")
        .onChange(of: query) { _, q in
            Task { await run(q) }
        }
        .fullScreenCover(item: $pick) { a in
            ViewerScreen(library: library, assets: result.items, start: a,
                         onRemoved: { id in result.items.removeAll { $0.id == id } })
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
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(p.photos) \(p.photos == 1 ? "Item" : "Items")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 76)
                        .accessibilityElement(children: .combine)
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
        guard term.count >= 2 else { result = PhotoClient.SearchResult(); searching = false; return }
        searching = true
        try? await Task.sleep(for: .milliseconds(250))   // debounce
        guard term == query.trimmingCharacters(in: .whitespaces) else { return }
        let found = (try? await library.client.search(term)) ?? PhotoClient.SearchResult()
        guard term == query.trimmingCharacters(in: .whitespaces) else { return }
        result = found
        searching = false
    }

    private var hint: some View {
        ContentUnavailableView("Search Photos", systemImage: "magnifyingglass",
                               description: Text("People, places, things or a year"))
    }
}
