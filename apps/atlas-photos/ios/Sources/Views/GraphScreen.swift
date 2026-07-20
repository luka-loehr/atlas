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

// MARK: - Screen
//
// ARCHITECTURE: the force layout is computed ONCE off the main thread until it
// rests — nothing simulates per frame. Nodes are plain SwiftUI views at fixed
// world positions; zoom/pan is a pure GPU transform on the container; every
// bit of "life" (entrance springs, idle pulse) is a repeatForever Core
// Animation the render loop never touches. Butter over spectacle.

struct GraphScreen: View {
    var library: Library

    @State private var nodes: [GraphNode] = []
    @State private var links: [GraphLink] = []
    @State private var positions: [String: CGPoint] = [:]
    @State private var adjacency: [String: Set<String>] = [:]
    @State private var loaded = false
    @State private var appeared = false
    @State private var focus: String?
    @State private var openPerson: Person?
    @State private var draggingId: String?

    // viewport (pure transform — never triggers node layout)
    @State private var scale: CGFloat = 0.85
    @State private var pinchBase: CGFloat = 0.85
    @State private var offset: CGSize = .zero
    @State private var dragBase: CGSize = .zero

    private let worldSide: CGFloat = 700

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if loaded {
                world
                    .scaleEffect(scale)
                    .offset(offset)
                    .contentShape(Rectangle())
                    .gesture(boardPan.simultaneously(with: pinch))
                    .onTapGesture { withAnimation(.snappy) { focus = nil } }
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Graph wird geladen …")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            VStack {
                Spacer()
                legend
            }
        }
        .navigationTitle("Graph")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.black, for: .navigationBar)
        .preferredColorScheme(.dark)
        .navigationDestination(item: $openPerson) { p in
            PersonDetailScreen(library: library, person: p)
        }
        .task { await loadGraph() }
    }

    // MARK: world

    private var world: some View {
        ZStack {
            // links: ONE static canvas, redrawn only when positions/focus change
            LinksCanvas(links: links, positions: positions,
                        focus: focus, adjacency: adjacency)
                .frame(width: worldSide, height: worldSide)

            ForEach(nodes) { node in
                let dimmed = isDimmed(node.id)
                GraphNodeView(node: node, library: library,
                              diameter: diameter(node),
                              dimmed: dimmed,
                              focused: focus == node.id)
                    .position(positions[node.id] ?? CGPoint(x: worldSide / 2,
                                                            y: worldSide / 2))
                    .scaleEffect(appeared ? 1 : 0.01,
                                 anchor: .center)
                    .animation(.spring(response: 0.55, dampingFraction: 0.72)
                        .delay(Double(stableIndex(node.id)) * 0.012),
                        value: appeared)
                    .gesture(nodeDrag(node.id))
                    .onTapGesture { tap(node) }
            }
        }
        .frame(width: worldSide, height: worldSide)
        .coordinateSpace(name: "world")
    }

    private func isDimmed(_ id: String) -> Bool {
        guard let f = focus else { return false }
        return id != f && !(adjacency[f]?.contains(id) ?? false)
    }

    private func stableIndex(_ id: String) -> Int {
        nodes.firstIndex(where: { $0.id == id }) ?? 0
    }

    private func diameter(_ n: GraphNode) -> CGFloat {
        if n.kind == "person" {
            return min(58, 26 + sqrt(CGFloat(n.size)) * 1.5)
        }
        return min(30, 15 + sqrt(CGFloat(n.size)) * 0.8)
    }

    // MARK: gestures

    private var boardPan: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                offset = CGSize(width: dragBase.width + v.translation.width,
                                height: dragBase.height + v.translation.height)
            }
            .onEnded { _ in dragBase = offset }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                scale = min(3.5, max(0.35, pinchBase * v.magnification))
            }
            .onEnded { _ in pinchBase = scale }
    }

    /// Drag a node in world coordinates; on release the neighborhood reflows
    /// with one smooth spring — no per-frame physics.
    private func nodeDrag(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("world"))
            .onChanged { v in
                draggingId = id
                positions[id] = v.location
            }
            .onEnded { _ in
                draggingId = nil
                reflow(around: id)
            }
    }

    private func tap(_ node: GraphNode) {
        if node.kind == "person", focus == node.id {
            let pid = Int64(node.id.dropFirst()) ?? 0
            openPerson = Person(id: pid,
                                name: node.label.isEmpty ? nil : node.label,
                                coverFace: node.cover, photos: node.size)
            return
        }
        withAnimation(.snappy) { focus = (focus == node.id) ? nil : node.id }
    }

    // MARK: layout

    private func loadGraph() async {
        guard !loaded else { return }
        guard let g = try? await library.client.graph() else { return }

        // trim to the strongest nodes — clarity over completeness
        var chosen: [GraphNode] = []
        for kind in ["person", "place", "tag"] {
            let cut = kind == "person" ? 26 : 20
            chosen += g.nodes.filter { $0.kind == kind }
                .sorted { $0.size > $1.size }.prefix(cut)
        }
        let ids = Set(chosen.map(\.id))
        var keptLinks = g.links.filter { ids.contains($0.a) && ids.contains($0.b) }
            .sorted { $0.w > $1.w }
        if keptLinks.count > 130 { keptLinks = Array(keptLinks.prefix(130)) }

        var adj: [String: Set<String>] = [:]
        for l in keptLinks {
            adj[l.a, default: []].insert(l.b)
            adj[l.b, default: []].insert(l.a)
        }

        // heavy lifting off-main: settle the layout completely
        let side = worldSide
        let radii = Dictionary(uniqueKeysWithValues: chosen.map {
            ($0.id, diameter($0) / 2)
        })
        let finalPos = await Task.detached(priority: .userInitiated) {
            GraphLayout.compute(nodes: chosen, links: keptLinks,
                                radii: radii, side: side)
        }.value

        nodes = chosen
        links = keptLinks
        adjacency = adj
        positions = finalPos
        loaded = true
        // entrance: everything springs from tiny to full, staggered
        withAnimation { appeared = true }
    }

    /// Local relaxation after a manual drag: a few solver rounds, then ONE
    /// animated settle of all affected nodes.
    private func reflow(around id: String) {
        let anchor = positions
        Task.detached(priority: .userInitiated) {
            let relaxed = GraphLayout.relax(from: anchor, nodes: nodes,
                                            links: links, pinned: id,
                                            side: worldSide, rounds: 60)
            await MainActor.run {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                    positions = relaxed
                }
            }
        }
    }

    // MARK: legend

    private var legend: some View {
        HStack(spacing: 14) {
            chip("Personen", GraphPalette.person)
            chip("Orte", GraphPalette.place)
            chip("Tags", GraphPalette.tag)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 10)
    }

    private func chip(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

enum GraphPalette {
    static let person = Color(red: 0.55, green: 0.58, blue: 0.98)
    static let place = Color(red: 0.36, green: 0.76, blue: 0.44)
    static let tag = Color(red: 0.85, green: 0.80, blue: 0.40)
}

// MARK: - Links (single static canvas)

private struct LinksCanvas: View {
    let links: [GraphLink]
    let positions: [String: CGPoint]
    let focus: String?
    let adjacency: [String: Set<String>]

    var body: some View {
        Canvas { ctx, _ in
            for l in links {
                guard let a = positions[l.a], let b = positions[l.b] else { continue }
                let active = focus == nil || l.a == focus || l.b == focus
                var path = Path()
                path.move(to: a)
                let mid = CGPoint(x: (a.x + b.x) / 2 + (b.y - a.y) * 0.07,
                                  y: (a.y + b.y) / 2 - (b.x - a.x) * 0.07)
                path.addQuadCurve(to: b, control: mid)
                let alpha = active ? min(0.28, 0.05 + Double(l.w) * 0.009) : 0.015
                ctx.stroke(path, with: .color(.white.opacity(alpha)),
                           lineWidth: active ? min(1.7, 0.5 + CGFloat(l.w) * 0.04) : 0.4)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: focus)
    }
}

// MARK: - Node view

private struct GraphNodeView: View {
    let node: GraphNode
    var library: Library
    let diameter: CGFloat
    let dimmed: Bool
    let focused: Bool

    @State private var pulse = false

    var body: some View {
        Group {
            switch node.kind {
            case "person": personView
            case "place": chipView(icon: "mappin", tint: GraphPalette.place)
            default: chipView(icon: "number", tint: GraphPalette.tag)
            }
        }
        .opacity(dimmed ? 0.12 : 1)
        .scaleEffect(focused ? 1.16 : (pulse ? 1.03 : 0.97))
        .shadow(color: focused ? .white.opacity(0.3) : .clear, radius: 12)
        .animation(.easeInOut(duration: 0.25), value: dimmed)
        .animation(.snappy(duration: 0.25), value: focused)
        .onAppear {
            // idle life: slow CA-driven pulse, cost-free for SwiftUI
            withAnimation(.easeInOut(duration: 2.6 + Double(abs(node.id.hashValue % 140)) / 100)
                .repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var personView: some View {
        VStack(spacing: 3) {
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
                GraphPalette.person.opacity(focused ? 1 : 0.7),
                lineWidth: focused ? 2.5 : 1.5))
            if !node.label.isEmpty {
                Text(node.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private func chipView(icon: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: max(8, diameter * 0.30), weight: .semibold))
            Text(node.label)
                .font(.system(size: max(9, diameter * 0.34), weight: .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, max(7, diameter * 0.30))
        .padding(.vertical, max(4, diameter * 0.17))
        .background(tint.opacity(0.28), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - Offline layout solver

/// Pure functions, run off-main. Classic force layout + collision resolution,
/// iterated to rest — the UI only ever sees finished positions.
enum GraphLayout {
    static func compute(nodes: [GraphNode], links: [GraphLink],
                        radii: [String: CGFloat], side: CGFloat) -> [String: CGPoint] {
        var pos: [String: CGPoint] = [:]
        let c = side / 2
        for (i, n) in nodes.enumerated() {
            let t = Double(i) / Double(max(nodes.count, 1))
            let angle = t * 2 * .pi * 3.7
            let r = 25 + t * 190
            pos[n.id] = CGPoint(x: c + cos(angle) * r, y: c + sin(angle) * r)
        }
        var vel: [String: CGVector] = [:]
        var alpha = 1.0
        for _ in 0..<520 {
            alpha *= 0.988
            step(&pos, &vel, nodes: nodes, links: links, radii: radii,
                 side: side, k: alpha, pinned: nil)
        }
        // final overlap cleanup
        for _ in 0..<40 { collide(&pos, nodes: nodes, radii: radii) }
        return pos
    }

    static func relax(from: [String: CGPoint], nodes: [GraphNode],
                      links: [GraphLink], pinned: String,
                      side: CGFloat, rounds: Int) -> [String: CGPoint] {
        var pos = from
        var vel: [String: CGVector] = [:]
        let radii = Dictionary(uniqueKeysWithValues: nodes.map { (n: GraphNode) in
            (n.id, n.kind == "person"
                ? min(58, 26 + sqrt(CGFloat(n.size)) * 1.5) / 2
                : min(30, 15 + sqrt(CGFloat(n.size)) * 0.8) / 2)
        })
        for i in 0..<rounds {
            let k = 0.35 * (1 - Double(i) / Double(rounds))
            step(&pos, &vel, nodes: nodes, links: links, radii: radii,
                 side: side, k: k, pinned: pinned)
        }
        for _ in 0..<25 { collide(&pos, nodes: nodes, radii: radii) }
        return pos
    }

    private static func step(_ pos: inout [String: CGPoint],
                             _ vel: inout [String: CGVector],
                             nodes: [GraphNode], links: [GraphLink],
                             radii: [String: CGFloat], side: CGFloat,
                             k: Double, pinned: String?) {
        let c = side / 2
        var force: [String: CGVector] = [:]

        for i in 0..<nodes.count {
            guard let pi = pos[nodes[i].id] else { continue }
            for j in (i + 1)..<nodes.count {
                guard let pj = pos[nodes[j].id] else { continue }
                var dx = pi.x - pj.x, dy = pi.y - pj.y
                var d2 = dx * dx + dy * dy
                if d2 > 26000 { continue }
                if d2 < 1 { d2 = 1; dx = 1; dy = 0 }
                let f = 600.0 / d2 * k
                force[nodes[i].id, default: .zero].dx += dx * f
                force[nodes[i].id, default: .zero].dy += dy * f
                force[nodes[j].id, default: .zero].dx -= dx * f
                force[nodes[j].id, default: .zero].dy -= dy * f
            }
        }
        for l in links {
            guard let pa = pos[l.a], let pb = pos[l.b] else { continue }
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let d = max(hypot(dx, dy), 0.01)
            let rest: CGFloat = 60 + 50 / CGFloat(min(l.w, 10))
            let f = (d - rest) / d * 0.05 * k * CGFloat(min(l.w, 6))
            force[l.a, default: .zero].dx += dx * f
            force[l.a, default: .zero].dy += dy * f
            force[l.b, default: .zero].dx -= dx * f
            force[l.b, default: .zero].dy -= dy * f
        }
        for n in nodes {
            if n.id == pinned { continue }
            guard let p = pos[n.id] else { continue }
            var v = vel[n.id] ?? .zero
            var f = force[n.id] ?? .zero
            f.dx -= (p.x - c) * 0.04 * k
            f.dy -= (p.y - c) * 0.04 * k
            v.dx = (v.dx + f.dx) * 0.78
            v.dy = (v.dy + f.dy) * 0.78
            vel[n.id] = v
            var np = CGPoint(x: p.x + v.dx, y: p.y + v.dy)
            let dc = hypot(np.x - c, np.y - c)
            let maxR = side * 0.46
            if dc > maxR {
                np = CGPoint(x: c + (np.x - c) / dc * maxR,
                             y: c + (np.y - c) / dc * maxR)
            }
            pos[n.id] = np
        }
    }

    /// Hard overlap resolution so avatars/chips never sit on each other.
    private static func collide(_ pos: inout [String: CGPoint],
                                nodes: [GraphNode], radii: [String: CGFloat]) {
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                let a = nodes[i].id, b = nodes[j].id
                guard var pa = pos[a], var pb = pos[b] else { continue }
                let minDist = (radii[a] ?? 15) + (radii[b] ?? 15) + 10
                var dx = pb.x - pa.x, dy = pb.y - pa.y
                var d = hypot(dx, dy)
                if d < 0.01 { dx = 1; dy = 0; d = 1 }
                if d < minDist {
                    let push = (minDist - d) / 2
                    pa.x -= dx / d * push; pa.y -= dy / d * push
                    pb.x += dx / d * push; pb.y += dy / d * push
                    pos[a] = pa; pos[b] = pb
                }
            }
        }
    }
}
