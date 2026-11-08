import SwiftUI
import MapKit

/// Where the photos were taken, in Albums: a heat map that opens into a
/// full map, and the places as cards. A place opens its photos.
struct PlacesSection: View {
    var library: Library
    @State private var places: [PlaceSummary] = PlacesMemo.places
    @Namespace private var zoom
    /// ATLAS_SCREEN=map opens a simulator on the full map.
    @State private var showMap = SimulatorHooks.screen == "map"
    /// ATLAS_SCREEN=covers: every place's card in one grid, to review them.
    @State private var showCovers = SimulatorHooks.screen == "covers"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !places.isEmpty {
                SectionHeader(title: "Places") { EmptyView() }
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink {
                        PlacesMapScreen(library: library, places: places)
                            .navigationTransition(.zoom(sourceID: "map", in: zoom))
                    } label: {
                        PlacesMapCard(places: places)
                            .matchedTransitionSource(id: "map", in: zoom)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 12) {
                            ForEach(places.prefix(30)) { place in
                                NavigationLink {
                                    PlaceScreen(library: library, place: place)
                                } label: {
                                    PlaceCard(library: library, place: place)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(.bottom, 8)
            }
        }
        .navigationDestination(isPresented: $showMap) { PlacesMapScreen(library: library, places: places) }
        .navigationDestination(isPresented: $showCovers) { CoverReview(library: library) }
        .task { await Covers.shared.load(library.client) }
        .task {
            if let fresh = try? await library.client.places() {
                places = fresh
                PlacesMemo.places = fresh
            }
        }
    }
}

/// Every place's card in one grid, the smallest places first: for
/// reviewing the covers in a simulator (ATLAS_SCREEN=covers).
private struct CoverReview: View {
    var library: Library
    @State private var places: [PlaceSummary] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(places.reversed()) { place in
                    PlaceCard(library: library, place: place).scaleEffect(0.66).frame(width: 100, height: 126)
                }
            }
            .padding(8)
        }
        .task {
            await Covers.shared.load(library.client)
            places = (try? await library.client.places()) ?? []
        }
    }
}

/// Launch switches for screenshots, read in a simulator only.
enum SimulatorHooks {
    static var screen: String? {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["ATLAS_SCREEN"]
        #else
        nil
        #endif
    }
    /// ATLAS_SCROLL=bottom: a page opens scrolled to its end.
    static var scrolledDown: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["ATLAS_SCROLL"] == "bottom"
        #else
        false
        #endif
    }
}

/// The places with a position, most photographed first.
private func located(_ places: [PlaceSummary], _ limit: Int) -> [PlaceSummary] {
    Array(places.filter { $0.coordinate != nil }.prefix(limit))
}

/// Where the map opens: around the places that hold most of the photos
/// (95 % of them, at most 40 places), so one trip far away does not zoom
/// the map out to half the globe.
private func homeRegion(_ places: [PlaceSummary]) -> MapCameraPosition {
    let shown = located(places, 400)
    let total = shown.reduce(0) { $0 + $1.photos }
    var core: [CLLocationCoordinate2D] = []
    var sum = 0
    for p in shown where core.count < 40 {
        core.append(p.coordinate!)
        sum += p.photos
        if Double(sum) >= Double(total) * 0.95 { break }
    }
    guard let first = core.first else { return .automatic }
    var lo = first, hi = first
    for c in core {
        lo.latitude = min(lo.latitude, c.latitude); lo.longitude = min(lo.longitude, c.longitude)
        hi.latitude = max(hi.latitude, c.latitude); hi.longitude = max(hi.longitude, c.longitude)
    }
    let center = CLLocationCoordinate2D(latitude: (lo.latitude + hi.latitude) / 2, longitude: (lo.longitude + hi.longitude) / 2)
    let span = MKCoordinateSpan(latitudeDelta: max((hi.latitude - lo.latitude) * 1.35, 0.6),
                                longitudeDelta: max((hi.longitude - lo.longitude) * 1.35, 0.6))
    return .region(MKCoordinateRegion(center: center, span: span))
}

