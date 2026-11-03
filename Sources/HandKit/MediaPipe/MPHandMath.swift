import Foundation

// Pure maths of MediaPipe's hand pipeline (palm detector → rotated hand rect →
// landmark model → next-frame rect), ported from the official calculators. No
// CoreML and no images here: the host runs the models and hands over raw tensors.
// Image coordinates are normalized 0…1, top-left origin, y down; angles in radians,
// positive = clockwise on screen.

public enum MPMath {
    /// Wraps an angle into [−π, π), as mediapipe's `NormalizeRadians`.
    public static func normalizeRadians(_ angle: Double) -> Double {
        angle - 2 * .pi * ((angle + .pi) / (2 * .pi)).rounded(.down)
    }

    static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }
}

/// The square, black-padded, centred crop the palm detector sees for a `w`×`h`
/// image (`ImageToTensor` with keep-aspect-ratio). Converts points of that square
/// back to the image's own normalized space.
public struct MPLetterbox: Equatable, Sendable {
    public let imageWidth: Double
    public let imageHeight: Double
    /// Side of the square, in image pixels: the longer image side.
    public let side: Double
    /// Black padding on each side of the image inside the square, in pixels.
    public let offsetX: Double
    public let offsetY: Double

    public init(imageWidth: Double, imageHeight: Double) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        side = max(imageWidth, imageHeight)
        offsetX = (side - imageWidth) / 2
        offsetY = (side - imageHeight) / 2
    }

    /// A point normalized to the square (0…1 over the tensor) → normalized to the image.
    /// Points over the padding fall outside 0…1.
    public func unproject(_ p: HandPoint) -> HandPoint {
        HandPoint(x: (p.x * side - offsetX) / imageWidth,
                  y: (p.y * side - offsetY) / imageHeight)
    }

    /// Inverse of `unproject`: image-normalized → tensor-normalized.
    public func project(_ p: HandPoint) -> HandPoint {
        HandPoint(x: (p.x * imageWidth + offsetX) / side,
                  y: (p.y * imageHeight + offsetY) / side)
    }
}

/// Landmark model output → image space (`LandmarkProjectionCalculator`).
public enum MPLandmarks {
    /// Side of the square crop the landmark model sees, in pixels.
    public static let inputSize = 224
    public static let count = 21
    /// `normalize_z` of the model's tensors-to-landmarks node.
    static let depthNormalization = 0.4

    /// `raw` = 63 floats (x, y, z per landmark, pixels of the 224 crop) → 21 points normalized
    /// to the image. The crop's centre lands on the rect's centre, for any rotation. Rotating
    /// before scaling by (w, h) is only exact for rects square in pixels, which every rect
    /// from `MPRect.fromPalm` / `fromLandmarks` is (square_long), so the image size is not needed.
    /// Wrong-sized input → empty.
    public static func project(raw: [Float], rect: MPRect) -> [HandPoint] {
        guard raw.count >= count * 3 else { return [] }
        let size = Double(inputSize)
        let c = cos(rect.rotation), s = sin(rect.rotation)
        return (0..<count).map { i in
            let x = Double(raw[i * 3]) / size - 0.5
            let y = Double(raw[i * 3 + 1]) / size - 0.5
            let nx = c * x - s * y
            let ny = s * x + c * y
            return HandPoint(x: nx * rect.w + rect.cx, y: ny * rect.h + rect.cy)
        }
    }

    /// Relative depth per landmark (wrist-relative in the model, scaled like x by the rect width).
    /// Wrong-sized input → empty.
    public static func depth(raw: [Float], rect: MPRect) -> [Double] {
        guard raw.count >= count * 3 else { return [] }
        let size = Double(inputSize)
        return (0..<count).map { Double(raw[$0 * 3 + 2]) / size / depthNormalization * rect.w }
    }
}
