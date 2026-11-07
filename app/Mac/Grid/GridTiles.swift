import AppKit
import ImageIO
import UniformTypeIdentifiers
import os

/// The grid's own copies of every thumbnail, made once on this Mac from the
/// pinned 512 WebPs, so a cell never waits, however fast the grid moves.
///
/// Decoding a WebP thumbnail takes ~5 ms; a fling shows hundreds of new
/// cells a second. So the Mac keeps two more forms of each, cropped to the
/// square the cell shows:
///
///   • the mini: 64 × 64 raw pixels in one file, read in microseconds and
///     shown the moment a cell appears (nothing is ever blank);
///   • the sharp tile: a 256 × 256 JPEG, decoded in under half a
///     millisecond on the tile queue, which replaces the mini within a frame
///     or two, and is held in RAM for scrolling back.
///
/// About 430 MB of minis and 400 MB of tiles for 26,000 photos, in
/// Application Support beside the thumbnails, built in the background in
/// half a minute and kept up to date as thumbnails come and go.
final class GridTiles: @unchecked Sendable {
    static let shared = GridTiles()

    static let miniSide = 64
    static let sharpSide = 256
    private static let slotBytes = miniSide * miniSide * 4

    private let directory: URL
    private let miniURL: URL
    private let indexURL: URL
    private let sharpDirectory: URL
    private let lock = NSLock()
    private var slots: [String: Int] = [:]
    private var free: [Int] = []
    private var nextSlot = 0
    private var handle: FileHandle?
    /// The minis, mapped, and read into the page cache in the background
    /// at launch: a mini is a pointer into it, nothing is copied or read
    /// from the disk while scrolling. Mapped again after the builder
    /// appended.
    private var mapped: NSData?
    private var dirty = false
    private var building: Task<Void, Never>?
    private let log = Logger(subsystem: "com.lukaloehr.atlas", category: "GridTiles")

    /// Decoded sharp tiles, for scrolling back.
    private let ram = NSCache<NSString, CGImageBox>()