/// The map as a card: still, the most photographed place called out.
struct PlacesMapCard: View {
    let places: [PlaceSummary]

    var body: some View {
        let shown = located(places, 60)
        let top = shown.first?.photos ?? 1
        Map(initialPosition: homeRegion(places), interactionModes: []) {
            ForEach(shown) { place in
                Annotation(place.name ?? "", coordinate: place.coordinate!, anchor: .center) {
                    HeatSpot(weight: Double(place.photos) / Double(max(top, 1)))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
        .frame(height: 230)
        .clipShape(.rect(cornerRadius: 26))
        .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.08)) }
        // the top corner: the map's legal notice stays readable below
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Image(systemName: "map.fill").foregroundStyle(.orange)
                Text("\(places.count.formatted()) places").fontWeight(.semibold)
            }
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.footnote.weight(.semibold))
                .frame(width: 34, height: 34)
                .glassEffect(.regular, in: .circle)
                .padding(12)
        }
        .contentShape(.rect(cornerRadius: 26))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of where your photos were taken, \(places.count) places")
        .accessibilityAddTraits(.isButton)
    }
}

/// The map in full: pan and zoom, every place glowing with its name; a
/// place opens its photos.
struct PlacesMapScreen: View {
    var library: Library
    let places: [PlaceSummary]
    @State private var open: PlaceSummary?
    @State private var position: MapCameraPosition = .automatic
    @State private var framed = false

    var body: some View {
        let shown = located(places, 400)
        let top = shown.first?.photos ?? 1
        Map(position: $position) {
            ForEach(shown) { place in
                Annotation(place.name ?? "", coordinate: place.coordinate!, anchor: .center) {
                    HeatSpot(weight: Double(place.photos) / Double(max(top, 1)))
                        .onTapGesture { open = place }
                        .accessibilityLabel("\(place.name ?? "Place"), \(place.photos) photos")
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $open) { PlaceScreen(library: library, place: $0) }
        // framed once the places are there (also when they arrive after
        // the map opened), then the camera is the user's
        .onChange(of: places.count, initial: true) {
            guard !framed, !places.isEmpty else { return }
            framed = true
            position = homeRegion(places)
        }
    }
}

/// One place: its photos, newest first.
struct PlaceScreen: View {
    var library: Library
    let place: PlaceSummary
    @State private var assets: [Asset] = []

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            AssetGrid(library: library, assets: assets, selection: nil,
                      onRefresh: { await load() }, onViewerClosed: { Task { await load() } }, underBar: true)
        }
        .navigationTitle(place.name ?? "Place")
        .inlineNavigationTitle()
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private func load() async {
        if let fresh = try? await library.client.collection("/places/\(place.id)") { assets = fresh }
    }
}

/// A glowing spot whose size and heat follow how many photos were taken
/// there (`weight` 0–1 against the most photographed place).
struct HeatSpot: View {
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
struct PlaceCard: View {
    var library: Library
    let place: PlaceSummary

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GroupCover(library: library, id: Covers.shared.places[String(place.id)], symbol: "mappin.and.ellipse",
                       coordinate: place.coordinate)
                .frame(width: 148, height: 188)
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                Text(place.name ?? "Unknown")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(place.photos.formatted()) \(place.photos == 1 ? "photo" : "photos")")
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

// MARK: - Places from the server

struct PlaceSummary: Codable, Identifiable, Hashable, Sendable {
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

/// The covers the server's image model chose for the places, countries
/// and years (GET /covers): the most beautiful photo of each, or none when
/// none is good. Asked for at most every half hour.
@MainActor @Observable
final class Covers {
    static let shared = Covers()
    private(set) var places: [String: String] = [:]
    private(set) var countries: [String: String] = [:]
    private(set) var years: [String: String] = [:]
    @ObservationIgnored private var asked = Date.distantPast

    private struct Saved: Codable {
        var places: [String: String]
        var countries: [String: String]
        var years: [String: String]
    }

