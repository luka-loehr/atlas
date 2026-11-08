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
                    if !result.understood.isEmpty {
                        QueryChips(parts: result.understood)
                        Divider()
                    }
                    if !result.persons.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 16) {
                                ForEach(result.persons) { person in
                                    Button { window.open(person) } label: {
                                        VStack(spacing: 4) {
                                            FaceCircle(library: model.library, person: person).frame(width: 64, height: 64)
                                            Text(person.displayName).font(.caption).lineLimit(1)
                                        }
                                        .frame(width: 80)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .scrollIndicators(.hidden)
                        Divider()
                    }
                    if !result.semantic {
                        Label("Searching by content is unavailable right now: names, places and albums only.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                    MacPhotoBrowser(source: .search(query), given: result.items)
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
