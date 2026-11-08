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
        .task { await Covers.shared.load(library.client) }
        .task {
            if let fresh = try? await library.client.places() {
                places = fresh
                PlacesMemo.places = fresh
            }
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
            GroupCover(library: library, id: Covers.shared.places[String(place.id)], symbol: "mappin.and.ellipse")
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

// MARK: - Places from the server

struct PlaceSummary: Decodable, Identifiable, Hashable, Sendable {
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
    private(set) var loaded = false
    @ObservationIgnored private var asked = Date.distantPast

    func load(_ client: PhotoClient) async {
        guard Date().timeIntervalSince(asked) > 1800 else { return }
        asked = Date()
        struct R: Decodable {
            let places: [String: String]
            let countries: [String: String]
            let years: [String: String]
        }
        guard let r: R = try? await client.get("/covers") else { asked = .distantPast; return }
        places = r.places
        countries = r.countries
        years = r.years
        loaded = true
    }
}

/// A card's picture: the cover photo, or a quiet ground with a symbol when
/// the group has no photo good enough.
struct GroupCover: View {
    var library: Library
    let id: String?
    var symbol: String? = nil

    var body: some View {
        if let id {
            Thumb(url: library.client.thumbURL(id, 512), maxPixel: 480)
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
