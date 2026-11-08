import SwiftUI

/// How the server read a search, as tokens above the results: "Alex"
/// (a person), "Rex" (a pet), "Spain", "Summer 2024", "beach".
struct QueryChips: View {
    let parts: [PhotoClient.QueryPart]
    /// The people and pets of the result: a chip that names one shows their
    /// face instead of an icon, and opens them.
    var persons: [Person] = []
    var library: Library?

    var body: some View {
        if parts.count > 1 || parts.contains(where: { $0.kind != "text" }) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(parts) { part in
                        if let library, let who = persons.first(where: { $0.id == part.person }) {
                            NavigationLink(value: who) {
                                HStack(spacing: 6) {
                                    FaceCircle(library: library, person: who)
                                        .frame(width: 24, height: 24)
                                    Text(part.label)
                                }
                                .font(.footnote.weight(.medium))
                                .padding(.leading, 3)
                                .padding(.trailing, 10)
                                .padding(.vertical, 3)
                                .background(tint(part).opacity(0.15), in: Capsule())
                                .foregroundStyle(tint(part))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(part.kind): \(part.label)")
                        } else {
                            Label(part.label, systemImage: part.symbol)
                                .font(.footnote.weight(.medium))
                                .labelStyle(.titleAndIcon)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(tint(part).opacity(0.15), in: Capsule())
                                .foregroundStyle(tint(part))
                                .accessibilityLabel("\(part.kind): \(part.label)")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Searched for")
        }
    }

    private func tint(_ part: PhotoClient.QueryPart) -> Color {
        switch part.kind {
        case "person": .blue
        case "pet": .orange
        case "place": .green
        case "date": .purple
        case "album", "media": .pink
        default: .secondary
        }
    }
}

/// The people (and pets) hidden from People, search and the info panel,
/// each with a way back.
struct HiddenPeopleSheet: View {
    var library: Library
    /// Someone came back.
    var onChange: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var people: [Person] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(people) { person in
                    HStack(spacing: 12) {
                        FaceCircle(library: library, person: person)
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading) {
                            Text(person.displayName)
                            Text("\(person.photos) \(person.photos == 1 ? "photo" : "photos")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show") {
                            Task {
                                try? await library.client.setPersonHidden(person.id, false)
                                people.removeAll { $0.id == person.id }
                                onChange()
                            }
                        }
                    }
                }
            }
            .overlay {
                if loaded && people.isEmpty {
                    ContentUnavailableView("Nobody Hidden", systemImage: "eye.slash",
                                           description: Text("People you hide leave People, search and the info panel."))
                }
            }
            .navigationTitle("Hidden People")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            people = (try? await library.client.persons(hidden: true)) ?? []
            loaded = true
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #endif
    }
}
