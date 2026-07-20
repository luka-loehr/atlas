import SwiftUI

/// "Personen und Haustiere" — 3-column grid of round face crops with names
/// (Google-Photos style). Tap -> PersonDetailScreen.
struct PersonsScreen: View {
    var library: Library
    @State private var persons: [Person] = []
    @State private var loaded = false

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 18), count: 3)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                LazyVGrid(columns: cols, spacing: 24) {
                    ForEach(persons) { person in
                        NavigationLink {
                            PersonDetailScreen(library: library, person: person)
                        } label: {
                            VStack(spacing: 8) {
                                FaceCircle(library: library, person: person)
                                    .frame(width: 96, height: 96)
                                Text(person.displayName)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(person.name == nil
                                                     ? .white.opacity(0.45) : .white)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                if persons.isEmpty && loaded {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.dashed")
                            .font(.system(size: 34))
                            .foregroundStyle(.white.opacity(0.25))
                        Text("Noch keine Personen erkannt")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("Die Pipeline gruppiert Gesichter, sobald sie durchgelaufen ist.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.35))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 80)
                    .padding(.horizontal, 40)
                }
            }
            .scrollIndicators(.hidden)
            .refreshable { await load() }
        }
        .navigationTitle("Personen")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        persons = (try? await library.client.persons()) ?? []
        loaded = true
    }
}

/// Round face-crop avatar with a fallback silhouette.
struct FaceCircle: View {
    var library: Library
    var person: Person

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            if let f = person.coverFace {
                Thumb(url: library.client.faceCropURL(f))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .clipShape(Circle())
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
    @Namespace private var zoom

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 10) {
                    FaceCircle(library: library, person: person)
                        .frame(width: 108, height: 108)
                    Text(person.displayName)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(person.name == nil ? .white.opacity(0.5) : .white)
                    Text("\(assets.count) Fotos")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.5))
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
                Menu {
                    Button {
                        newName = person.name ?? ""
                        renaming = true
                    } label: { Label("Umbenennen", systemImage: "pencil") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Person benennen", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Sichern") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                person.name = name.isEmpty ? nil : name
                Task { try? await library.client.renamePerson(person.id, name: name) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Wie heißt diese Person?")
        }
        .task { assets = (try? await library.client.personAssets(person.id)) ?? [] }
        .fullScreenCover(item: $pick) { a in
            ViewerScreen(library: library, assets: assets, start: a)
                .navigationTransition(.zoom(sourceID: a.id, in: zoom))
        }
    }
}
