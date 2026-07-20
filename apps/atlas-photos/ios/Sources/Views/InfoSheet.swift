import SwiftUI
import MapKit

/// Detail sheet for one asset — Apple-/Google-Photos style:
/// date + filename, gray camera card (model + format badge, MP · resolution ·
/// size, ISO | focal | ev | ƒ | shutter), a map with the photo as pin, the
/// place name and the pipeline's tags.
struct InfoSheet: View {
    var library: Library
    var asset: Asset

    @Environment(\.dismiss) private var dismiss
    @State private var info: AssetInfo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                dateRow
                cameraCard
                mapCard
                tagsSection
                aiCaption
            }
            .padding(18)
            .padding(.top, 8)
        }
        .presentationDragIndicator(.visible)
        .task {
            info = try? await library.client.assetInfo(asset.id)
        }
    }

    // MARK: - Date + filename

    private var dateRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(longDate(info?.takenAt ?? asset.takenAt))
                .font(.system(size: 17, weight: .semibold))
            if let name = info?.origName {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.icloud")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Camera card

    @ViewBuilder
    private var cameraCard: some View {
        let ext = ((info?.origName as NSString?)?.pathExtension ?? "").uppercased()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(info?.camera ?? "Unbekannte Kamera")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if !ext.isEmpty {
                    Text(ext == "JPG" ? "JPEG" : ext)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(14)

            if let lens = info?.exif?.lens {
                Text(lens)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Text(dimensionLine)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            if !exifCells.isEmpty {
                Divider().padding(.horizontal, 8)
                HStack {
                    ForEach(Array(exifCells.enumerated()), id: \.offset) { i, cell in
                        if i > 0 { Divider().frame(height: 16) }
                        Text(cell)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 6)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private var dimensionLine: String {
        var parts: [String] = []
        if let w = info?.width ?? asset.width, let h = info?.height ?? asset.height {
            let mp = Double(w * h) / 1_000_000
            parts.append(String(format: "%.0f MP", mp))
            parts.append("\(w) × \(h)")
        }
        if let b = info?.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: b, countStyle: .file))
        }
        if let d = info?.durationS ?? asset.durationS {
            parts.append(Duration.seconds(d).formatted(.time(pattern: .minuteSecond)))
        }
        return parts.joined(separator: " · ")
    }

    private var exifCells: [String] {
        guard let e = info?.exif else { return [] }
        var out: [String] = []
        if let iso = e.iso { out.append("ISO \(iso)") }
        if let f = e.focalLen { out.append("\(f.formatted(.number.precision(.fractionLength(0...1)))) mm") }
        if let n = e.fNumber { out.append("ƒ\(n.formatted(.number.precision(.fractionLength(0...1))))") }
        if let t = e.exposureTime { out.append("\(t) s") }
        return out
    }

    // MARK: - Map

    @ViewBuilder
    private var mapCard: some View {
        if let lat = info?.lat, let lon = info?.lon {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            VStack(alignment: .leading, spacing: 0) {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))) {
                    Annotation("", coordinate: coord) {
                        Thumb(url: library.client.thumbURL(asset.id, 512))
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.white, lineWidth: 3))
                            .shadow(radius: 3)
                    }
                }
                .frame(height: 210)
                .allowsHitTesting(false)

                Button { openInMaps(coord) } label: {
                    HStack {
                        Text(info?.place ?? String(format: "%.4f, %.4f", lat, lon))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(14)
                }
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func openInMaps(_ coord: CLLocationCoordinate2D) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
        item.name = info?.place ?? "Foto-Ort"
        item.openInMaps()
    }

    // MARK: - Tags + AI caption

    @ViewBuilder
    private var tagsSection: some View {
        if let tags = info?.tags, !tags.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tags")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                FlowChips(items: tags)
            }
        }
    }

    @ViewBuilder
    private var aiCaption: some View {
        if let c = info?.caption, !c.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(c)
                    .font(.system(size: 14))
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
        }
    }

    private func longDate(_ d: Date?) -> String {
        guard let d else { return "Unbekanntes Datum" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, d. MMMM yyyy 'um' HH:mm"
        return f.string(from: d)
    }
}

/// Simple wrapping chip layout for tags.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: Capsule())
            }
        }
    }
}

/// Minimal flow layout (wraps children like text).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
