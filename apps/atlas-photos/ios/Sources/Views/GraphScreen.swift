import SwiftUI

// MARK: - Payload (GET /api/graph)

struct GraphNode: Codable, Identifiable {
    let id: String
    let label: String
    let kind: String     // person | place | tag
    let size: Int
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

/// Obsidian-style force-directed knowledge graph: persons, places and tags as
/// glowing dots, co-occurrence as links. Physics runs live on a Canvas;
/// pinch to zoom, drag to pan, tap a node to focus its neighborhood.
struct GraphScreen: View {
    var library: Library

    @State private var sim = GraphSim()
    @State private var loaded = false
    @State private var selected: String?

    // viewport transform
    @State private var scale: CGFloat = 1
    @State private var pinchBase: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragBase: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if loaded {
                TimelineView(.animation) { _ in
                    Canvas { ctx, size in
                        sim.step()
                        draw(ctx: ctx, size: size)
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture.simultaneously(with: pinchGesture))
                .onTapGesture { pt in select(at: pt) }
            } else {
                ProgressView().tint(.white)
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
        .task {
            guard !loaded else { return }
            if let g = try? await library.client.graph() {
                sim.load(nodes: g.nodes, links: g.links)
                loaded = true
            }
        }
    }

    // MARK: gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                offset = CGSize(width: dragBase.width + v.translation.width,
                                height: dragBase.height + v.translation.height)
            }
            .onEnded { _ in dragBase = offset }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in scale = min(4, max(0.35, pinchBase * v.magnification)) }
            .onEnded { _ in pinchBase = scale }
    }

    private func select(at pt: CGPoint) {
        // screen -> world
        let size = UIScreen.main.bounds.size
        let wx = (pt.x - size.width / 2 - offset.width) / scale
        let wy = (pt.y - size.height / 2 - offset.height) / scale
        if let hit = sim.nearest(to: CGPoint(x: wx, y: wy), maxDist: 26 / scale) {
            withAnimation(.snappy) { selected = (selected == hit) ? nil : hit }
        } else {
            withAnimation(.snappy) { selected = nil }
        }
    }

    // MARK: drawing

    private func draw(ctx: GraphicsContext, size: CGSize) {
        var ctx = ctx
        ctx.translateBy(x: size.width / 2 + offset.width,
                        y: size.height / 2 + offset.height)
        ctx.scaleBy(x: scale, y: scale)

        let neighbors = selected.map { sim.neighbors(of: $0) }

        // links
        for l in sim.links {
            guard let pa = sim.pos[l.a], let pb = sim.pos[l.b] else { continue }
            let active = neighbors == nil
                || (l.a == selected || l.b == selected)
            var path = Path()
            path.move(to: pa)
            path.addLine(to: pb)
            let alpha = active ? min(0.42, 0.05 + Double(l.w) * 0.012) : 0.02
            ctx.stroke(path, with: .color(.white.opacity(alpha)),
                       lineWidth: active ? min(2.2, 0.4 + CGFloat(l.w) * 0.05) : 0.4)
        }

        // nodes
        for n in sim.nodes {
            guard let p = sim.pos[n.id] else { continue }
            let dimmed = neighbors != nil && n.id != selected
                && !(neighbors?.contains(n.id) ?? false)
            let r = sim.radius(n)
            let color = Self.color(for: n.kind).opacity(dimmed ? 0.14 : 1)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            // soft glow
            if !dimmed && r > 6 {
                ctx.fill(Path(ellipseIn: rect.insetBy(dx: -r * 0.55, dy: -r * 0.55)),
                         with: .color(Self.color(for: n.kind).opacity(0.16)))
            }
            ctx.fill(Path(ellipseIn: rect), with: .color(color))

            // labels: named persons, big nodes, or the selection
            let name = n.label.isEmpty
                ? (n.kind == "person" ? "" : n.label)
                : n.label
            let show = !dimmed && (n.id == selected || (!name.isEmpty && r > 6.5))
            if show, !name.isEmpty {
                let text = Text(name)
                    .font(.system(size: n.id == selected ? 11 : 8.5,
                                  weight: n.id == selected ? .bold : .medium))
                    .foregroundStyle(.white.opacity(n.id == selected ? 1 : 0.75))
                ctx.draw(ctx.resolve(text), at: CGPoint(x: p.x, y: p.y + r + 7))
            }
        }
    }

    static func color(for kind: String) -> Color {
        switch kind {
        case "person": return Color(red: 0.55, green: 0.58, blue: 0.98)   // violett-blau
        case "place":  return Color(red: 0.36, green: 0.76, blue: 0.44)   // grün
        default:       return Color(red: 0.85, green: 0.84, blue: 0.40)   // gelbgrün (tag)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            chip("Personen", Self.color(for: "person"))
            chip("Orte", Self.color(for: "place"))
            chip("Tags", Self.color(for: "tag"))
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

// MARK: - Physics

/// d3-style force simulation: link springs + n-body repulsion + centering,
/// with alpha decay so the layout settles and stops burning CPU.
@Observable
final class GraphSim {
    var nodes: [GraphNode] = []
    var links: [GraphLink] = []
    var pos: [String: CGPoint] = [:]
    private var vel: [String: CGVector] = [:]
    private var adj: [String: Set<String>] = [:]
    private var alpha: Double = 0

    func load(nodes: [GraphNode], links: [GraphLink]) {
        self.nodes = nodes
        self.links = links
        adj = [:]
        for l in links {
            adj[l.a, default: []].insert(l.b)
            adj[l.b, default: []].insert(l.a)
        }
        // deterministic ring start (hash-seeded) — no Date/random needed
        for (i, n) in nodes.enumerated() {
            let angle = Double(i) / Double(max(nodes.count, 1)) * 2 * .pi
            let ring = 90.0 + Double(abs(n.id.hashValue) % 90)
            pos[n.id] = CGPoint(x: cos(angle) * ring, y: sin(angle) * ring)
            vel[n.id] = .zero
        }
        alpha = 1
    }

    func radius(_ n: GraphNode) -> CGFloat {
        3 + min(15, sqrt(CGFloat(n.size)) * 0.75)
    }

    func neighbors(of id: String) -> Set<String> { adj[id] ?? [] }

    func nearest(to p: CGPoint, maxDist: CGFloat) -> String? {
        var best: (String, CGFloat)?
        for n in nodes {
            guard let q = pos[n.id] else { continue }
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < maxDist + radius(n), d < (best?.1 ?? .infinity) {
                best = (n.id, d)
            }
        }
        return best?.0
    }

    func step() {
        guard alpha > 0.003 else { return }
        alpha *= 0.995
        let k = alpha

        var force: [String: CGVector] = [:]

        // n-body repulsion
        let arr = nodes
        for i in 0..<arr.count {
            guard let pi = pos[arr[i].id] else { continue }
            for j in (i + 1)..<arr.count {
                guard let pj = pos[arr[j].id] else { continue }
                var dx = pi.x - pj.x
                var dy = pi.y - pj.y
                var d2 = dx * dx + dy * dy
                if d2 < 1 { d2 = 1; dx = 1; dy = 0 }
                let f = 900.0 / d2 * k
                let fx = dx * f, fy = dy * f
                force[arr[i].id, default: .zero].dx += fx
                force[arr[i].id, default: .zero].dy += fy
                force[arr[j].id, default: .zero].dx -= fx
                force[arr[j].id, default: .zero].dy -= fy
            }
        }

        // link springs (stronger + shorter for heavier links)
        for l in links {
            guard let pa = pos[l.a], let pb = pos[l.b] else { continue }
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let d = max(hypot(dx, dy), 0.01)
            let rest: CGFloat = 46 + 60 / CGFloat(min(l.w, 12))
            let f = (d - rest) / d * 0.09 * k * CGFloat(min(l.w, 8))
            force[l.a, default: .zero].dx += dx * f
            force[l.a, default: .zero].dy += dy * f
            force[l.b, default: .zero].dx -= dx * f
            force[l.b, default: .zero].dy -= dy * f
        }

        // centering + integrate
        for n in nodes {
            guard let p = pos[n.id] else { continue }
            var v = vel[n.id] ?? .zero
            var f = force[n.id] ?? .zero
            f.dx -= p.x * 0.012 * k
            f.dy -= p.y * 0.012 * k
            v.dx = (v.dx + f.dx) * 0.82
            v.dy = (v.dy + f.dy) * 0.82
            vel[n.id] = v
            pos[n.id] = CGPoint(x: p.x + v.dx, y: p.y + v.dy)
        }
    }
}
