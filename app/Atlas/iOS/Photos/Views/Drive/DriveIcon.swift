import SwiftUI

/// A file's type, or a folder, as a symbol on a tinted rounded square.
struct DriveIcon: View {
    let symbol: String
    let color: Color
    let size: CGFloat
    let weight: Font.Weight

    init(symbol: String, color: Color, size: CGFloat = 15, weight: Font.Weight = .semibold) {
        self.symbol = symbol
        self.color = color
        self.size = size
        self.weight = weight
    }

    /// The symbol and color of a file's type, from its name.
    init(file name: String) {
        let icon = driveIcon(for: name)
        self.init(symbol: icon.symbol, color: icon.color)
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

private func driveIcon(for name: String) -> (symbol: String, color: Color) {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "pdf": return ("doc.richtext.fill", .red)
    case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tif", "tiff":
        return ("photo.fill", .teal)
    case "mp3", "m4a", "aac", "wav", "ogg", "oga", "opus", "flac", "aiff":
        return ("waveform", .purple)
    case "mp4", "mov", "m4v", "webm", "mkv", "avi": return ("play.rectangle.fill", .indigo)
    case "zip", "7z", "tar", "gz", "rar": return ("doc.zipper", .brown)
    case "txt", "md", "rtf", "log": return ("doc.text.fill", .gray)
    case "csv", "xls", "xlsx", "numbers": return ("tablecells.fill", .green)
    case "doc", "docx", "pages", "goodnotes": return ("doc.fill", .blue)
    case "ppt", "pptx", "key": return ("rectangle.stack.fill", .orange)
    case "json", "xml", "html", "js", "py", "swift", "rs":
        return ("chevron.left.forwardslash.chevron.right", .cyan)
    default: return ("doc.fill", Color(.systemGray))
    }
}
