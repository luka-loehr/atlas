import SwiftUI
import MapKit

/// The search tab before anything is typed: where the photos were taken (a
/// heat map, then the places as cards). Every place searches for itself.
/// The people ride above the search field (`SearchPeopleBar`).
struct SearchHome: View {
    var library: Library
    var onSearch: (String) -> Void

    @State private var places: [PlaceSummary] = PlacesMemo.places

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !mapped.isEmpty { heatMap }
                if !places.isEmpty { topPlaces }
                if !years.isEmpty { yearCards }
                if places.isEmpty {
                    ContentUnavailableView("Search Photos", systemImage: "magnifyingglass",
                                           description: Text("People, places, things or a year"))
                        .padding(.top, 80)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(Self.startAtBottom ? .bottom : .top)
        .task {
            if let fresh = try? await library.client.places() {
                places = fresh
                PlacesMemo.places = fresh
            }
        }
    }

    /// ATLAS_SCROLL=bottom opens a simulator at the end of the page.
    private static var startAtBottom: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["ATLAS_SCROLL"] == "bottom"
        #else
        false
        #endif
    }

    /// The places with a position, most photographed first, as many as a
    /// map can show without turning into noise.
    private var mapped: [PlaceSummary] {
        Array(places.filter { $0.coordinate != nil }.prefix(60))
    }

    // MARK: Heat map

    private var heatMap: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Where You Take Photos", "\(places.count.formatted()) places")
            let top = mapped.first?.photos ?? 1
            Map(initialPosition: .automatic, interactionModes: []) {
                ForEach(mapped) { place in
                    Annotation(place.name ?? "", coordinate: place.coordinate!, anchor: .center) {
                        HeatSpot(weight: Double(place.photos) / Double(max(top, 1)))
                            .onTapGesture { search(place) }
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .frame(height: 280)
            .clipShape(.rect(cornerRadius: 26))
            .overlay {
                RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.08))
            }
            // the top corner: the map's legal notice stays readable below
            .overlay(alignment: .topLeading) {
                if let first = mapped.first {
                    Button { search(first) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "flame.fill").foregroundStyle(.orange)
                            Text(first.name ?? "").fontWeight(.semibold)
                            Text(first.photos.formatted()).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(.capsule)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Map of where your photos were taken")
        }
    }

    // MARK: Places

    private var topPlaces: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Places", nil)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(places.prefix(30)) { place in
                        Button { search(place) } label: { PlaceCard(library: library, place: place) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Years

    /// Each year with its photos, the newest first, and a photo from it.
    private var years: [(year: Int, count: Int, cover: String?)] {
        var out: [Int: (count: Int, cover: String?)] = [:]
        for m in library.months where m.key != Library.undatedID && m.count > 0 {
            var y = out[m.year] ?? (0, nil)
            y.count += m.count
            // the year's newest month gives the cover (months run oldest first)
            y.cover = library.assets[safe: m.first + m.count / 2]?.id ?? y.cover
            out[m.year] = y
        }
        return out.map { ($0.key, $0.value.count, $0.value.cover) }.sorted { $0.year > $1.year }
    }

    private var yearCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Years", nil)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(years, id: \.year) { y in
                        Button { onSearch(String(y.year)) } label: {
                            ZStack(alignment: .bottomLeading) {
                                Thumb(url: y.cover.flatMap { library.client.thumbURL($0, 512) }, maxPixel: 480)
                                    .frame(width: 210, height: 128)
                                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(String(y.year))
                                        .font(.system(size: 30, weight: .bold, design: .rounded))
                                    Text("\(y.count.formatted()) photos")
                                        .font(.caption)
                                        .opacity(0.85)
                                        .monospacedDigit()
                                }
                                .foregroundStyle(.white)
                                .padding(12)
                            }
                            .frame(width: 210, height: 128)
                            .clipShape(.rect(cornerRadius: 20))
                            .contentShape(.rect(cornerRadius: 20))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(y.year), \(y.count) photos")
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func header(_ title: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
    }

    private func search(_ place: PlaceSummary) {
        guard let name = place.name, !name.isEmpty else { return }
        onSearch(name)
    }
}

/// A glowing spot whose size and heat follow how many photos were taken
/// there (`weight` 0–1 against the most photographed place).
private struct HeatSpot: View {
    let weight: Double

    var body: some View {
        // square root: a place with a quarter of the photos is half as big
        let w = max(weight, 0).squareRoot()
        let size = 22 + 74 * w
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(red: 1, green: 0.32, blue: 0.1).opacity(0.75 * (0.45 + 0.55 * w)),
                                              Color.orange.opacity(0.35), .clear],
                                     center: .center, startRadius: 0, endRadius: size / 2))
            Circle()
                .fill(Color(red: 1, green: 0.85 - 0.4 * w, blue: 0.3 - 0.2 * w))
                .frame(width: 5 + 5 * w, height: 5 + 5 * w)
                .shadow(color: .orange, radius: 4)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}

/// A place as a photo from there with its name.
private struct PlaceCard: View {
    var library: Library
    let place: PlaceSummary

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Thumb(url: place.cover.flatMap { library.client.thumbURL($0, 512) }, maxPixel: 480)
                .frame(width: 148, height: 188)
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                Text(place.name ?? "Unknown")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(place.photos.formatted()) photos")
                    .font(.caption)
                    .opacity(0.8)
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .frame(width: 148, height: 188)
        .clipShape(.rect(cornerRadius: 20))
        .contentShape(.rect(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(place.name ?? "Unknown"), \(place.photos) photos")
        .accessibilityAddTraits(.isButton)
    }
}

/// The people, most photographed first, as glass pills in one line that
/// scrolls sideways, just above the search field. A pill searches for them.
struct SearchPeopleBar: View {
    var library: Library
    var onSearch: (String) -> Void

    @State private var people: [Person] = SearchPeopleBar.named(PeopleMemo.people)
    @Environment(\.isSearching) private var searching

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(people) { person in
                        Button { onSearch(person.name ?? "") } label: {
                            HStack(spacing: 7) {
                                FaceCircle(library: library, person: person)
                                    .frame(width: 30, height: 30)
                                Text(person.name ?? "")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.primary)
                            .padding(.leading, 5)
                            .padding(.trailing, 14)
                            .frame(height: 40)
                            .contentShape(.capsule)
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Search for \(person.name ?? "")")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        // while the field is open it floats over the bottom of the page
        // (above the keyboard): the pills sit right above it
        .padding(.bottom, searching ? 58 : 0)
        .task {
            if let fresh = try? await library.client.persons() {
                PeopleMemo.people = fresh
                people = Self.named(fresh)
            }
        }
    }

    /// Everyone with a name, the most photographed first.
    static func named(_ all: [Person]) -> [Person] {
        all.filter { $0.name?.isEmpty == false }.sorted { $0.photos > $1.photos }
    }
}

// MARK: - Places from the server

struct PlaceSummary: Decodable, Identifiable, Sendable {
    let id: Int64
    let name: String?
    let region: String?
    let country: String?
    let photos: Int
    let cover: String?
    let lat: Double?
    let lon: Double?

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// The places as last fetched, so the search tab opens complete.
@MainActor
enum PlacesMemo {
    static var places: [PlaceSummary] = []
}

extension PhotoClient {
    /// Every place with photos, most photographed first.
    func places() async throws -> [PlaceSummary] {
        struct R: Decodable { let places: [PlaceSummary] }
        let r: R = try await get("/places")
        return r.places
    }
}
