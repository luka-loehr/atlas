import SwiftUI

/// Everyone atlas recognized, as faces; a person opens their photos.
struct MacPeopleView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacWindowState.self) private var window
    @State private var persons: [Person] = PeopleMemo.people
    @State private var loaded = !PeopleMemo.people.isEmpty
    @State private var renaming: Person?
    @State private var newName = ""
    @State private var changeFailed = false
    @State private var showHidden = false

    private var size: CGFloat { max(90, GridZoom.sizes[window.zoom]) }

    var body: some View {
        @Bindable var window = window
        NavigationStack(path: $window.peoplePath) {
            ScrollView {
                grid(persons.filter { !$0.isPet })
                if persons.contains(where: \.isPet) {
                    Text("Pets")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                    grid(persons.filter(\.isPet))
                }
                if persons.isEmpty && loaded {
                    ContentUnavailableView("No People", systemImage: "person.crop.circle",
                                           description: Text("People appear here once atlas has recognized faces."))
                        .padding(.top, 60)
                }
            }
            .overlay { if persons.isEmpty && !loaded { ProgressView() } }
            .navigationTitle("People")
            .navigationSubtitle(persons.isEmpty ? "" : "\(persons.count.formatted()) People")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Hidden People", systemImage: "eye.slash") { showHidden = true }
                        .help("People You Hid")
                }
            }
            .sheet(isPresented: $showHidden) {
                HiddenPeopleSheet(library: model.library) { Task { await load() } }
            }
            .navigationDestination(for: Person.self) { person in
                MacPhotoBrowser(source: .person(person))
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Rename…", systemImage: "pencil") { newName = person.name ?? ""; renaming = person }
                                .help(person.isPet ? "Name This Pet" : "Name This Person")
                        }
                    }
            }
        }
        .task { await load() }
        .alert("Name This Person", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .changeFailedAlert($changeFailed)
    }

    private func grid(_ shown: [Person]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size * 1.4), spacing: 24)], spacing: 24) {
            ForEach(shown) { person in
                NavigationLink(value: person) {
                    VStack(spacing: 6) {
                        FaceCircle(library: model.library, person: person)
                            .aspectRatio(1, contentMode: .fit)
                        Text(person.displayName)
                            .font(.callout)
                            .foregroundStyle(person.name == nil ? .secondary : .primary)
                            .lineLimit(1)
                        Text(person.photos, format: .number)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Rename…") { newName = person.name ?? ""; renaming = person }
                    Button("Hide") { hide(person) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(person.displayName)
                .accessibilityValue("\(person.photos) photos")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Hide") { hide(person) }
            }
        }
        .padding(24)
    }

    private func hide(_ person: Person) {
        persons.removeAll { $0.id == person.id }
        PeopleMemo.people = persons
        Task {
            do { try await model.library.client.setPersonHidden(person.id, true) } catch { await load() }
        }
    }

    private func load() async {
        if let fresh = try? await model.library.client.persons() {
            persons = fresh
            PeopleMemo.people = fresh
        }
        loaded = true
    }

    private func rename() {
        guard let person = renaming else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await model.library.client.renamePerson(person.id, name: name)
                await load()
            } catch {
                changeFailed = true
            }
        }
    }
}
