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
    /// Split once per load, not filtered on every update of the page.
    private var humans: [Person] { split.humans }
    private var pets: [Person] { split.pets }
    @State private var split = (humans: [Person](), pets: [Person]())

    var body: some View {
        @Bindable var window = window
        NavigationStack(path: $window.peoplePath) {
            Group {
                if persons.isEmpty && loaded {
                    ContentUnavailableView("No People", systemImage: "person.crop.circle",
                                           description: Text("People appear here once atlas has recognized faces."))
                } else {
                    PeopleGrid(library: model.library, humans: humans, pets: pets, size: size,
                               onOpen: { window.peoplePath.append($0) },
                               onRename: { newName = $0.name ?? ""; renaming = $0 },
                               onHide: { hide($0) })
                        .ignoresSafeArea(edges: .top)
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
        .task {
            if split.humans.isEmpty { split = Self.split(persons) }
            await load()
        }
        .alert("Name This Person", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .changeFailedAlert($changeFailed)
    }

    private func hide(_ person: Person) {
        persons.removeAll { $0.id == person.id }
        PeopleMemo.people = persons
        split = Self.split(persons)
        Task {
            do { try await model.library.client.setPersonHidden(person.id, true) } catch { await load() }
        }
    }

    private static func split(_ all: [Person]) -> (humans: [Person], pets: [Person]) {
        (all.filter { !$0.isPet }, all.filter(\.isPet))
    }

    private func load() async {
        if let fresh = try? await model.library.client.persons() {
            persons = fresh
            PeopleMemo.people = fresh
            split = Self.split(fresh)
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
