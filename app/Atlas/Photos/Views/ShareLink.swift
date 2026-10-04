import SwiftUI
import UIKit

/// Photos or an album on their way to a share link, for `.sheet(item:)`.
struct ShareLinkItem: Identifiable {
    let id = UUID()
    let title: String
    var ids: [String] = []
    var album: Int? = nil

    /// The days of the photos, as the Library header names them.
    static func title(for assets: [Asset]) -> String {
        let dates = assets.compactMap(\.takenAt)
        guard let first = dates.min(), let last = dates.max() else { return "Photos" }
        if Calendar.current.isDate(first, inSameDayAs: last) { return day.string(from: first) }
        return range.string(from: first, to: last)
    }

    private static let range: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateTemplate = "dMMMyyyy"
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        return f
    }()
}

/// "Share as Link": title, expiry, originals and a password, then the
/// upload's progress and the link. Closing while it uploads is fine, the
/// server keeps going (the link is under Settings › Shared Links).
struct ShareLinkSheet: View {
    var library: Library
    let item: ShareLinkItem
    var created: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var days = 7
    @State private var originals = false
    @State private var protect = false
    @State private var password = ""
    @State private var share: Share?
    @State private var creating = false
    @State private var failed = false
    @State private var notSetUp = false
    @State private var copied = false
    @State private var sending: LinkSend?

    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool { !cleanTitle.isEmpty && (!protect || !password.isEmpty) && !creating }

    var body: some View {
        NavigationStack {
            Form {
                if let share { status(share) } else { form }
            }
            .navigationTitle("Share Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(share == nil ? "Cancel" : "Done", systemImage: "xmark") { dismiss() }
                }
            }
            .task(id: share?.id) { await poll() }
            .onChange(of: share?.state) { old, new in
                if old == .uploading, new == .ready { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            }
            .sheet(item: $sending) { send in
                ActivitySheet(items: send.items).presentationDetents([.medium, .large])
            }
            .changeFailedAlert($failed)
            .alert("Sharing Isn’t Set Up", isPresented: $notSetUp) {
                Button("OK", role: .cancel) {}
            }
        }
        .onAppear { if title.isEmpty { title = item.title } }
        #if targetEnvironment(simulator)
        .onAppear { share = share ?? Self.demo() }
        #endif
    }

