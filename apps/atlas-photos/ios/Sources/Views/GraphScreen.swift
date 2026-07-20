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

/// Living knowledge graph: persons appear as their actual face avatars,
/// places and tags as glass chips, connected by soft links. Everything is
/// touchable — drag a node and the whole graph reacts, pinch to zoom, pan
/// around, tap a person to open their photos. The layout never fully sleeps,
/// so the graph keeps gently breathing.
struct GraphScreen: View {
    var library: Library

    @State private var sim = GraphSim()
    @State private var loaded = false
    @State private var focus: String?
    @State private var openPerson: Person?

    // viewport
    @State private var scale: CGFloat = 0.9
    @State private var pinchBase: CGFloat = 0.9
    @State private var offset: CGSize = .zero
    @State private var dragBase: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if loaded {
                    // links live on a cheap Canvas below the node views
                    TimelineView(.animation) { _ in
                        Canvas { ctx, size in
                            sim.step()
                            drawLinks(ctx: ctx, size: size)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(boardDrag.simultaneously(with: pinch))
                    .onTapGesture { withAnimation(.snappy) { focus = nil } }

                    // nodes as real SwiftUI views
                    TimelineView(.animation) { _ in
                        nodeLayer(center: CGPoint(x: geo.size.width / 2,
                                                  y: geo.size.height / 2))
                    }
                    .allowsHitTesting(true)
                } else {
                    ProgressView().tint(.white)
                }

                VStack {
                    Spacer()
                    legend
                }
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
        .task {
            guard !loaded else { return }
            if let g = try? await library.client.graph() {
                sim.load(nodes: g.nodes, links: g.links)
                loaded = true
            }
        }
    }

    // MARK: transform helpers

    private func toScreen(_ p: CGPoint, center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + (p.x * scale) + offset.width,
                y: center.y + (p.y * scale) + offset.height)
    }

