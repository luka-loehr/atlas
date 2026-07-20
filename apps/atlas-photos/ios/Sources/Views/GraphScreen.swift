import SwiftUI

// MARK: - Payload (GET /api/graph)

struct GraphNode: Codable, Identifiable, Equatable {
    let id: String
    let label: String
    let kind: String     // person | place | tag
    let size: Int
    var cover: Int64?    // person avatar face id
}

struct GraphLink: Codable {
    let a: String
    let b: String
    let w: Int
}

extension PhotoClient {
    func graph() async throws -> (nodes: [GraphNode], links: [GraphLink]) {
        struct R: Codable { let nodes: [GraphNode]; let links: [GraphLink] }
        guard let url = URL(string: "http://\(host)/api/graph") else {
            throw URLError(.badURL)
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        return (r.nodes, r.links)
    }
}

enum GraphPalette {
    static let person = Color(red: 0.55, green: 0.58, blue: 0.98)
    static let place = Color(red: 0.36, green: 0.76, blue: 0.44)
    static let tag = Color(red: 0.85, green: 0.80, blue: 0.40)

    static func color(_ kind: String) -> Color {
        switch kind {
        case "person": return person
        case "place": return place
        default: return tag
        }
    }
}

// MARK: - OrbitLayout (Layout protocol)
//
// ONE native layout container for the whole board: subview 0 is the center,
// the next `innerCount` sit on an inner ellipse, the rest on an outer one.
// Because center and satellites live in the SAME container, a recenter is a
// pure reorder — views keep their identity and SwiftUI animates the flight
// into the middle by itself. No matchedGeometryEffect, no duplicate-source
// conflicts. Ring phases are offset so no node sits at exactly 3/9 o'clock
// (where the ellipses run closest together).

struct OrbitLayout: Layout {
    var innerRx: CGFloat
    var innerRy: CGFloat
    var outerRx: CGFloat
    var outerRy: CGFloat
    var innerCount: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        subviews[0].place(at: mid, anchor: .center, proposal: .unspecified)

        let innerN = min(innerCount, subviews.count - 1)
        let outerN = subviews.count - 1 - innerN

        for i in 0..<innerN {
            let a = Double(i) / Double(max(innerN, 1)) * 2 * .pi - .pi / 2 + .pi / 8
            let p = CGPoint(x: mid.x + cos(a) * innerRx,
                            y: mid.y + sin(a) * innerRy)
            subviews[1 + i].place(at: p, anchor: .center, proposal: .unspecified)
        }
        for i in 0..<outerN {
            let slot = 2 * .pi / Double(max(outerN, 1))
            let a = Double(i) * slot - .pi / 2 + slot / 2
            let p = CGPoint(x: mid.x + cos(a) * outerRx,
                            y: mid.y + sin(a) * outerRy)
            subviews[1 + innerN + i].place(at: p, anchor: .center,
                                           proposal: .unspecified)
        }
    }
}

// MARK: - Anchor preferences: spokes drawn between REAL view positions

