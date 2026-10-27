import AppKit
import ImageIO

/// Claude's own mark, read at run time from the Claude app installed on this Mac:
/// Hone ships no copy of it. The app's menu bar icon is a template (black on clear)
/// of the spark; it is cut to what it draws, so it fills its box the way
/// `ClaudeSpark` does. `nil` without the app or the file: the island draws
/// `ClaudeSpark` instead.
enum ClaudeAppLogo {
    /// Read once, on first use, and kept for good.
    static let image: CGImage? = load(fromResources: NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: IslandClaudeApp.bundleID)?
        .appendingPathComponent("Contents/Resources", isDirectory: true))

    /// The largest first: drawn at a few points, it is only ever scaled down.
    static let fileNames = ["TrayIconTemplate@3x.png", "TrayIconTemplate@2x.png", "TrayIconTemplate.png"]
    /// A menu bar icon is tens of pixels: anything far larger is not the one meant.
    static let maxSide = 512

    /// The first of `fileNames` in `folder` that reads, trimmed.
    static func load(fromResources folder: URL?) -> CGImage? {
        guard let folder else { return nil }
        for name in fileNames {
            let url = folder.appendingPathComponent(name)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width <= maxSide, image.height <= maxSide,
                  let trimmed = trimmed(image) else { continue }
            return trimmed
        }
        return nil
    }

    /// `image` cut to the pixels it draws (alpha above a trace); `nil` if it draws none.
    static func trimmed(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // The bitmap's first row is the image's top row, as `cropping(to:)` counts.
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    /// `logo`'s shape filled with `color`, at the logo's own pixels: what a layer
    /// shows as its contents.
    static func tinted(_ logo: CGImage, color: CGColor) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: logo.width, height: logo.height)
        guard let context = CGContext(
            data: nil, width: logo.width, height: logo.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clip(to: rect, mask: logo)
        context.setFillColor(color)
        context.fill(rect)
        return context.makeImage()
    }
}