    private func toWorld(_ p: CGPoint, center: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - center.x - offset.width) / scale,
                y: (p.y - center.y - offset.height) / scale)
    }

    // MARK: gestures

    private var boardDrag: some Gesture {
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

    // MARK: node layer

    @ViewBuilder
    private func nodeLayer(center: CGPoint) -> some View {
        let dimmedSet: Set<String>? = focus.map { f in
            var keep = sim.neighbors(of: f)
            keep.insert(f)
            return keep
        }
        ForEach(sim.nodes) { node in
            let p = toScreen(sim.pos[node.id] ?? .zero, center: center)
            let dimmed = dimmedSet.map { !$0.contains(node.id) } ?? false
            NodeView(node: node, library: library,
                     diameter: sim.diameter(node) * scale,
                     dimmed: dimmed, focused: focus == node.id)
                .position(p)
                .gesture(nodeDrag(node.id, center: center))
                .onTapGesture { tap(node) }
                .animation(.easeInOut(duration: 0.25), value: dimmed)
        }
    }

    private func nodeDrag(_ id: String, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                sim.grab(id, at: toWorld(v.location, center: center))
            }
            .onEnded { _ in sim.release(id) }
    }

    private func tap(_ node: GraphNode) {
        if node.kind == "person", focus == node.id {
            // second tap opens the person
            let pid = Int64(node.id.dropFirst()) ?? 0
            openPerson = Person(id: pid,
                                name: node.label.isEmpty ? nil : node.label,
                                coverFace: node.cover, photos: node.size)
            return
        }
        withAnimation(.snappy) { focus = (focus == node.id) ? nil : node.id }
        sim.poke()
    }

    // MARK: links

    private func drawLinks(ctx: GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let keep: Set<String>? = focus.map { f in
            var k = sim.neighbors(of: f); k.insert(f); return k
        }
        for l in sim.links {
            guard let pa = sim.pos[l.a], let pb = sim.pos[l.b] else { continue }
            let active = keep == nil || (l.a == focus || l.b == focus)
            let a = toScreen(pa, center: center)
            let b = toScreen(pb, center: center)
            var path = Path()
            path.move(to: a)
            // soft curve instead of harsh straight spaghetti
            let mid = CGPoint(x: (a.x + b.x) / 2 + (b.y - a.y) * 0.06,
                              y: (a.y + b.y) / 2 - (b.x - a.x) * 0.06)
            path.addQuadCurve(to: b, control: mid)
            let alpha = active ? min(0.30, 0.05 + Double(l.w) * 0.010) : 0.015
            ctx.stroke(path, with: .color(.white.opacity(alpha)),
                       lineWidth: (active ? min(1.8, 0.5 + CGFloat(l.w) * 0.04) : 0.4) * scale)
        }
    }

    // MARK: legend

    private var legend: some View {
        HStack(spacing: 14) {
            chip("Personen", Color(red: 0.55, green: 0.58, blue: 0.98))
            chip("Orte", Color(red: 0.36, green: 0.76, blue: 0.44))
            chip("Tags", Color(red: 0.85, green: 0.80, blue: 0.40))
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

// MARK: - Node view

/// A single graph node: persons render their real face avatar with a colored
/// ring, places and tags render as small glass chips.
private struct NodeView: View {
    let node: GraphNode
    var library: Library
    let diameter: CGFloat
    let dimmed: Bool
    let focused: Bool

    var body: some View {
        Group {
            switch node.kind {
            case "person": personView
            case "place": chipView(icon: "mappin",
                                   tint: Color(red: 0.36, green: 0.76, blue: 0.44))
            default: chipView(icon: "number",
                              tint: Color(red: 0.85, green: 0.80, blue: 0.40))
            }
        }
        .opacity(dimmed ? 0.13 : 1)
        .scaleEffect(focused ? 1.18 : 1)
        .shadow(color: focused ? .white.opacity(0.25) : .clear, radius: 10)
        .animation(.snappy(duration: 0.25), value: focused)
    }

    private var personView: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.55, green: 0.58, blue: 0.98).opacity(0.25))
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
                Color(red: 0.55, green: 0.58, blue: 0.98)
                    .opacity(focused ? 1 : 0.7),
                lineWidth: focused ? 2.5 : 1.5))
            if !node.label.isEmpty || focused {
                Text(node.label.isEmpty ? "\(node.size)" : node.label)
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
                .font(.system(size: max(7, diameter * 0.28), weight: .semibold))
            Text(node.label)
                .font(.system(size: max(8, diameter * 0.32), weight: .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, max(6, diameter * 0.28))
        .padding(.vertical, max(3, diameter * 0.16))
        .background(tint.opacity(0.30), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.65), lineWidth: 1))
    }
}

// MARK: - Physics

/// Tamed d3-style force layout that never fully sleeps: repulsion is range-
/// limited, centering is firm, positions are clamped — no more exploding
/// hairball — and a small alpha floor keeps the graph breathing.
@Observable
final class GraphSim {
    var nodes: [GraphNode] = []
    var links: [GraphLink] = []
    var pos: [String: CGPoint] = [:]
    private var vel: [String: CGVector] = [:]
    private var adj: [String: Set<String>] = [:]
    private var alpha: Double = 0
    private var grabbed: String?

    private let maxNodes = 70
    private let worldRadius: CGFloat = 300

