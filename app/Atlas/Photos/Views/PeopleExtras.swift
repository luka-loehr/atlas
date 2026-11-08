import SwiftUI

/// How the server read a search, as tokens above the results: "Alex"
/// (a person), "Rex" (a pet), "Spain", "Summer 2024", "beach".
struct QueryChips: View {
    let parts: [PhotoClient.QueryPart]
    /// The people and pets of the result: a chip that names one shows their
    /// face instead of an icon, and opens them.
    var persons: [Person] = []
    var library: Library?
    /// Opens a person or pet; without it the chip is a navigation link.
    var onPerson: ((Person) -> Void)? = nil

    var body: some View {
        if parts.count > 1 || parts.contains(where: { $0.kind != "text" }) {
            // Liquid Glass pills, as many lines as they need
            GlassEffectContainer(spacing: 6) {
                FlowLayout(spacing: 6) {
                    ForEach(parts) { part in chip(part) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // exactly as tall as its pills: the glass container would
            // otherwise take a share of the height next to a grid
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Searched for")
        }
    }

    @ViewBuilder
    private func chip(_ part: PhotoClient.QueryPart) -> some View {
        if let library, let who = persons.first(where: { $0.id == part.person }) {
            PersonChipLink(person: who, open: onPerson) {
                HStack(spacing: 7) {
                    FaceCircle(library: library, person: who)
                        .frame(width: 30, height: 30)
                    Text(part.label)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.leading, 5)
                .padding(.trailing, 14)
                .frame(minHeight: 40)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(part.kind): \(part.label)")
        } else {
            Label(part.label, systemImage: part.symbol)
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .glassEffect(.regular, in: .capsule)
                .accessibilityLabel("\(part.kind): \(part.label)")
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

/// A pill that opens a person: through `open` when given (the Mac window),
/// else as a navigation link.
private struct PersonChipLink<Label: View>: View {
    let person: Person
    let open: ((Person) -> Void)?
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let open {
            Button { open(person) } label: { label() }
        } else {
            NavigationLink(value: person) { label() }
        }
    }
}
