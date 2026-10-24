import AppKit
import SwiftUI
import HoneDesign

/// A colour as three sRGB components, 0…1. Plain numbers so the maths is testable.
struct IslandRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double
}

/// The tint of the equaliser and progress bar: the cover's average colour, lifted
/// until it reads on black.
enum IslandTint {
    /// Plain mean of the opaque pixels of an RGBA8 buffer (premultiplied alpha is
    /// undone). Transparent pixels don't count; `nil` when nothing is left.
    static func average(rgba: [UInt8]) -> IslandRGB? {
        var r = 0.0, g = 0.0, b = 0.0, count = 0.0
        var i = 0
        while i + 3 < rgba.count {
            let a = Double(rgba[i + 3])
            if a > 0 {
                let unpremultiply = 255 / a
                r += min(Double(rgba[i]) * unpremultiply, 255)
                g += min(Double(rgba[i + 1]) * unpremultiply, 255)
                b += min(Double(rgba[i + 2]) * unpremultiply, 255)
                count += 1
            }
            i += 4
        }
        guard count > 0 else { return nil }
        return IslandRGB(red: r / count / 255, green: g / count / 255, blue: b / count / 255)
    }

    /// The brightest component reaches at least `minBrightness`, so a dark cover
    /// still gives a visible tint on the black island. Hue and saturation stay.
    static func legible(_ rgb: IslandRGB, minBrightness: Double = 0.72) -> IslandRGB {
        let peak = max(rgb.red, rgb.green, rgb.blue)
        guard peak < minBrightness else { return rgb }
        // Pure black has no hue to keep: a neutral light grey.
        guard peak > 0.001 else { return IslandRGB(red: minBrightness, green: minBrightness, blue: minBrightness) }
        let scale = minBrightness / peak
        return IslandRGB(red: rgb.red * scale, green: rgb.green * scale, blue: rgb.blue * scale)
    }
}

/// A decoded cover and its tint. Built once per track (the controller caches it),
/// never in a view's body.
struct IslandArtwork {
    let image: NSImage
    let tint: Color

    /// `nil` when there are no bytes or they are not an image: the view then draws
    /// the placeholder.
    static func make(from data: Data?) -> IslandArtwork? {
        guard let data, !data.isEmpty, let image = NSImage(data: data),
              image.size.width > 0, image.size.height > 0 else { return nil }
        let rgb = averageColour(of: image).map { IslandTint.legible($0) }
        return IslandArtwork(image: image, tint: rgb.map(Self.color) ?? IslandPalette.fallbackTint)
    }

    static func color(_ rgb: IslandRGB) -> Color {
        Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// Draws the image into a 12×12 sRGB buffer and averages that.
    private static func averageColour(of image: NSImage) -> IslandRGB? {
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? IslandTint.average(rgba: pixels) : nil
    }
}

/// The island's colours, from the design tokens. It is drawn in the canvas black
/// to merge with the notch, so it never uses the card surfaces.
enum IslandPalette {
    /// The island itself: the notch's black.
    static let island = VibeColor.canvas
    /// Tint when the track has no cover.
    static let fallbackTint = VibeColor.text1
    /// Behind the placeholder note.
    static let placeholder = VibeColor.track
    /// The unfilled part of the progress bar.
    static let track = VibeColor.track
    /// Hovered control.
    static let hover = VibeColor.cornerFill
    static let primaryText = VibeColor.text1
    static let secondaryText = VibeColor.text2
    static let tertiaryText = VibeColor.text3
}