    @ViewBuilder private var form: some View {
        Section {
            TextField("Title", text: $title)
        }
        Section {
            Picker("Expires", selection: $days) {
                Text("1 Day").tag(1)
                Text("3 Days").tag(3)
                Text("7 Days").tag(7)
            }
            Toggle("Include Originals", isOn: $originals)
            Toggle("Password", isOn: $protect.animation())
            if protect {
                TextField("Password", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        Section {
            Button { create() } label: {
                if creating {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Create Link").frame(maxWidth: .infinity)
                }
            }
            .disabled(!canCreate)
        }
    }

    @ViewBuilder private func status(_ s: Share) -> some View {
        switch s.state {
        case .uploading:
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Uploading…")
                        Spacer()
                        Text(s.count == 1 ? "1 Item" : "\(s.count.formatted()) Items")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: s.progress ?? 0)
                    Text("\(Self.mb(s.doneBytes)) of \(Self.mb(s.totalBytes))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 4)
            } header: {
                Text(s.title)
            }
        case .ready:
            Section(s.title) {
                Text(s.url.absoluteString)
                    .foregroundStyle(.tint)
                    .textSelection(.enabled)
                if s.hasPassword, !password.isEmpty {
                    LabeledContent("Password", value: password)
                }
            }
            Section {
                Button(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.url = s.url
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation { copied = true }
                }
                Button("Share…", systemImage: "square.and.arrow.up") {
                    sending = LinkSend(s, password: s.hasPassword ? password : nil)
                }
            }
        case .failed:
            Section(s.title) {
                Label(s.error ?? "The upload failed.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Section {
                Button { create(replacing: s) } label: {
                    if creating {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Try Again").frame(maxWidth: .infinity)
                    }
                }
                .disabled(creating)
            }
        }
    }

    /// The share again about once a second while it uploads.
    private func poll() async {
        while let s = share, s.state == .uploading {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            if let fresh = try? await library.client.share(s.id), fresh.id == share?.id { share = fresh }
        }
    }

    /// A failed share is removed first, so its leftovers do not wait for the expiry.
    private func create(replacing old: Share? = nil) {
        creating = true
        Task {
            defer { creating = false }
            if let old { try? await library.client.stopSharing(old.id) }
            do {
                let s = try await library.client.createShare(
                    title: cleanTitle, ids: item.album == nil ? item.ids : nil, album: item.album,
                    days: days, allowDownload: originals, password: protect ? password : nil)
                copied = false
                withAnimation { share = s }
                created()
            } catch ShareError.notSetUp {
                notSetUp = true
            } catch {
                failed = true
            }
        }
    }

    static func mb(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    #if targetEnvironment(simulator)
    /// ATLAS_SHARE_DEMO=uploading|ready|failed shows the sheet in that state.
    private static func demo() -> Share? {
        guard let state = ProcessInfo.processInfo.environment["ATLAS_SHARE_DEMO"].flatMap(Share.State.init) else { return nil }
        return Share(id: "4fQ2xV7bLk9TzR1mWc3NaE", title: "Zrmanja Rafting",
                     url: URL(string: "https://atlas-share.example.workers.dev/s/4fQ2xV7bLk9TzR1mWc3NaE")!,
                     createdAt: .now, expiresAt: .now.addingTimeInterval(7 * 86400), state: state,
                     doneBytes: 41_200_000, totalBytes: 98_700_000, count: 39, cover: nil, albumID: nil,
                     allowDownload: false, hasPassword: false,
                     error: state == .failed ? "atlas-share did not answer." : nil)
    }
    #endif
}

/// Settings › Shared Links: every live link; tap for the link, swipe to stop.
struct SharedLinksScreen: View {
    var library: Library

    @State private var shares: [Share] = []
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var stopping: Share?
    @State private var sending: LinkSend?
    @State private var failed = false

    var body: some View {
        Group {
            if shares.isEmpty {
                if loaded {
                    ContentUnavailableView("No Shared Links", systemImage: "link")
                } else {
                    LoadingOrUnavailable(loaded: loadFailed)
                }
            } else {
                List {
                    ForEach(shares) { share in
                        Menu {
                            if share.state == .ready {
                                Button("Copy Link", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.url = share.url
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                }
                                Button("Share…", systemImage: "square.and.arrow.up") { sending = LinkSend(share) }
                            }
                            Button("Stop Sharing", systemImage: "xmark.circle", role: .destructive) { stopping = share }
                        } label: {
                            SharedLinkRow(library: library, share: share)
                        }
                        .swipeActions {
                            Button("Stop Sharing") { stopping = share }.tint(.red)
                        }
                    }
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("Shared Links")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            while !Task.isCancelled, shares.contains(where: { $0.state == .uploading }) {
                try? await Task.sleep(for: .seconds(1))
                await load()
            }
        }
        .confirmationDialog("Stop Sharing “\(stopping?.title ?? "")”?",
                            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                            titleVisibility: .visible, presenting: stopping) { share in
            Button("Stop Sharing", role: .destructive) { stop(share) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $sending) { send in
            ActivitySheet(items: send.items).presentationDetents([.medium, .large])
        }
        .changeFailedAlert($failed)
    }

    private func load() async {
        do {
            shares = try await library.client.shares()
            loaded = true
        } catch {
            loadFailed = true
        }
    }

    private func stop(_ share: Share) {
        Task {
            do {
                try await library.client.stopSharing(share.id)
                withAnimation { shares.removeAll { $0.id == share.id } }
            } catch {
                failed = true
            }
        }
    }
}

private struct SharedLinkRow: View {
    var library: Library
    let share: Share

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Rectangle().fill(Color(.secondarySystemFill))
                if let cover = share.cover {
                    Thumb(url: library.client.thumbURL(cover, 512))
                } else {
                    Image(systemName: "link").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(share.title).lineLimit(1)
                    if share.hasPassword {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                switch share.state {
                case .uploading:
                    ProgressView(value: share.progress ?? 0)
                case .ready:
                    Text(share.expiresText).font(.subheadline).foregroundStyle(.secondary)
                case .failed:
                    Text("Upload Failed").font(.subheadline).foregroundStyle(.red)
                }
            }
        }
    }
}

extension Share {
    /// "Expires in 6 days", "Expires tomorrow", "Expires today".
    var expiresText: String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: expiresAt)).day ?? 0
        switch days {
        case ..<1: return "Expires today"
        case 1: return "Expires tomorrow"
        default: return "Expires in \(days) days"
        }
    }
}

/// The link for the system share sheet, with the password as text when it has one.
private struct LinkSend: Identifiable {
    let id = UUID()
    let items: [Any]

    init(_ share: Share, password: String? = nil) {
        var items: [Any] = [share.url]
        if let password, !password.isEmpty { items.append("Password: \(password)") }
        self.items = items
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
