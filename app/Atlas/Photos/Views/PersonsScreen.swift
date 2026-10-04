import SwiftUI

/// Everyone atlas recognized: a three-column grid of round faces with
/// names and photo counts. Tap -> PersonDetailScreen.
struct PersonsScreen: View {
    var library: Library
    // the last list, faces already on the phone: the screen opens complete
    @State private var persons: [Person] = PeopleMemo.people
    @State private var loaded = !PeopleMemo.people.isEmpty

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 20), count: 3)

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            ScrollView {
                LazyVGrid(columns: cols, spacing: 24) {
                    ForEach(persons) { person in
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
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(person.displayName)
                        .accessibilityValue("\(person.photos) \(person.photos == 1 ? "photo" : "photos")")
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
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
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        if let fresh = try? await library.client.persons() {
            persons = fresh
            PeopleMemo.people = fresh
        }
        loaded = true
    }
}

/// Round face-crop avatar with a fallback silhouette.
struct FaceCircle: View {
    var library: Library
    var person: Person

    var body: some View {
        ZStack {
            Circle().fill(Color(.secondarySystemFill))
            if let f = person.coverFace {
                Thumb(url: library.client.faceCropURL(f))
            } else {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(22)
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// One person: big avatar + name + count, then their photo grid.
/// Rename via the ⋯ menu (alert with text field).
struct PersonDetailScreen: View {
    var library: Library
    @State var person: Person

    @State private var assets: [Asset] = []
    @State private var pick: Asset?
    @State private var renaming = false
    @State private var newName = ""
    @State private var changeFailed = false
    @Namespace private var zoom

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 10) {
                    FaceCircle(library: library, person: person)
                        .frame(width: 108, height: 108)
                    Text(person.displayName)
                        .font(.title.bold())
                        .foregroundStyle(person.name == nil ? .secondary : .primary)
                        .multilineTextAlignment(.center)
                    Text("\(assets.count) \(assets.count == 1 ? "Item" : "Items")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 18)

                LazyVGrid(columns: cols, spacing: 2) {
                    ForEach(assets) { asset in
                        Color.clear.aspectRatio(1, contentMode: .fill)
                            .overlay {
                                Thumb(url: library.client.thumbURL(asset.id, 512)).clipped()
                            }
                            .clipped()
                            .overlay(alignment: .bottomTrailing) {
                                if asset.isVideo {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 2)
                                        .padding(5)
                                }
                            }
                            .contentShape(Rectangle())
                            .matchedTransitionSource(id: asset.id, in: zoom)
                            .onTapGesture { pick = asset }
                            .assetAccessibility(asset)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(person.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    Button {
                        newName = person.name ?? ""
                        renaming = true
                    } label: { Label("Rename", systemImage: "pencil") }
                }
            }
        }
        .alert("Name This Person", isPresented: $renaming) {
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
            Text("What’s this person’s name?")
        }
        .changeFailedAlert($changeFailed)
        .task { assets = (try? await library.client.personAssets(person.id)) ?? [] }
        .fullScreenCover(item: $pick) { a in
            ViewerScreen(library: library, assets: assets, start: a,
                         onRemoved: { id in assets.removeAll { $0.id == id } })
                .navigationTransition(.zoom(sourceID: a.id, in: zoom))
        }
    }
}