    /// The tile decodes, apart from the thumbnail queue: a fling never waits
    /// behind viewer previews.
    let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "atlas.tiles"
        q.qualityOfService = .userInteractive
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        return q
    }()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("GridTiles", isDirectory: true)
        miniURL = directory.appendingPathComponent("mini.bin")
        indexURL = directory.appendingPathComponent("index.json")
        sharpDirectory = directory.appendingPathComponent("sharp", isDirectory: true)
        try? FileManager.default.createDirectory(at: sharpDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: miniURL.path) {
            FileManager.default.createFile(atPath: miniURL.path, contents: nil)
        }
        handle = try? FileHandle(forUpdating: miniURL)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([String: Int].self, from: data) {
            slots = saved
            nextSlot = (saved.values.max() ?? -1) + 1
            let used = Set(saved.values)
            free = (0..<nextSlot).filter { !used.contains($0) }
        }
        remap()
        let memory = ProcessInfo.processInfo.physicalMemory
        ram.totalCostLimit = Int(min(memory / 10, 2 << 30))
        // a thumbnail made again on the server: its tiles are made again too
        MediaStore.thumbRemoved = { id in GridTiles.shared.forget(id) }
    }

    // MARK: Reading

    /// The mini of `id`, at once (a read of 16 KB from the page cache).
    func mini(_ id: String) -> CGImage? {
        let found: (Int, NSData)? = lock.withLock {
            guard let slot = slots[id], let mapped else { return nil }
            return (slot, mapped)
        }
        guard let (slot, mapped) = found else { return nil }
        let start = slot * Self.slotBytes
        guard start + Self.slotBytes <= mapped.length else { return nil }
        // the provider keeps the mapping alive as long as the image lives
        let owner = Unmanaged.passRetained(mapped).toOpaque()
        guard let provider = CGDataProvider(dataInfo: owner, data: mapped.bytes.advanced(by: start), size: Self.slotBytes,
                                            releaseData: { info, _, _ in
                                                if let info { Unmanaged<NSData>.fromOpaque(info).release() }
                                            }) else {
            Unmanaged<NSData>.fromOpaque(owner).release()
            return nil
        }
        return CGImage(width: Self.miniSide, height: Self.miniSide, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: Self.miniSide * 4, space: Self.space, bitmapInfo: Self.bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A sharp tile already decoded in RAM.
    func cachedSharp(_ id: String) -> CGImage? { ram.object(forKey: id as NSString)?.image }

    /// Decodes the sharp tile of `id` on the tile queue; `done` runs on the
    /// main thread with nil when there is no tile (yet). Cancel the
    /// operation when the cell no longer wants it.
    @discardableResult
    func requestSharp(_ id: String, priority: Operation.QueuePriority = .veryHigh,
                      _ done: @escaping @MainActor (CGImage?) -> Void) -> Operation {
        let op = BlockOperation()
        op.addExecutionBlock { [unowned op] in
            guard !op.isCancelled else { return }
            let image = self.decodeSharp(id)
            if let image { self.ram.setObject(CGImageBox(image), forKey: id as NSString, cost: image.bytesPerRow * image.height) }
            guard !op.isCancelled else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(image) } }
        }
        op.queuePriority = priority
        queue.addOperation(op)
        return op
    }

    private func decodeSharp(_ id: String) -> CGImage? {
        let url = sharpURL(id)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let jpeg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        // into the format Core Animation shows as it is
        return Self.redraw(jpeg, side: jpeg.width, crop: false)
    }

    // MARK: Building

    /// Makes what is missing for `ids` (newest first), in the background.
    /// Thumbnails not on the Mac yet are skipped; the next call makes them.
    func build(_ ids: [String]) {
        building?.cancel()
        building = Task.detached(priority: .utility) { [self] in
            let missing = ids.reversed().filter { id in
                self.lock.withLock { self.slots[id] == nil } || !FileManager.default.fileExists(atPath: self.sharpURL(id).path)
            }
            guard !missing.isEmpty else { return }
            self.log.info("grid tiles: making \(missing.count)")
            let started = Date()
            var made = 0
            await withTaskGroup(of: Bool.self) { group in
                var it = missing.makeIterator()
                func next() {
                    guard let id = it.next() else { return }
                    group.addTask(priority: .utility) { self.make(id) }
                }
                for _ in 0..<max(2, ProcessInfo.processInfo.activeProcessorCount - 2) { next() }
                for await ok in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    if ok { made += 1 }
                    if made % 500 == 0 { self.saveIndex(); self.remap() }
                    next()
                }
            }
            self.saveIndex()
            self.remap()
            self.log.info("grid tiles: made \(made) of \(missing.count) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
        }
    }

    /// One thumbnail into its mini and its sharp tile.
    private func make(_ id: String) -> Bool {
        let thumb = MediaStore.shared.thumbURL(id)
        guard let source = CGImageSourceCreateWithURL(thumb as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512,
              ] as CFDictionary) else { return false }
        guard let sharp = Self.redraw(image, side: Self.sharpSide, crop: true),
              let mini = Self.redraw(image, side: Self.miniSide, crop: true),
              let miniBytes = mini.dataProvider?.data as Data? else { return false }
        // the JPEG
        let url = sharpURL(id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, sharp, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return false }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        // the mini, tightly packed rows
        var packed = Data(capacity: Self.slotBytes)
        let row = Self.miniSide * 4
        for y in 0..<Self.miniSide {
            packed.append(miniBytes.subdata(in: (y * mini.bytesPerRow)..<(y * mini.bytesPerRow + row)))
        }
        return lock.withLock {
            guard let handle else { return false }
            let slot = slots[id] ?? free.popLast() ?? { defer { nextSlot += 1 }; return nextSlot }()
            do {
                try handle.seek(toOffset: UInt64(slot * Self.slotBytes))
                try handle.write(contentsOf: packed)
            } catch { return false }
            slots[id] = slot
            dirty = true
            return true
        }
    }

    private func remap() {
        let fresh = try? NSData(contentsOf: miniURL, options: .alwaysMapped)
        lock.withLock { mapped = fresh }
        guard let fresh, fresh.length > 0 else { return }
        // into the page cache now, in one sequential read, rather than one
        // page fault per cell while scrolling
        DispatchQueue.global(qos: .utility).async {
            _ = madvise(UnsafeMutableRawPointer(mutating: fresh.bytes), fresh.length, MADV_WILLNEED)
        }
    }

    private func forget(_ id: String) {
        lock.withLock {
            if let slot = slots.removeValue(forKey: id) { free.append(slot); dirty = true }
        }
        ram.removeObject(forKey: id as NSString)
        try? FileManager.default.removeItem(at: sharpURL(id))
    }

    private func saveIndex() {
        let snapshot: [String: Int]? = lock.withLock {
            guard dirty else { return nil }
            dirty = false
            return slots
        }
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: Pixels

    private func sharpURL(_ id: String) -> URL {
        let safe = String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
        return sharpDirectory.appendingPathComponent(String(safe.prefix(2)), isDirectory: true)
            .appendingPathComponent(safe + ".jpg")
    }

    private static var space: CGColorSpace { DisplayColor.space ?? CGColorSpace(name: CGColorSpace.sRGB)! }
    private static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    /// `image` as a `side`-pixel BGRA bitmap in the display's color space,
    /// center-cropped to a square when `crop` (what an aspect-fill cell shows).
    static func redraw(_ image: CGImage, side: Int, crop: Bool) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0,
              let context = CGContext(data: nil, width: side, height: crop ? side : Int((h / w * CGFloat(side)).rounded()),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        let target = CGFloat(side)
        let rect: CGRect
        if crop {
            let scale = target / min(w, h)
            rect = CGRect(x: (target - w * scale) / 2, y: (target - h * scale) / 2, width: w * scale, height: h * scale)
        } else {
            rect = CGRect(x: 0, y: 0, width: CGFloat(context.width), height: CGFloat(context.height))
        }
        context.draw(image, in: rect)
        return context.makeImage()
    }
}

/// `NSCache` holds objects.
final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
