import SwiftUI

struct AccountSheet: View {
    var library: Library
    @AppStorage("photos.host") private var host = "atlas.your-tailnet.ts.net:8788"
    @Environment(\.dismiss) private var dismiss
    @State private var sync: DeviceSync?
    @State private var showSync = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        header
                        if let s = library.stats {
                            statsGrid(s)
                            span(s)
                        }
                        settingsLink
                        hostRow
                    }
                    .padding(20)
                }
            }
            .navigationTitle("atlas Fotos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .task { if sync == nil { sync = DeviceSync(client: library.client) } }
        .sheet(isPresented: $showSync) { if let sync { SyncProgressView(sync: sync) } }
    }

    private var settingsLink: some View {
        NavigationLink {
            SettingsScreen(
                library: library,
                onSyncNow: { startSync(delete: false) },
                onCleanupDevice: { startSync(delete: true) },
                onEmptyTrash: { Task { try? await library.client.emptyTrash(); await library.loadStats() } })
        } label: {
            HStack {
                Image(systemName: "gearshape.fill").foregroundStyle(.blue)
                Text("Einstellungen & iPhone-Sync")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(.white.opacity(0.3))
            }
            .padding(14)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func startSync(delete: Bool) {
        guard let sync else { return }
        showSync = true
        Task {
            guard await sync.requestAccess() else { return }
            await sync.scan()
            if delete { await sync.deleteBackedUpFromDevice() }
            else { await sync.backupNew() }
            await library.loadStats()
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.blue, .purple],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
            }
            Text("Deine Bibliothek")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            HStack(spacing: 6) {
                Circle().fill(library.online ? .green : .red).frame(width: 7, height: 7)
                Text(library.online ? "mit atlas verbunden" : "offline")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func statsGrid(_ s: LibraryStats) -> some View {
        HStack(spacing: 12) {
            stat("\(s.total - s.videos)", "Fotos", "photo")
            stat("\(s.videos)", "Videos", "video")
            stat("\(s.albums)", "Alben", "rectangle.stack")
            stat(bytes(s.bytes), "Größe", "internaldrive")
        }
    }

    private func stat(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.blue)
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func span(_ s: LibraryStats) -> some View {
        Group {
            if let o = s.oldest, let n = s.newest {
                Text("\(o.formatted(.dateTime.month().year())) – \(n.formatted(.dateTime.month().year()))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var hostRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SERVER")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            HStack {
                Image(systemName: "server.rack").foregroundStyle(.white.opacity(0.5))
                TextField("host:port", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(.white.opacity(0.8))
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit { library.host = host; Task { await library.refresh() } }
            }
            .padding(12)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func bytes(_ b: Int64) -> String {
        let gb = Double(b) / 1_073_741_824
        return gb >= 1 ? String(format: "%.0f GB", gb)
                       : String(format: "%.0f MB", Double(b) / 1_048_576)
    }
}
