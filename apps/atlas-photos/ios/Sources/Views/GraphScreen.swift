import SwiftUI

// MARK: - Payload (GET /api/graph)

struct GraphNode: Codable, Identifiable {
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

// MARK: - Screen
//
// ORBIT VIEW (ego graph): one entity sits in the center, its strongest
// connections orbit around it on two rings — inner ring = closest ties,
// outer ring = the long tail. Spokes fade with connection strength. Tap any
// satellite and it springs into the center, its own world re-orbits around
// it. Deterministic, always tidy, phone-first — no physics that can explode.

struct GraphScreen: View {
    var library: Library

    @State private var allNodes: [String: GraphNode] = [:]
    @State private var weights: [String: [(id: String, w: Int)]] = [:]
    @State private var loaded = false

    @State private var centerId: String?
    @State private var history: [String] = []
    @State private var openPerson: Person?
    @State private var spin = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RadialGradient(colors: [Color(white: 0.09), .black],
                               center: .center, startRadius: 20,
                               endRadius: max(geo.size.width, geo.size.height) * 0.7)
                    .ignoresSafeArea()

                if loaded, let cid = centerId, let center = allNodes[cid] {
                    orbitView(center: center, size: geo.size)
                        .id(cid)                       // full re-entrance per center
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
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
        }
        .navigationTitle("Graph")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if history.count > 0 {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                            centerId = history.popLast()
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                }
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.black, for: .navigationBar)
        .preferredColorScheme(.dark)
        .navigationDestination(item: $openPerson) { p in
            PersonDetailScreen(library: library, person: p)
        }
        .task { await loadGraph() }
        .onAppear {
            withAnimation(.linear(duration: 140).repeatForever(autoreverses: false)) {
                spin = true
            }
        }
    }

    // MARK: orbit layout

    @ViewBuilder
    private func orbitView(center: GraphNode, size: CGSize) -> some View {
        let mid = CGPoint(x: size.width / 2, y: size.height / 2 - 26)
        let maxR = min(size.width, size.height - 200) / 2
        let ring1R = maxR * 0.52
        let ring2R = maxR * 0.92
        let sats = neighbors(of: center.id)
        let inner = Array(sats.prefix(9))
        let outer = Array(sats.dropFirst(9).prefix(15))

        ZStack {
            // spokes (behind everything)
            Canvas { ctx, _ in
                for (i, s) in inner.enumerated() {
                    spoke(ctx: &ctx, from: mid,
                          to: ringPos(i, of: inner.count, r: ring1R, mid: mid, phase: 0),
                          w: s.w, maxW: inner.first?.w ?? 1)
                }
                for (i, s) in outer.enumerated() {
                    spoke(ctx: &ctx, from: mid,
                          to: ringPos(i, of: outer.count, r: ring2R, mid: mid,
                                      phase: .pi / Double(max(outer.count, 1))),
                          w: s.w, maxW: inner.first?.w ?? 1)
                }
                // faint orbit circles
                for r in [ring1R, ring2R] {
                    let rect = CGRect(x: mid.x - r, y: mid.y - r, width: 2 * r, height: 2 * r)
                    ctx.stroke(Path(ellipseIn: rect),
                               with: .color(.white.opacity(0.05)), lineWidth: 0.7)
                }
            }

            // slow counter-spinning rings (pure CA transform)
            ring(nodes: inner, radius: ring1R, mid: mid, big: true,
                 rotation: spin ? 360 : 0, duration: 140)
            ring(nodes: outer, radius: ring2R, mid: mid, big: false,
                 rotation: spin ? -360 : 0, duration: 200)

            // the sun
            centerView(center)
                .position(mid)
        }
    }

    private func ringPos(_ i: Int, of n: Int, r: CGFloat, mid: CGPoint,
                         phase: Double) -> CGPoint {
        let angle = Double(i) / Double(max(n, 1)) * 2 * .pi - .pi / 2 + phase
        return CGPoint(x: mid.x + cos(angle) * r, y: mid.y + sin(angle) * r)
    }

    private func spoke(ctx: inout GraphicsContext, from: CGPoint, to: CGPoint,
                       w: Int, maxW: Int) {
        var path = Path()
        path.move(to: from)
        let mid = CGPoint(x: (from.x + to.x) / 2 + (to.y - from.y) * 0.05,
                          y: (from.y + to.y) / 2 - (to.x - from.x) * 0.05)
        path.addQuadCurve(to: to, control: mid)
        let t = Double(w) / Double(max(maxW, 1))
        ctx.stroke(path, with: .color(.white.opacity(0.05 + 0.20 * t)),
                   lineWidth: 0.6 + 1.6 * t)
    }

    /// One orbit ring: rotates slowly via Core Animation; every node counter-
    /// rotates so avatars and labels stay upright. Zero per-frame SwiftUI work.
    @ViewBuilder
    private func ring(nodes ringNodes: [(id: String, w: Int)], radius: CGFloat,
                      mid: CGPoint, big: Bool, rotation: Double,
                      duration: Double) -> some View {
        ZStack {
            ForEach(Array(ringNodes.enumerated()), id: \.element.id) { i, sat in
                if let node = allNodes[sat.id] {
                    let p = ringPos(i, of: ringNodes.count, r: radius, mid: mid,
                                    phase: big ? 0 : .pi / Double(max(ringNodes.count, 1)))
                    SatelliteView(node: node, library: library,
                                  diameter: big ? satSize(sat.w, base: 46)
                                               : satSize(sat.w, base: 32),
                                  showLabel: big)
                        .rotationEffect(.degrees(-rotation))   // stay upright
                        .animation(.linear(duration: duration)
                            .repeatForever(autoreverses: false), value: rotation)
                        .position(p)
                        .onTapGesture { recenter(on: node) }
                }
            }
        }
        .rotationEffect(.degrees(rotation))
        .animation(.linear(duration: duration).repeatForever(autoreverses: false),
                   value: rotation)
    }

    private func satSize(_ w: Int, base: CGFloat) -> CGFloat {
        base + min(22, CGFloat(w) * 0.8)
    }

    // MARK: center

    @ViewBuilder
    private func centerView(_ node: GraphNode) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(GraphPalette.color(node.kind).opacity(0.22))
                    .frame(width: 118, height: 118)
                    .blur(radius: 16)
                Group {
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
                        .frame(width: 96, height: 96)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(GraphPalette.person, lineWidth: 2.5))
                    } else {
                        centerChip(node)
                    }
                }
            }
            VStack(spacing: 2) {
                Text(displayName(node))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle(node))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if node.kind == "person" {
                Button {
                    let pid = Int64(node.id.dropFirst()) ?? 0
                    openPerson = Person(id: pid,
                                        name: node.label.isEmpty ? nil : node.label,
                                        coverFace: node.cover, photos: node.size)
                } label: {
                    Label("Fotos", systemImage: "photo.on.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    private func centerChip(_ node: GraphNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.kind == "place" ? "mappin" : "number")
                .font(.system(size: 20, weight: .semibold))
            Text(node.label)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(GraphPalette.color(node.kind).opacity(0.30), in: Capsule())
        .overlay(Capsule().strokeBorder(GraphPalette.color(node.kind), lineWidth: 2))
    }

    private func displayName(_ n: GraphNode) -> String {
        n.label.isEmpty ? (n.kind == "person" ? "Unbenannt" : n.label) : n.label
    }

    private func subtitle(_ n: GraphNode) -> String {
        switch n.kind {
        case "person": return "\(n.size) Fotos"
        case "place": return "Ort · \(n.size) Fotos"
        default: return "Tag · \(n.size)×"
        }
    }

    // MARK: data & navigation

    private func neighbors(of id: String) -> [(id: String, w: Int)] {
        weights[id] ?? []
    }

    private func recenter(on node: GraphNode) {
        guard node.id != centerId else { return }
        if let c = centerId { history.append(c) }
        if history.count > 24 { history.removeFirst() }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
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
        // start at the biggest person (very likely Luka)
        centerId = g.nodes.filter { $0.kind == "person" }
            .max(by: { $0.size < $1.size })?.id ?? g.nodes.first?.id
        loaded = true
    }

    // MARK: quick jump

    private var quickJump: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(topEntities(), id: \.id) { n in
                    Button { recenter(on: n) } label: {
                        HStack(spacing: 5) {
                            Circle().fill(GraphPalette.color(n.kind))
                                .frame(width: 7, height: 7)
                            Text(displayName(n))
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

// MARK: - Satellite

private struct SatelliteView: View {
    let node: GraphNode
    var library: Library
    let diameter: CGFloat
    let showLabel: Bool

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
                    chip
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
        .contentShape(Circle())
    }

    private var chip: some View {
        HStack(spacing: 3) {
            Image(systemName: node.kind == "place" ? "mappin" : "number")
                .font(.system(size: max(8, diameter * 0.24), weight: .semibold))
            Text(node.label)
                .font(.system(size: max(9, diameter * 0.26), weight: .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, max(7, diameter * 0.22))
        .padding(.vertical, max(4, diameter * 0.13))
        .background(GraphPalette.color(node.kind).opacity(0.26), in: Capsule())
        .overlay(Capsule().strokeBorder(
            GraphPalette.color(node.kind).opacity(0.6), lineWidth: 1))
    }
}