    /// The covers as last fetched, on the phone: the cards show their
    /// photos at once after a launch, before the server is asked again.
    private static let file = URL.cachesDirectory.appending(path: "covers.json")

    private init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            places = saved.places
            countries = saved.countries
            years = saved.years
        }
    }

    func load(_ client: PhotoClient) async {
        guard Date().timeIntervalSince(asked) > 1800 else { return }
        asked = Date()
        guard let r: Saved = try? await client.get("/covers") else { asked = .distantPast; return }
        if r.places != places { places = r.places }
        if r.countries != countries { countries = r.countries }
        if r.years != years { years = r.years }
        let data = try? JSONEncoder().encode(r)
        Task.detached(priority: .utility) { try? data?.write(to: Self.file, options: .atomic) }
        warm(client)
    }

    /// The year and country covers, decoded into memory ahead, as the
    /// search tab shows them: it opens complete, like the grid. (Their
    /// files are grid thumbnails, kept on the phone with the grid's.)
    private func warm(_ client: PhotoClient) {
        let ids = Array(years.values) + Array(countries.values)
        Task(priority: .utility) {
            for id in ids {
                guard let url = client.thumbURL(id, 512) else { continue }
                if MediaCache.shared.cached(url, maxPixel: 480) == nil {
                    _ = await MediaCache.shared.load(url, maxPixel: 480)
                }
            }
        }
    }
}

/// A card's picture: the cover photo; for a place or country without a
/// good one, a map of where it is; else a quiet ground with a symbol.
struct GroupCover: View {
    var library: Library
    let id: String?
    var symbol: String? = nil
    /// Where the group is, for the map instead of a photo.
    var coordinate: CLLocationCoordinate2D? = nil
    /// How much of the map shows, in degrees (a town, a country).
    var span: Double = 0.12

    var body: some View {
        if let id {
            Thumb(url: library.client.thumbURL(id, 512), maxPixel: 480)
        } else if let coordinate {
            MapCover(coordinate: coordinate, span: span)
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.32), Color(white: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                        .offset(y: -14)
                }
            }
        }
    }
}

/// A still map of a spot with a glow on it, drawn once by MapKit's
/// snapshotter and kept, so a row of cards does not run live maps.
private struct MapCover: View {
    let coordinate: CLLocationCoordinate2D
    let span: Double
    @Environment(\.colorScheme) private var scheme
    @State private var image: UIImage?

    private var key: String {
        String(format: "%.4f,%.4f,%.3f,%d", coordinate.latitude, coordinate.longitude, span, scheme == .dark ? 1 : 0)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.secondarySystemBackground)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                    HeatSpot(weight: 0.5)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .task(id: key) { image = await Self.snapshot(coordinate, span, geo.size, scheme, key) }
        }
    }

    private static let cache = NSCache<NSString, UIImage>()

    private static func snapshot(_ c: CLLocationCoordinate2D, _ span: Double, _ size: CGSize,
                                 _ scheme: ColorScheme, _ key: String) async -> UIImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard size.width > 0, size.height > 0 else { return nil }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
        options.size = size
        options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        options.traitCollection = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        guard let shot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        cache.setObject(shot.image, forKey: key as NSString)
        return shot.image
    }
}

/// The places as last fetched, kept on the phone, so Albums and Search
/// open complete, also right after a launch.
@MainActor
enum PlacesMemo {
    private static let file = URL.cachesDirectory.appending(path: "places.json")

    static var places: [PlaceSummary] = {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([PlaceSummary].self, from: data)) ?? []
    }() {
        didSet {
            let data = try? JSONEncoder().encode(places)
            Task.detached(priority: .utility) { try? data?.write(to: file, options: .atomic) }
        }
    }
}

extension PhotoClient {
    /// Every place with photos, most photographed first.
    func places() async throws -> [PlaceSummary] {
        struct R: Decodable { let places: [PlaceSummary] }
        let r: R = try await get("/places")
        return r.places
    }
}
