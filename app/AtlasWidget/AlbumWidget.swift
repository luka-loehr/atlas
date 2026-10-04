import WidgetKit
import SwiftUI
import ImageIO

@main
struct AtlasWidgets: WidgetBundle {
    var body: some Widget { AlbumWidget() }
}

/// One album on the Home Screen, a different photo every 45 minutes, like
/// the Photos widget. Everything it shows the app has put in the App Group
/// container (`WidgetData`); tapping opens the photo in the app.
struct AlbumWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetData.kind, intent: AlbumWidgetIntent.self, provider: AlbumProvider()) { entry in
            AlbumWidgetView(entry: entry)
        }
        .configurationDisplayName("Album")
        .description("Photos from an album you choose, a different one every hour or so.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct AlbumEntry: TimelineEntry {
    let date: Date
    let key: String
    let title: String
    /// The photo to show, or the album's cover while its set is not there.
    let file: URL?
    let photo: WidgetData.Photo?
    let size: CGSize
    var placeholder = false
}

struct AlbumProvider: AppIntentTimelineProvider {
    static let interval: TimeInterval = 45 * 60

    func placeholder(in context: Context) -> AlbumEntry {
        AlbumEntry(date: .now, key: WidgetData.recents, title: "Recent Photos", file: nil, photo: nil,
                   size: context.displaySize, placeholder: true)
    }

    func snapshot(for configuration: AlbumWidgetIntent, in context: Context) async -> AlbumEntry {
        entries(configuration, context, count: 1).first ?? placeholder(in: context)
    }

    func timeline(for configuration: AlbumWidgetIntent, in context: Context) async -> Timeline<AlbumEntry> {
        let list = entries(configuration, context, count: 8)
        // a set that is still empty: look again soon, the app may have filled it
        let next = list.first?.photo == nil ? Date.now.addingTimeInterval(15 * 60) : nil
        return Timeline(entries: list, policy: next.map { .after($0) } ?? .atEnd)
    }

    /// A photo per 45-minute slot, starting with the current one. The slot
    /// number picks the photo, so a reload keeps showing the same one.
    private func entries(_ configuration: AlbumWidgetIntent, _ context: Context, count: Int) -> [AlbumEntry] {
        let manifest = WidgetData.read() ?? .init()
        let key = configuration.album?.id ?? WidgetData.recents
        let info = WidgetData.albumID(of: key).flatMap { id in manifest.albums.first { $0.id == id } }
        let title = key == WidgetData.recents ? "Recent Photos" : info?.title ?? configuration.album?.title ?? "Album"
        let photos = manifest.sets[key] ?? []
        let now = Date.now
        guard !photos.isEmpty else {
            let cover = info?.cover.flatMap(WidgetData.file)
            return [AlbumEntry(date: now, key: key, title: title, file: cover, photo: nil, size: context.displaySize)]
        }
        let slot = Int(now.timeIntervalSince1970 / Self.interval)
        // the families start apart, so a small and a large widget of one
        // album do not show the same photo
        let offset = context.family == .systemSmall ? 0 : context.family == .systemMedium ? photos.count / 3 : 2 * photos.count / 3
        return (0..<min(count, max(photos.count, 1))).map { i in
            let photo = photos[(slot + i + offset) % photos.count]
            let start = i == 0 ? now : Date(timeIntervalSince1970: TimeInterval(slot + i) * Self.interval)
            return AlbumEntry(date: start, key: key, title: title, file: WidgetData.file(photo.file), photo: photo,
                              size: context.displaySize)
        }
    }
}

struct AlbumWidgetView: View {
    let entry: AlbumEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = WidgetImage.load(entry.file, fill: entry.size, scale: scale) {
                // the photo fills the widget without widening the layout,
                // so the caption stays inside it
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .widgetAccentedRenderingMode(.accentedDesaturated)
                            .scaledToFill()
                    }
                    .clipped()
                    .accessibilityLabel(label)
            } else {
                empty
            }
            if entry.file != nil, family != .systemSmall {
                caption
            }
        }
        .containerBackground(for: .widget) { Color(.secondarySystemBackground) }
        .widgetURL(link)
        .redacted(reason: entry.placeholder ? .placeholder : [])
    }

    /// Album and date over a soft shade at the bottom.
    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let taken = entry.photo?.taken {
                Text(taken, format: .dateTime.day().month(.wide).year())
                    .font(.caption)
                    .opacity(0.85)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
        }
    }

    /// Nothing on the phone for this album yet: the app fills it next time.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(entry.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text("Open Atlas to load these photos.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var label: String {
        guard let taken = entry.photo?.taken else { return "Photo from \(entry.title)" }
        return "Photo from \(entry.title), \(taken.formatted(date: .long, time: .omitted))"
    }

    /// atlas://photo/<id>?album=<key>, or atlas://album/<id> (atlas://open
    /// for the recent photos) while there is no photo.
    private var link: URL? {
        var c = URLComponents()
        c.scheme = "atlas"
        if let photo = entry.photo {
            c.host = "photo"
            c.path = "/\(photo.id)"
            c.queryItems = [URLQueryItem(name: "album", value: entry.key)]
        } else if let id = WidgetData.albumID(of: entry.key) {
            c.host = "album"
            c.path = "/\(id)"
        } else {
            c.host = "open"
        }
        return c.url
    }
}

/// Widgets have little memory: an image is decoded straight to the pixel
/// size it fills, never at its full size.
enum WidgetImage {
    static func load(_ url: URL?, fill size: CGSize, scale: CGFloat) -> UIImage? {
        guard let url, size.width > 0, size.height > 0,
              let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        // the scale that covers the widget, applied to the long side
        let cover = max(size.width * scale / w, size.height * scale / h)
        let target = min(max(w, h), (max(w, h) * cover).rounded(.up))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target, 1),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