private struct NodeAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGPoint>] { [:] }
    static func reduce(value: inout [String: Anchor<CGPoint>],
                       nextValue: () -> [String: Anchor<CGPoint>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Screen

private enum OrbitRole { case center, inner, outer }

private struct OrbitItem: Identifiable {
    let node: GraphNode
    let role: OrbitRole
    let weight: Int
    var id: String { node.id }
}

struct GraphScreen: View {
    var library: Library

    @State private var allNodes: [String: GraphNode] = [:]
    @State private var weights: [String: [(id: String, w: Int)]] = [:]
    @State private var loadState: LoadState = .loading

    @State private var centerId: String?
    @State private var history: [String] = []
    @State private var openPerson: Person?

    enum LoadState { case loading, failed, empty, ready }

    var body: some View {
        ZStack {
            background

            switch loadState {
            case .ready:
                if let cid = centerId, let center = allNodes[cid] {
                    orbitBoard(center: center)
                }
                VStack {
                    Spacer()
                    quickJump
                }
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Graph wird geladen …")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                }
            case .failed, .empty:
                VStack(spacing: 14) {
                    Image(systemName: loadState == .empty
                          ? "circle.hexagongrid" : "wifi.exclamationmark")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.35))
                    Text(loadState == .empty
                         ? "Noch keine Verbindungen im Graph."
                         : "Graph konnte nicht geladen werden.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                    if loadState == .failed {
                        Button("Erneut versuchen") {
                            loadState = .loading
                            Task { await loadGraph() }
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                }
            }
        }
        .navigationTitle("Graph")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !history.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
                            centerId = history.popLast()
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                }
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.clear, for: .navigationBar)
        .preferredColorScheme(.dark)
        .sensoryFeedback(.impact(weight: .light), trigger: centerId)
        .navigationDestination(item: $openPerson) { p in
            PersonDetailScreen(library: library, person: p)
        }
        .task { await loadGraph() }
    }

    private var background: some View {
        MeshGradient(width: 3, height: 3,
                     points: [
                        [0, 0], [0.5, 0], [1, 0],
                        [0, 0.5], [0.5, 0.5], [1, 0.5],
                        [0, 1], [0.5, 1], [1, 1],
                     ],
                     colors: [
                        .black, Color(red: 0.05, green: 0.05, blue: 0.12), .black,
                        Color(red: 0.03, green: 0.08, blue: 0.05), .black,
                        Color(red: 0.07, green: 0.05, blue: 0.13),
                        .black, Color(red: 0.04, green: 0.04, blue: 0.10), .black,
                     ])
            .ignoresSafeArea()
    }

    // MARK: orbit board

    private func orbitItems(center: GraphNode) -> [OrbitItem] {
        let sats = weights[center.id] ?? []
        var items = [OrbitItem(node: center, role: .center, weight: 0)]
        for (i, s) in sats.filter({ $0.id != center.id }).prefix(20).enumerated() {
            guard let n = allNodes[s.id] else { continue }
            items.append(OrbitItem(node: n, role: i < 8 ? .inner : .outer,
                                   weight: s.w))
        }
        return items
    }

    @ViewBuilder
    private func orbitBoard(center: GraphNode) -> some View {
        let items = orbitItems(center: center)
        let innerN = items.filter { $0.role == .inner }.count
        let innerIds = Set(items.filter { $0.role == .inner }.map(\.id))

        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height - 110   // room for quick-jump row

            // ring-to-ring clearance on the diagonals needs ≥ 69pt:
            // (outerRy-innerRy)·sin45° must beat both nodes' half-heights,
            // so the ellipses are pushed apart (0.26h vs 0.45h)
            OrbitLayout(innerRx: min(w * 0.30, 122),
                        innerRy: min(h * 0.26, 170),
                        outerRx: min(w * 0.41, 162),
                        outerRy: min(h * 0.45, 310),
                        innerCount: innerN) {
                ForEach(items) { item in
                    nodeView(item)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .frame(width: w, height: h)
            .backgroundPreferenceValue(NodeAnchorKey.self) { anchors in
                GeometryReader { g in
                    spokes(anchors: anchors, in: g, centerId: center.id,
                           innerIds: innerIds,
                           weights: weights[center.id] ?? [])
                }
            }
        }
    }

    @ViewBuilder
    private func nodeView(_ item: OrbitItem) -> some View {
        switch item.role {
        case .center:
            CenterNodeView(node: item.node, library: library) {
                guard item.node.kind == "person" else { return }
                let pid = Int64(item.node.id.dropFirst()) ?? 0
                openPerson = Person(id: pid,
                                    name: item.node.label.isEmpty ? nil : item.node.label,
                                    coverFace: item.node.cover,
                                    photos: item.node.size)
            }
        case .inner:
            OrbNode(node: item.node, library: library,
                    diameter: min(58, 46 + CGFloat(item.weight) * 0.5),
                    labelSize: 11)
                .onTapGesture { recenter(on: item.node) }
        case .outer:
            OrbNode(node: item.node, library: library,
                    diameter: min(44, 32 + CGFloat(item.weight) * 0.4),
                    labelSize: 10)
                .onTapGesture { recenter(on: item.node) }
        }
    }

    // Spokes only for the inner ring, starting at the avatar rim — the outer
    // ring's connectivity is implied. Fewer, cleaner lines instead of a fan.
    private func spokes(anchors: [String: Anchor<CGPoint>], in geo: GeometryProxy,
                        centerId: String, innerIds: Set<String>,
                        weights sats: [(id: String, w: Int)]) -> some View {
        Canvas { ctx, _ in
            guard let ca = anchors[centerId] else { return }
            let cp = geo[ca]
            let maxW = sats.first?.w ?? 1
            for sat in sats where innerIds.contains(sat.id) {
                guard let a = anchors[sat.id] else { continue }
                let p = geo[a]
                let dx = p.x - cp.x, dy = p.y - cp.y
                let len = max(sqrt(dx * dx + dy * dy), 1)
                let start = CGPoint(x: cp.x + dx / len * 52,
                                    y: cp.y + dy / len * 52)
                var path = Path()
                path.move(to: start)
                path.addLine(to: p)
                let t = Double(sat.w) / Double(max(maxW, 1))
                ctx.stroke(path, with: .color(.white.opacity(0.10 + 0.22 * t)),
                           lineWidth: 0.8 + 1.6 * t)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: navigation

    private func recenter(on node: GraphNode) {
        guard node.id != centerId else { return }
        if let c = centerId { history.append(c) }
        if history.count > 24 { history.removeFirst() }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) {
            centerId = node.id
        }
    }

    private func loadGraph() async {
        guard let g = try? await library.client.graph() else {
            loadState = .failed
            return
        }
        var dict: [String: GraphNode] = [:]
        for n in g.nodes { dict[n.id] = n }
        var w: [String: [(id: String, w: Int)]] = [:]
        for l in g.links where l.a != l.b {
            w[l.a, default: []].append((l.b, l.w))
            w[l.b, default: []].append((l.a, l.w))
        }
        for k in w.keys {
            var seen = Set<String>()
            w[k] = w[k]!.sorted { $0.w > $1.w }
                .filter { seen.insert($0.id).inserted }
        }
        allNodes = dict
        weights = w
        centerId = g.nodes.filter { $0.kind == "person" }
            .max(by: { $0.size < $1.size })?.id ?? g.nodes.first?.id
        loadState = dict.isEmpty ? .empty : .ready
    }

    // MARK: quick jump — named persons with real face chips, no debug rows

    private var quickJump: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(topEntities(), id: \.id) { n in
                    Button {
                        recenter(on: n)
                    } label: {
                        HStack(spacing: 6) {
                            if n.kind == "person", let f = n.cover {
                                Thumb(url: library.client.faceCropURL(f))
                                    .frame(width: 20, height: 20)
                                    .clipShape(Circle())
                            } else {
                                Circle().fill(GraphPalette.color(n.kind))
                                    .frame(width: 7, height: 7)
                            }
                            Text(n.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(centerId == n.id ? 0.16 : 0.07),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 40)
        .padding(.bottom, 8)
    }

    private func topEntities() -> [GraphNode] {
        let persons = allNodes.values.filter { $0.kind == "person" && !$0.label.isEmpty }
            .sorted { $0.size > $1.size }.prefix(5)
        let places = allNodes.values.filter { $0.kind == "place" }
            .sorted { $0.size > $1.size }.prefix(3)
        let tags = allNodes.values.filter { $0.kind == "tag" }
            .sorted { $0.size > $1.size }.prefix(3)
        return Array(persons) + Array(places) + Array(tags)
    }
}

// MARK: - Center node (compact — tap avatar to open photos)

private struct CenterNodeView: View {
    let node: GraphNode
    var library: Library
    var openPhotos: () -> Void

    private var tint: Color { GraphPalette.color(node.kind) }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                // the ONE ambient motion on the board: a slow glow breathe
                Circle()
                    .fill(tint.opacity(0.30))
                    .frame(width: 116, height: 116)
                    .blur(radius: 24)
                    .phaseAnimator([false, true]) { c, p in
                        c.opacity(p ? 1.0 : 0.55)
                    } animation: { _ in
                        .easeInOut(duration: 4.5)
                    }

                avatar
                    .frame(width: 88, height: 88)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(tint, lineWidth: 2))
                    .overlay(alignment: .bottomTrailing) {
                        if node.kind == "person" {
                            Image(systemName: "photo.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(tint, in: Circle())
                                .offset(x: 2, y: 2)
                        }
                    }
            }
            .anchorPreference(key: NodeAnchorKey.self, value: .center) {
                [node.id: $0]
            }
            .onTapGesture { openPhotos() }

            Text(node.label.isEmpty ? "Unbenannt" : node.label)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 150)

            Text(node.kind == "person" ? "\(node.size) Fotos"
                 : node.kind == "place" ? "Ort · \(node.size) Fotos"
                 : "Tag · \(node.size)×")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if node.kind == "person" {
            ZStack {
                Circle().fill(tint.opacity(0.25))
                if let f = node.cover {
                    Thumb(url: library.client.faceCropURL(f))
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        } else {
            ZStack {
                Circle().fill(tint.opacity(0.25))
                Image(systemName: node.kind == "place" ? "mappin.and.ellipse" : "number")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
    }
}

// MARK: - Satellite: uniform circle + legible label — overlap-proof by design

private struct OrbNode: View {
    let node: GraphNode
    var library: Library
    let diameter: CGFloat
    let labelSize: CGFloat

    private var tint: Color { GraphPalette.color(node.kind) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(tint.opacity(0.20))
                if node.kind == "person" {
                    if let f = node.cover {
                        Thumb(url: library.client.faceCropURL(f))
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: diameter * 0.4))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                } else {
                    Image(systemName: node.kind == "place" ? "mappin" : "number")
                        .font(.system(size: diameter * 0.36, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.75), lineWidth: 1.5))
            .anchorPreference(key: NodeAnchorKey.self, value: .center) {
                [node.id: $0]
            }

            if !node.label.isEmpty {
                Text(node.label)
                    .font(.system(size: labelSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.85), radius: 2)
                    .lineLimit(1)
                    .frame(maxWidth: 70)
            }
        }
        .contentShape(Circle())
    }
}
