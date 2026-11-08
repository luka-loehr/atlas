import SwiftUI

/// Everyone atlas recognized: a three-column grid of round faces with
/// names and photo counts, people first, then pets. Tap ->
/// PersonDetailScreen; long press to hide someone.
struct PersonsScreen: View {
    var library: Library
    // the last list, faces already on the phone: the screen opens complete
    @State private var persons: [Person] = PeopleMemo.people
    @State private var loaded = !PeopleMemo.people.isEmpty
    @State private var showHidden = false

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 20), count: 3)

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            ScrollView {
                grid(persons.filter { !$0.isPet })
                if persons.contains(where: \.isPet) {
                    Text("Pets")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 28)
                    grid(persons.filter(\.isPet))
                }
                if persons.isEmpty && loaded {
                    ContentUnavailableView("No People", systemImage: "person.crop.circle",
                                           description: Text("People appear here once atlas has recognized faces."))
                        .padding(.top, 60)
                }
            }
            .scrollIndicators(.hidden)
            .refreshable { await load() }
        }
        .navigationTitle("People")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .trailingBar) {
                Button("Hidden People", systemImage: "eye.slash") { showHidden = true }
            }
        }
        .sheet(isPresented: $showHidden) {
            HiddenPeopleSheet(library: library) { Task { await load() } }
        }
        .task { await load() }
    }

    private func grid(_ shown: [Person]) -> some View {
                LazyVGrid(columns: cols, spacing: 24) {
                    ForEach(shown) { person in
                        NavigationLink {
                            PersonDetailScreen(library: library, person: person)
                        } label: {
                            VStack(spacing: 2) {
                                FaceCircle(library: library, person: person)
                                    .aspectRatio(1, contentMode: .fit)
                                    .padding(.bottom, 6)
                                Text(person.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(person.name == nil
                                                     ? .secondary : .primary)
                                    .lineLimit(1)
                                Text(person.photos, format: .number)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Hide", systemImage: "eye.slash") { hide(person) }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(person.displayName)
                        .accessibilityValue("\(person.photos) \(person.photos == 1 ? "photo" : "photos")")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named: "Hide") { hide(person) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
    }

    private func hide(_ person: Person) {
        persons.removeAll { $0.id == person.id }
        PeopleMemo.people = persons
        Task {
            do { try await library.client.setPersonHidden(person.id, true) } catch { await load() }
        }
    }

    private func load() async {
        if let fresh = try? await library.client.persons() {
            persons = fresh
            PeopleMemo.people = fresh
        }
        loaded = true
    }
}


/// One person: big avatar + name + count, then their photo grid.
/// Rename via the ⋯ menu (alert with text field).
struct PersonDetailScreen: View {
    var library: Library
    @State var person: Person

    @State private var assets: [Asset] = []
    @State private var renaming = false
    @State private var newName = ""
    @State private var changeFailed = false
    @Environment(\.dismiss) private var dismissScreen

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            // the library's own grid, newest first
            AssetGrid(library: library, assets: assets, selection: nil,
                      onRefresh: { await load() }, onViewerClosed: { Task { await load() } })
                .ignoresSafeArea(edges: .bottom)
        }
        .navigationTitle(person.displayName)
        .inlineNavigationTitle()
        .toolbar {
            // the title with a small face of who it is
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    FaceCircle(library: library, person: person)
                        .frame(width: 28, height: 28)
                    Text(person.displayName)
                        .font(.headline)
                        .foregroundStyle(person.name == nil ? .secondary : .primary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(person.displayName)
                .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .trailingBar) {
                Menu("More", systemImage: "ellipsis") {
                    Button {
                        newName = person.name ?? ""
                        renaming = true
                    } label: { Label("Rename", systemImage: "pencil") }
                    Button {
                        Task {
                            do {
                                try await library.client.setPersonHidden(person.id, true)
                                PeopleMemo.people.removeAll { $0.id == person.id }
                                dismissScreen()
                            } catch { changeFailed = true }
                        }
                    } label: { Label("Hide", systemImage: "eye.slash") }
                }
            }
        }
        .alert(person.isPet ? "Name This Pet" : "Name This Person", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                let old = person.name
                person.name = name.isEmpty ? nil : name
                Task {
                    do {
                        try await library.client.renamePerson(person.id, name: name)
                    } catch {
                        person.name = old
                        changeFailed = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(person.isPet ? "What’s this pet’s name?" : "What’s this person’s name?")
        }
        .changeFailedAlert($changeFailed)
        .task { await load() }
    }

    private func load() async {
        if let fresh = try? await library.client.personAssets(person.id) { assets = fresh }
    }
}