    func load(nodes allNodes: [GraphNode], links allLinks: [GraphLink]) {
        // trim to the strongest nodes per kind — beauty over completeness
        var chosen: [GraphNode] = []
        for kind in ["person", "place", "tag"] {
            let cut = kind == "person" ? 26 : 22
            chosen += allNodes.filter { $0.kind == kind }
                .sorted { $0.size > $1.size }
                .prefix(cut)
        }
        chosen = Array(chosen.prefix(maxNodes))
        let ids = Set(chosen.map(\.id))
        nodes = chosen
        links = allLinks
            .filter { ids.contains($0.a) && ids.contains($0.b) }
            .sorted { $0.w > $1.w }
        if links.count > 140 { links = Array(links.prefix(140)) }

        adj = [:]
        for l in links {
            adj[l.a, default: []].insert(l.b)
            adj[l.b, default: []].insert(l.a)
        }

        // compact deterministic spiral start — grows outward from the center
        for (i, n) in nodes.enumerated() {
            let t = Double(i) / Double(max(nodes.count, 1))
            let angle = t * 2 * .pi * 3.7
            let r = 20 + t * 150
            pos[n.id] = CGPoint(x: cos(angle) * r, y: sin(angle) * r)
            vel[n.id] = .zero
        }
        alpha = 1
    }

    /// Visual size in world points: persons are avatars, chips scale gently.
    func diameter(_ n: GraphNode) -> CGFloat {
        if n.kind == "person" {
            return min(56, 24 + sqrt(CGFloat(n.size)) * 1.6)
        }
        return min(30, 15 + sqrt(CGFloat(n.size)) * 0.9)
    }

    func neighbors(of id: String) -> Set<String> { adj[id] ?? [] }

    /// re-energize (after focus changes etc.)
    func poke() { alpha = max(alpha, 0.25) }

    func grab(_ id: String, at p: CGPoint) {
        grabbed = id
        pos[id] = clamp(p)
        vel[id] = .zero
        alpha = max(alpha, 0.45)
    }

    func release(_ id: String) {
        if grabbed == id { grabbed = nil }
        alpha = max(alpha, 0.35)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        let d = hypot(p.x, p.y)
        guard d > worldRadius else { return p }
        return CGPoint(x: p.x / d * worldRadius, y: p.y / d * worldRadius)
    }

    func step() {
        // alpha floor: the graph keeps gently moving forever
        alpha = max(alpha * 0.992, 0.018)
        let k = alpha

        var force: [String: CGVector] = [:]

        // range-limited repulsion (no long-distance explosion)
        let arr = nodes
        for i in 0..<arr.count {
            guard let pi = pos[arr[i].id] else { continue }
            for j in (i + 1)..<arr.count {
                guard let pj = pos[arr[j].id] else { continue }
                var dx = pi.x - pj.x
                var dy = pi.y - pj.y
                var d2 = dx * dx + dy * dy
                if d2 > 22500 { continue }          // > 150pt apart: ignore
                if d2 < 1 { d2 = 1; dx = 1; dy = 0 }
                let f = 520.0 / d2 * k
                force[arr[i].id, default: .zero].dx += dx * f
                force[arr[i].id, default: .zero].dy += dy * f
                force[arr[j].id, default: .zero].dx -= dx * f
                force[arr[j].id, default: .zero].dy -= dy * f
            }
        }

        // springs
        for l in links {
            guard let pa = pos[l.a], let pb = pos[l.b] else { continue }
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let d = max(hypot(dx, dy), 0.01)
            let rest: CGFloat = 55 + 50 / CGFloat(min(l.w, 10))
            let f = (d - rest) / d * 0.06 * k * CGFloat(min(l.w, 6))
            force[l.a, default: .zero].dx += dx * f
            force[l.a, default: .zero].dy += dy * f
            force[l.b, default: .zero].dx -= dx * f
            force[l.b, default: .zero].dy -= dy * f
        }

        // firm centering + integrate + clamp
        for n in nodes {
            if n.id == grabbed { continue }         // finger owns it
            guard let p = pos[n.id] else { continue }
            var v = vel[n.id] ?? .zero
            var f = force[n.id] ?? .zero
            f.dx -= p.x * 0.045 * k
            f.dy -= p.y * 0.045 * k
            v.dx = (v.dx + f.dx) * 0.80
            v.dy = (v.dy + f.dy) * 0.80
            vel[n.id] = v
            pos[n.id] = clamp(CGPoint(x: p.x + v.dx, y: p.y + v.dy))
        }
    }
}
