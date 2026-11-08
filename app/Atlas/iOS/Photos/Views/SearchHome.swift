import SwiftUI
import MapKit

/// The search tab before anything is typed: the years and the countries,
/// each searching for itself. The people ride above the search
/// field (`SearchPeopleBar`); the map of the places lives in Albums.
struct SearchHome: View {
    var library: Library
    var onSearch: (String) -> Void
    @State private var places: [PlaceSummary] = PlacesMemo.places

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if years.isEmpty {
                    ContentUnavailableView("Search Photos", systemImage: "magnifyingglass",
                                           description: Text("People, places, things or a year"))
                        .padding(.top, 80)
                } else {
                    yearCards
                }
                if !countries.isEmpty { countryCards }
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(SimulatorHooks.scrolledDown ? .bottom : .top)
        .task { await Covers.shared.load(library.client) }
        .task {
            if let fresh = try? await library.client.places() {
                places = fresh
                PlacesMemo.places = fresh
            }
        }
    }

    // MARK: Countries

    struct Country: Identifiable {
        let code: String
        var name: String
        var photos: Int
        var places: Int
        var cover: String?
        /// The middle of its places, weighted by their photos.
        var center: CLLocationCoordinate2D?
        var id: String { code }
        /// The flag, from the two letters of the country code.
        var flag: String {
            String(String.UnicodeScalarView(code.uppercased().unicodeScalars.compactMap {
                UnicodeScalar(127397 + $0.value)
            }))
        }
    }

    /// The places grouped by country, the most photographed first; a
    /// country's photo is from its most photographed place.
    private var countries: [Country] {
        var out: [String: Country] = [:]
        for p in places {
            guard let cc = p.country, cc.count == 2 else { continue }
            var c = out[cc] ?? Country(code: cc, name: Locale.current.localizedString(forRegionCode: cc) ?? cc,
                                       photos: 0, places: 0, cover: p.cover)
            c.photos += p.photos
            c.places += 1
            out[cc] = c
        }
        for (cc, c) in out {
            let located = places.filter { $0.country == cc && $0.coordinate != nil }
            let w = Double(located.reduce(0) { $0 + $1.photos })
            guard w > 0 else { continue }
            out[cc]?.center = CLLocationCoordinate2D(
                latitude: located.reduce(0) { $0 + $1.lat! * Double($1.photos) } / w,
                longitude: located.reduce(0) { $0 + $1.lon! * Double($1.photos) } / w)
        }
        return out.values.sorted { $0.photos > $1.photos }
    }

    private var countryCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Countries", nil)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(countries) { c in
                        Button { onSearch(c.name) } label: {
                            ZStack(alignment: .bottomLeading) {
                                // no photo good enough: a map of the country
                                GroupCover(library: library, id: Covers.shared.countries[c.code],
                                           coordinate: c.center, span: 5)
                                    .frame(width: 210, height: 128)
                                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(c.flag).font(.system(size: 22))
                                        Text(c.name)
                                            .font(.title3.weight(.bold))
                                            .lineLimit(1)
                                    }
                                    Text("\(c.photos.formatted()) photos · \(c.places) \(c.places == 1 ? "place" : "places")")
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
                        .accessibilityLabel("\(c.name), \(c.photos) photos")
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
                                GroupCover(library: library, id: Covers.shared.years[String(y.year)])
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

