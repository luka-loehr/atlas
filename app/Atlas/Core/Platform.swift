import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// The little that differs between UIKit and AppKit for the shared layer:
// images, system colors, the pasteboard, haptics, the screen, and the
// handful of view modifiers that exist on one platform only. Everything
// else in Atlas/ is plain SwiftUI and Foundation and compiles for both.

#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage

extension NSImage {
    /// A bitmap image whose size in points is its size in pixels; SwiftUI
    /// scales it to its frame anyway, so the point size only matters for
    /// the aspect ratio.
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// The bitmap the image was made from.
    var cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
#endif

extension PlatformImage {
    /// What it costs in RAM, decoded (for `NSCache` limits).
    var decodedCost: Int { (cgImage?.bytesPerRow ?? 0) * (cgImage?.height ?? 0) }

    /// A bitmap decoded off the main thread, so nothing decodes at render
    /// time. ImageIO's thumbnails (`ShouldCacheImmediately`) are decoded
    /// already; on iOS this also moves them into the display's format.
    func preparedForDisplay() -> PlatformImage {
        #if os(iOS)
        preparingForDisplay() ?? self
        #else
        // What UIKit's preparingForDisplay does: the bitmap in the format
        // Core Animation shows directly (32-bit BGRA, premultiplied, in an
        // RGB color space). Anything else (ImageIO's RGB without alpha, wide
        // gamut 16-bit) is converted by Core Animation on the main thread
        // when the layer is committed, which stalls a fast scroll.
        guard let cg = cgImage else { return self }
        // the display's own color space: Core Animation then has nothing to
        // match on the main thread either
        let space = DisplayColor.space ?? cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info) else { return self }
        context.interpolationQuality = .none
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let native = context.makeImage() else { return self }
        return NSImage(cgImage: native)
        #endif
    }
}

#if os(macOS)
/// The color space of the main display, read on the main thread (at launch
/// and when the displays change) for the decoders to draw into.
enum DisplayColor {
    nonisolated(unsafe) static var space: CGColorSpace?

    @MainActor static func update() {
        space = NSScreen.main?.colorSpace?.cgColorSpace
    }
}
#endif

extension Image {
    init(platformImage image: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}

extension Color {
    /// The grey a thumbnail shows while it loads.
    static var placeholderFill: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemFill)
        #else
        Color(nsColor: .quaternarySystemFill)
        #endif
    }

    /// The empty part of a bar (the storage bar).
    static var trackFill: Color {
        #if os(iOS)
        Color(uiColor: .systemGray5)
        #else
        Color(nsColor: .quaternaryLabelColor)
        #endif
    }

    /// A card on the window background (the info sheet's boxes).
    static var cardBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .quaternarySystemFill)
        #endif
    }
}

/// Copying to the pasteboard.
@MainActor
enum Pasteboard {
    static func copy(_ url: URL) {
        #if os(iOS)
        UIPasteboard.general.url = url
        #else
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
        board.setString(url.absoluteString, forType: .string)
        #endif
    }

    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Confirmation haptics. The Mac has none for this (its trackpad haptics
/// are for alignment and pressure, not for "done").
@MainActor
enum Haptics {
    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}

/// The screen the app shows on (what `UIScreen.main` used to answer).
@MainActor
enum ScreenSize {
    #if os(iOS)
    private static var screen: UIScreen? { (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen }
    static var bounds: CGRect { screen?.bounds ?? CGRect(x: 0, y: 0, width: 402, height: 874) }
    static var scale: CGFloat { screen?.scale ?? 3 }
    #else
    private static var screen: NSScreen? { NSApp?.keyWindow?.screen ?? NSScreen.main }
    static var bounds: CGRect { screen?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982) }
    static var scale: CGFloat { screen?.backingScaleFactor ?? 2 }
    #endif
}

/// Calls `handler` on the main thread when the system runs short of memory:
/// the memory warning on iOS, memory pressure on the Mac.
@MainActor
enum MemoryPressure {
    #if os(macOS)
    private static var source: DispatchSourceMemoryPressure?
    #endif

    static func observe(_ handler: @escaping @MainActor () -> Void) {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        #else
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.resume()
        self.source = source
        #endif
    }
}

extension View {
    /// The compact title of a pushed screen. Mac windows title themselves.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// A text field for addresses, tokens and passwords: no capitals, no
    /// autocorrection.
    func plainTextEntry() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }
}

extension ToolbarItemPlacement {
    /// The trailing end of the bar: the navigation bar's on iOS, the
    /// window toolbar's on the Mac.
    static var trailingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}
