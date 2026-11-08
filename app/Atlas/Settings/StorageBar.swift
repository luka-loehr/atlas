import SwiftUI

/// What Atlas keeps on this device, by kind.
struct StorageUse {
    /// Every grid thumbnail of the library (kept for good).
    var thumbnails: Int64 = 0
    var previews: Int64 = 0
    var originals: Int64 = 0
    var videos: Int64 = 0
    /// Faces and file thumbnails.
    var other: Int64 = 0

    var total: Int64 { thumbnails + previews + originals + videos + other }

    /// Read off the main thread: walking the caches touches the disk.
    static func measure() async -> StorageUse {
        await Task.detached(priority: .utility) {
            var u = StorageUse()
            await MediaStore.shared.loadThumbIndex()
            u.thumbnails = MediaStore.shared.thumbStats.bytes
            let kinds = MediaStore.shared.bytesByKind
            u.previews = kinds[.preview] ?? 0
            u.originals = kinds[.original] ?? 0
            u.videos = kinds[.video] ?? 0
            u.other = (kinds[.face] ?? 0) + (kinds[.driveThumb] ?? 0)
            return u
        }.value
    }
}

/// One row like Settings › General › iPhone Storage, but only for what
/// Atlas keeps on this device: a horizontal bar split by kind, and a legend.
struct StorageBar: View {
    var use: StorageUse

    private var parts: [(String, Color, Int64)] {
        [("Thumbnails", .indigo, use.thumbnails), ("Previews", .blue, use.previews),
         ("Originals", .teal, use.originals), ("Videos", .orange, use.videos), ("Faces & Files", .pink, use.other)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Atlas").font(.headline)
                Spacer()
                Text(use.total.fileSize).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                let total = CGFloat(max(use.total, 1))
                HStack(spacing: 1.5) {
                    ForEach(parts.filter { $0.2 > 0 }, id: \.0) { part in
                        Rectangle().fill(part.1)
                            .frame(width: max(geo.size.width * CGFloat(part.2) / total - 1.5, 2))
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .background(Color.trackFill)
                .clipShape(.rect(cornerRadius: 4))
            }
            .frame(height: 20)
            .accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(parts, id: \.0) { part in legend(part.1, part.0, part.2) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func legend(_ color: Color, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption)
                Text(bytes.fileSize).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}
