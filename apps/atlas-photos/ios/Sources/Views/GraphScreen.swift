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

// MARK: - Native RadialLayout (Layout protocol)
//
// A real SwiftUI layout container: places its subviews evenly on a circle.
// Because it speaks SwiftUI's layout language, EVERY arrangement change
// (ring swaps, recentering) is animated by the system itself — combined with
// matchedGeometryEffect a satellite literally flies into the center.

struct RadialLayout: Layout {
    var radius: CGFloat
    var phase: Double = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let n = max(subviews.count, 1)
        for (i, sub) in subviews.enumerated() {
            let angle = Double(i) / Double(n) * 2 * .pi - .pi / 2 + phase
            let p = CGPoint(x: bounds.midX + cos(angle) * radius,
                            y: bounds.midY + sin(angle) * radius)
            sub.place(at: p, anchor: .center, proposal: .unspecified)
        }
    }
}

// MARK: - Anchor preferences: spokes drawn between REAL view positions
//
// Every node reports its center via anchorPreference; the container draws the
// spokes from those anchors — so the lines track every animation (layout
// changes, matched-geometry flights, breathing) automatically. This is the
// canonical SwiftUI way to connect views with lines.

private struct NodeAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGPoint>] { [:] }
    static func reduce(value: inout [String: Anchor<CGPoint>],
                       nextValue: () -> [String: Anchor<CGPoint>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Screen

struct GraphScreen: View {
    var library: Library

    @State private var allNodes: [String: GraphNode] = [:]
    @State private var weights: [String: [(id: String, w: Int)]] = [:]
    @State private var loaded = false

    @State private var centerId: String?
    @State private var history: [String] = []
    @State private var openPerson: Person?
    @State private var ringPhase: Double = 0
    @Namespace private var orbit

    var body: some View {
        ZStack {
            background

            if loaded, let cid = centerId, let center = allNodes[cid] {
                orbitBoard(center: center)
            } else if !loaded {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Graph wird geladen …")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            VStack {
                Spacer()
                quickJump
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
        .onAppear {
            withAnimation(.linear(duration: 160).repeatForever(autoreverses: false)) {
                ringPhase = 2 * .pi
            }
        }
    }

    // native MeshGradient background — deep space with faint color islands
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

    // MARK: orbit board (pure native containers)

    @ViewBuilder
    private func orbitBoard(center: GraphNode) -> some View {
        let sats = weights[center.id] ?? []
        let inner = Array(sats.prefix(8))
        let outer = Array(sats.dropFirst(8).prefix(14))

        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height - 170)
            let r1 = side * 0.30
            let r2 = side * 0.47

            ZStack {
                // outer ring — a real Layout container
                RadialLayout(radius: r2, phase: ringPhase * 0.6 + .pi / 14) {
                    ForEach(outer, id: \.id) { sat in
                        satellite(sat, big: false)
                    }
                }

                // inner ring
                RadialLayout(radius: r1, phase: -ringPhase) {
                    ForEach(inner, id: \.id) { sat in
                        satellite(sat, big: true)
                    }
                }

                // the sun
                CenterNodeView(node: center, library: library) {
                    guard center.kind == "person" else { return }
                    let pid = Int64(center.id.dropFirst()) ?? 0
                    openPerson = Person(id: pid,
                                        name: center.label.isEmpty ? nil : center.label,
                                        coverFace: center.cover, photos: center.size)
                }
                .anchorPreference(key: NodeAnchorKey.self, value: .center) {
                    [center.id: $0]
                }
                .matchedGeometryEffect(id: center.id, in: orbit)
            }
            .frame(width: geo.size.width, height: geo.size.height - 110)
            // spokes: drawn from the REAL anchors → follow every animation
            .backgroundPreferenceValue(NodeAnchorKey.self) { anchors in
                GeometryReader { g in
                    spokes(anchors: anchors, in: g, center: center,
                           weights: sats)
                }
            }
        }
    }

    @ViewBuilder
    private func satellite(_ sat: (id: String, w: Int), big: Bool) -> some View {
        if let node = allNodes[sat.id] {
            SatelliteView(node: node, library: library,
                          diameter: big ? min(54, 34 + CGFloat(sat.w) * 0.7)
                                        : min(36, 22 + CGFloat(sat.w) * 0.5),
                          showLabel: big,
                          counterPhase: big ? ringPhase : -ringPhase * 0.6)
                .anchorPreference(key: NodeAnchorKey.self, value: .center) {
                    [node.id: $0]
                }
                .matchedGeometryEffect(id: node.id, in: orbit)
                .onTapGesture { recenter(on: node) }
        }
    }

    private func spokes(anchors: [String: Anchor<CGPoint>], in geo: GeometryProxy,
                        center: GraphNode,
                        weights sats: [(id: String, w: Int)]) -> some View {
        Canvas { ctx, _ in
            guard let ca = anchors[center.id] else { return }
            let cp = geo[ca]
            let maxW = sats.first?.w ?? 1
            for sat in sats.prefix(22) {
                guard let a = anchors[sat.id] else { continue }
                let p = geo[a]
                var path = Path()
                path.move(to: cp)
                let mid = CGPoint(x: (cp.x + p.x) / 2 + (p.y - cp.y) * 0.05,
                                  y: (cp.y + p.y) / 2 - (p.x - cp.x) * 0.05)
                path.addQuadCurve(to: p, control: mid)
                let t = Double(sat.w) / Double(max(maxW, 1))
                ctx.stroke(path, with: .color(.white.opacity(0.06 + 0.20 * t)),
                           lineWidth: 0.6 + 1.7 * t)
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
        guard !loaded else { return }
        guard let g = try? await library.client.graph() else { return }
        var dict: [String: GraphNode] = [:]
        for n in g.nodes { dict[n.id] = n }
        var w: [String: [(id: String, w: Int)]] = [:]
        for l in g.links {
            w[l.a, default: []].append((l.b, l.w))
            w[l.b, default: []].append((l.a, l.w))
        }
        for k in w.keys { w[k]?.sort { $0.w > $1.w } }
        allNodes = dict
        weights = w
        centerId = g.nodes.filter { $0.kind == "person" }
            .max(by: { $0.size < $1.size })?.id ?? g.nodes.first?.id
        loaded = true
    }

    // MARK: quick jump

    private var quickJump: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(topEntities(), id: \.id) { n in
                    Button {
                        recenter(on: n)
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(GraphPalette.color(n.kind))
                                .frame(width: 7, height: 7)
                            Text(n.label.isEmpty ? "Person \(n.size)" : n.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
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
            .sorted { $0.size > $1.size }.prefix(6)
        let unnamed = allNodes.values.filter { $0.kind == "person" && $0.label.isEmpty }
            .sorted { $0.size > $1.size }.prefix(3)
        let places = allNodes.values.filter { $0.kind == "place" }
            .sorted { $0.size > $1.size }.prefix(5)
        let tags = allNodes.values.filter { $0.kind == "tag" }
            .sorted { $0.size > $1.size }.prefix(5)
        return Array(persons) + Array(unnamed) + Array(places) + Array(tags)
    }
}

// MARK: - Center node

private struct CenterNodeView: View {
    let node: GraphNode
    var library: Library
    var openPhotos: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(GraphPalette.color(node.kind).opacity(0.22))
                    .frame(width: 120, height: 120)
                    .blur(radius: 18)
                if node.kind == "person" {
                    ZStack {
                        Circle().fill(GraphPalette.person.opacity(0.3))
                        if let f = node.cover {
                            Thumb(url: library.client.faceCropURL(f))
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(width: 94, height: 94)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(GraphPalette.person, lineWidth: 2.5))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: node.kind == "place" ? "mappin" : "number")
                            .font(.system(size: 19, weight: .semibold))
                        Text(node.label)
                            .font(.system(size: 19, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(GraphPalette.color(node.kind).opacity(0.30),
                                in: Capsule())
                    .overlay(Capsule().strokeBorder(GraphPalette.color(node.kind),
                                                    lineWidth: 2))
                }
            }
            VStack(spacing: 2) {
                Text(node.label.isEmpty
                     ? (node.kind == "person" ? "Unbenannt" : node.label)
                     : node.label)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text(node.kind == "person" ? "\(node.size) Fotos"
                     : node.kind == "place" ? "Ort · \(node.size) Fotos"
                     : "Tag · \(node.size)×")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if node.kind == "person" {
                Button(action: openPhotos) {
                    Label("Fotos", systemImage: "photo.on.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
            }
        }
    }
}

// MARK: - Satellite

private struct SatelliteView: View {
    let node: GraphNode
    var library: Library
    let diameter: CGFloat
    let showLabel: Bool
    var counterPhase: Double

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if node.kind == "person" {
                    ZStack {
                        Circle().fill(GraphPalette.person.opacity(0.25))
                        if let f = node.cover {
                            Thumb(url: library.client.faceCropURL(f))
                        } else {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(
                        GraphPalette.person.opacity(0.75), lineWidth: 1.5))
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: node.kind == "place" ? "mappin" : "number")
                            .font(.system(size: max(8, diameter * 0.24),
                                          weight: .semibold))
                        Text(node.label)
                            .font(.system(size: max(9, diameter * 0.26),
                                          weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, max(7, diameter * 0.22))
                    .padding(.vertical, max(4, diameter * 0.13))
                    .background(GraphPalette.color(node.kind).opacity(0.26),
                                in: Capsule())
                    .overlay(Capsule().strokeBorder(
                        GraphPalette.color(node.kind).opacity(0.6), lineWidth: 1))
                }
            }
            if showLabel, node.kind == "person", !node.label.isEmpty {
                Text(node.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        // stay upright while the ring container rotates
        .rotationEffect(.radians(counterPhase))
        // native idle life: gentle two-phase breathing, driven by the system
        .phaseAnimator([false, true]) { content, phase in
            content.scaleEffect(phase ? 1.04 : 0.97)
        } animation: { _ in
            .easeInOut(duration: 2.2 + Double(abs(node.id.hashValue % 160)) / 100)
        }
        .contentShape(Circle())
    }
}
