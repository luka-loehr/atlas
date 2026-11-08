import SwiftUI

/// A section title in the Photos style: bold, with an optional "See All".
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
                .font(.body)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }
}

/// Albums side by side, two rows when there are enough of them, scrolling
/// sideways a column at a time; the next column peeks in at the edge.
struct AlbumCarousel: View {
    var library: Library
    var albums: [Album]
    var placeholders = 0
    var menu: ((Album) -> AnyView)? = nil
    var open: (Album) -> Void

    private var rows: Int { albums.count > 4 || placeholders > 2 ? 2 : 1 }

    var body: some View {
        let count = albums.isEmpty ? placeholders : albums.count
        let columns = stride(from: 0, to: count, by: rows).map { $0..<min($0 + rows, count) }
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(columns, id: \.lowerBound) { range in
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(range, id: \.self) { i in
                            if let album = albums[safe: i] {
                                Button { open(album) } label: { AlbumTile(library: library, album: album) }
                                    .buttonStyle(.plain)
                                    .contextMenu { menu?(album) }
                            } else {
                                AlbumTile.placeholder
                            }
                        }
                    }
                    // two full columns and a peek of the third
                    .containerRelativeFrame(.horizontal) { width, _ in
                        max(120, (width - 40 - 14 * 2) / 2.18)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .padding(.bottom, 8)
    }
}

/// One album: a large rounded square cover, the title and the count.
struct AlbumTile: View {
    var library: Library
    var album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { CoverImage(library: library, id: album.cover) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(album.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.top, 7)
            Text(album.count, format: .number)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(album.title)
        .accessibilityValue("\(album.count) \(album.count == 1 ? "item" : "items")")
        .accessibilityAddTraits(.isButton)
    }

    static var placeholder: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemFill))
                .aspectRatio(1, contentMode: .fit)
            Text("Album").font(.subheadline).padding(.top, 7)
            Text("00").font(.subheadline)
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

/// An album cover: the grid thumbnail at once (it is on the phone), then
/// the sharp preview decoded at the size the cover is shown.
struct CoverImage: View {
    var library: Library
    var id: String?
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geo in
            let px = (max(geo.size.width, geo.size.height) * scale * 1.5).rounded(.up)
            ZStack {
                Rectangle().fill(Color(.secondarySystemFill))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if id == nil {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: "\(id ?? "")@\(Int(px))") { await load(px) }
        }
        .accessibilityHidden(true)
    }

    private func load(_ px: CGFloat) async {
        guard let id, px > 0,
              let small = library.client.thumbURL(id, 512),
              let big = library.client.thumbURL(id, 2048) else { return }
        let cache = MediaCache.shared
        if let sharp = cache.cached(big, maxPixel: px) { image = sharp; return }
        if image == nil {
            image = cache.cached(small)
            if image == nil { image = await cache.load(small) }
        }
        if let sharp = await cache.load(big, maxPixel: px) { image = sharp }
    }
}

/// A row of Media Types or Utilities: symbol, title, count, chevron.
struct CollectionRow: View {
    let kind: SpecialKind
    let count: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: kind.icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(kind.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if kind == .locked {
                    Image(systemName: "faceid")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                } else if let count {
                    Text(count, format: .number)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.forward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .accessibilityValue(kind == .locked ? "Locked" : count.map { "\($0) \($0 == 1 ? "item" : "items")" } ?? "")
    }
}

/// The grey highlight a list row shows while pressed.
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemFill) : .clear)
    }
}

/// A spinner in a rounded box over a collection while a change runs.
struct BusyBox: View {
    var body: some View {
        ProgressView().padding(20)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
