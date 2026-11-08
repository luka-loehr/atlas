import Foundation
import UniformTypeIdentifiers

extension VideoCache {
    /// One video on disk: a sparse data file and the ranges it holds.
    final class VideoFile: @unchecked Sendable {
        struct Meta: Codable {
            var length: Int64?
            var type: String?
            var ranges: [[Int64]] = []
        }

        let id: String
        let dataURL: URL
        let metaURL: URL
        var meta: Meta
        var ranges: [Range<Int64>]
        var refs = 0
        private var handle: FileHandle?
        private var dirty = false

        init(id: String, dataURL: URL, metaURL: URL) {
            self.id = id
            self.dataURL = dataURL
            self.metaURL = metaURL
            let fm = FileManager.default
            if fm.fileExists(atPath: dataURL.path), let d = try? Data(contentsOf: metaURL),
               let m = try? JSONDecoder().decode(Meta.self, from: d) {
                meta = m
                ranges = m.ranges.compactMap { $0.count == 2 && $0[0] < $0[1] ? $0[0]..<$0[1] : nil }
            } else {
                // data without its range list (or nothing): start over
                try? fm.removeItem(at: dataURL)
                meta = Meta()
                ranges = []
            }
        }

        var uti: String {
            meta.type.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.mpeg4Movie.identifier
        }

        var bytes: Int64 { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

        func range(containing o: Int64) -> Range<Int64>? { ranges.first { $0.contains(o) } }

        func nextStart(after o: Int64) -> Int64? { ranges.first { $0.lowerBound > o }?.lowerBound }

        func gaps(in r: Range<Int64>) -> [Range<Int64>] {
            var out: [Range<Int64>] = []
            var pos = r.lowerBound
            for c in ranges where c.upperBound > pos && c.lowerBound < r.upperBound {
                if c.lowerBound > pos { out.append(pos..<c.lowerBound) }
                pos = max(pos, c.upperBound)
            }
            if pos < r.upperBound { out.append(pos..<r.upperBound) }
            return out
        }

        private func open() throws -> FileHandle {
            if let handle { return handle }
            if !FileManager.default.fileExists(atPath: dataURL.path) {
                FileManager.default.createFile(atPath: dataURL.path, contents: nil)
            }
            let h = try FileHandle(forUpdating: dataURL)
            handle = h
            return h
        }

        func write(_ data: Data, at offset: Int64) throws {
            guard !data.isEmpty else { return }
            let h = try open()
            try h.seek(toOffset: UInt64(offset))
            try h.write(contentsOf: data)
            add(offset..<offset + Int64(data.count))
        }

        func read(_ r: Range<Int64>) throws -> Data {
            let h = try open()
            try h.seek(toOffset: UInt64(r.lowerBound))
            return try h.read(upToCount: Int(r.upperBound - r.lowerBound)) ?? Data()
        }

        private func add(_ r: Range<Int64>) {
            var merged = r
            var out: [Range<Int64>] = []
            for c in ranges {
                if c.upperBound < merged.lowerBound || c.lowerBound > merged.upperBound {
                    out.append(c)
                } else {
                    merged = min(c.lowerBound, merged.lowerBound)..<max(c.upperBound, merged.upperBound)
                }
            }
            out.append(merged)
            ranges = out.sorted { $0.lowerBound < $1.lowerBound }
            dirty = true
        }

        func noteHeaders(length: Int64?, type: String?) {
            if meta.length == nil, let length, length > 0 { meta.length = length; dirty = true }
            if meta.type == nil, let type { meta.type = type; dirty = true }
        }

        /// The range list goes to disk after the bytes it describes.
        func flush() {
            guard dirty else { return }
            meta.ranges = ranges.map { [$0.lowerBound, $0.upperBound] }
            if let d = try? JSONEncoder().encode(meta) { try? d.write(to: metaURL, options: .atomic) }
            dirty = false
        }

        func close() {
            flush()
            try? handle?.close()
            handle = nil
        }
    }
}
