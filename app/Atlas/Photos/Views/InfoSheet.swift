import SwiftUI
import MapKit

/// Detail sheet for one asset — Apple-/Google-Photos style:
/// person chips up top, date + filename, gray camera card (model +
/// format badge, MP · resolution · size, ISO | focal | ev | ƒ | shutter),
/// a map with the photo as pin, and per person a "make this the avatar" row.
struct InfoSheet: View {
    var library: Library
    var asset: Asset

    @State private var info: AssetInfo?
    @State private var faces: [AssetFace] = []
    @State private var coverSet: Set<Int64> = []   // persons whose avatar now IS this photo

    #if os(macOS)
    /// On the Mac the info is the window's inspector, and a person chip
    /// shows that person in the main window.
    @Environment(\.openPerson) private var openPerson
    #endif

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content.toolbar(.hidden, for: .navigationBar)
        }
        .presentationDragIndicator(.visible)
        #else
        content
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                personFlow
                dateRow
                cameraCard
                mapCard
                textCard
                coverSection
                hideStrangers
            }
            .padding(18)
            .padding(.top, 8)
        }
        .task(id: asset.id) {
            if info?.id != asset.id { info = nil; faces = []; coverSet = [] }
            // one request: the detail carries the faces
            guard let fresh = try? await library.client.assetInfo(asset.id) else { return }
            info = fresh
            faces = fresh.people
        }
    }

    /// Best face per person, pipeline already sorts by quality.
    private var personsOnPhoto: [AssetFace] {
        var seen = Set<Int64>(), out: [AssetFace] = []
        for f in faces where seen.insert(f.person).inserted { out.append(f) }
        return out
    }

    // MARK: - Date + filename

    private var dateRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(longDate(info?.takenAt ?? asset.takenAt))
                .font(.headline)
            if let name = info?.origName {
                Label(name, systemImage: "doc")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Camera card

    @ViewBuilder
    private var cameraCard: some View {
        let ext = ((info?.origName as NSString?)?.pathExtension ?? "").uppercased()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(info?.camera ?? "Unknown Camera")
                    .font(.callout.weight(.semibold))
                Spacer()
                if !ext.isEmpty {
                    Text(ext == "JPG" ? "JPEG" : ext)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(14)

            if let lens = info?.exif?.lens {
                Text(lens)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Text(dimensionLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            if !exifCells.isEmpty {
                Divider().padding(.horizontal, 8)
                HStack {
                    ForEach(Array(exifCells.enumerated()), id: \.offset) { i, cell in
                        if i > 0 { Divider().frame(height: 16) }
                        Text(cell)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 6)
            }
        }
        .background(Color.cardBackground,
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
            parts.append(b.fileSize)
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

    // MARK: - Text in the photo

    @ViewBuilder
    private var textCard: some View {
        if let text = info?.text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Text", systemImage: "text.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Strangers

    /// Hides everyone unnamed on the photo (a school's staff photo): they
    /// leave People, search and this panel, and stay hidden when they turn
    /// up in other photos.
    @ViewBuilder
    private var hideStrangers: some View {
        if personsOnPhoto.contains(where: { $0.name == nil }) {
            Button {
                Task {
                    try? await library.client.hideFaces(inAssets: [asset.id])
                    if let fresh = try? await library.client.assetInfo(asset.id) {
                        info = fresh
                        faces = fresh.people
                    }
                }
            } label: {
                Label("Hide Unnamed People in This Photo", systemImage: "eye.slash")
            }
            .font(.subheadline)
        }
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
                .accessibilityHidden(true)

                Button { openInMaps(coord) } label: {
                    HStack {
                        Text(info?.place ?? String(format: "%.4f, %.4f", lat, lon))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Spacer()
                    }
                    .padding(14)
                }
            }
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func openInMaps(_ coord: CLLocationCoordinate2D) {
        let item = MKMapItem(location: CLLocation(latitude: coord.latitude, longitude: coord.longitude), address: nil)
        item.name = info?.place ?? "Photo Location"
        item.openInMaps()
    }

    // MARK: - Persons. One flow up top: tappable person chips (face + name
    // -> their photo grid).

    @ViewBuilder
    private var personFlow: some View {
        if !personsOnPhoto.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(personsOnPhoto) { f in
                    let person = Person(id: f.person, name: f.name, coverFace: f.face, photos: 0, kind: f.kind ?? "person")
                    #if os(iOS)
                    NavigationLink {
                        PersonDetailScreen(library: library, person: person)
                    } label: { chip(f) }
                    .buttonStyle(.plain)
                    #else
                    Button { openPerson(person) } label: { chip(f) }
                        .buttonStyle(.plain)
                    #endif
                }
            }
            .padding(.top, 4)
        }
    }

    private func chip(_ f: AssetFace) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(Color.placeholderFill)
                Thumb(url: library.client.faceCropURL(f.face))
            }
            .frame(width: 26, height: 26)
            .clipShape(Circle())
            Text(f.displayName)
                .font(.footnote.weight(.medium))
                .foregroundStyle(f.name == nil ? .secondary : .primary)
                .lineLimit(1)   // chip stays one line, truncates
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(Color.cardBackground,
                    in: Capsule())
    }

    // MARK: - "Als Titelbild festlegen" — one row per person on the photo;
    // sets persons.cover_face_id to THIS photo's face crop.

    @ViewBuilder
    private var coverSection: some View {
        if !personsOnPhoto.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(personsOnPhoto) { f in
                    let done = coverSet.contains(f.person)
                    Button {
                        Task {
                            do {
                                try await library.client.setPersonCover(f.person, faceId: f.face)
                                coverSet.insert(f.person)
                            } catch {}
                        }
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.placeholderFill)
                                Thumb(url: library.client.faceCropURL(f.face))
                            }
                            .frame(width: 34, height: 34)
                            .clipShape(Circle())
                            Text(done ? "Key photo of \(f.displayName) updated"
                                      : "Make Key Photo of \(f.displayName)")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(done ? .secondary : .primary)
                            Spacer()
                            Image(systemName: done ? "checkmark.circle.fill"
                                                   : "person.crop.circle.badge.checkmark")
                                .font(.title3)
                                .accessibilityHidden(true)
                                .foregroundStyle(done ? AnyShapeStyle(.green)
                                                      : AnyShapeStyle(.secondary))
                        }
                        .padding(12)
                        .background(Color.cardBackground,
                                    in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(done)
                }
            }
        }
    }

    private func longDate(_ d: Date?) -> String {
        guard let d else { return "Unknown Date" }
        return Self.longDateFormat.string(from: d)
    }

    private static let longDateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, d MMMM yyyy 'at' HH:mm"
        return f
    }()
}
