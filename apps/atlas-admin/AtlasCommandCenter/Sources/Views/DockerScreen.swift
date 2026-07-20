import SwiftUI

@MainActor
@Observable
final class DockerModel {
    var containers: [Metrics.Container] = []
    var error: String?
    var host = ""
    var token = ""

    private var client: AtlasClient { AtlasClient(host: host, token: token.isEmpty ? nil : token) }

    func load() async {
        do { containers = try await client.containers(); error = nil }
        catch { self.error = "atlas nicht erreichbar" }
    }

    func inspect(_ name: String) async -> ContainerDetail? {
        try? await client.inspect(name)
    }
}

struct DockerScreen: View {
    var host: String
    var token: String
    @State private var model = DockerModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                ScrollView {
                    VStack(spacing: 14) {
                        if model.containers.isEmpty {
                            emptyState
                        } else {
                            ForEach(model.containers) { c in
                                NavigationLink {
                                    ContainerDetailView(model: model, name: c.name)
                                } label: {
                                    ContainerRow(container: c)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.load() }
            }
            .navigationTitle("Docker")
            .navigationBarTitleDisplayMode(.large)
        }
        .task {
            model.host = host
            model.token = token
            await model.load()
        }
    }

    private var emptyState: some View {
        GlassCard(padding: 24) {
            VStack(spacing: 10) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.4))
                Text(model.error ?? "keine laufenden Container")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 40)
    }
}

struct ContainerRow: View {
    var container: Metrics.Container

    var body: some View {
        GlassCard {
            HStack(spacing: 12) {
                Circle()
                    .fill(Theme.good)
                    .frame(width: 9, height: 9)
                    .shadow(color: Theme.good.opacity(0.6), radius: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(container.name)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.middle)
                    Text(container.image ?? "")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.accent.opacity(0.9))
                    Text(container.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }
}

struct ContainerDetailView: View {
    var model: DockerModel
    var name: String
    @State private var detail: ContainerDetail?

    var body: some View {
        ZStack {
            Theme.background
            ScrollView {
                VStack(spacing: 14) {
                    if let d = detail {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                field("Status", d.state, tint: d.state == "running" ? Theme.good : Theme.warn)
                                field("Image", d.image, mono: true)
                                field("Ports", d.ports.isEmpty ? "—" : d.ports, mono: true)
                                field("Restarts", "\(d.restarts)")
                                field("Started", d.started, mono: true)
                            }
                        }
                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Logs", systemImage: "text.alignleft")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                ScrollView(.horizontal, showsIndicators: false) {
                                    Text(d.logs.isEmpty ? "(keine Logs)" : d.logs)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.75))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    } else {
                        ProgressView().tint(.white).padding(.top, 60)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { detail = await model.inspect(name) }
        .refreshable { detail = await model.inspect(name) }
    }

    private func field(_ label: String, _ value: String, tint: Color = .white, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: mono ? .monospaced : .default))
                .foregroundStyle(tint)
                .lineLimit(2).truncationMode(.middle)
            Spacer()
        }
    }
}
