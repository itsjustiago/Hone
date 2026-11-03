import Foundation

/// A rectangle of the camera image, normalized 0…1. The host hands it to the detector
/// as its region of interest (hand pose on a crop around the hand is steadier and
/// cheaper than on the whole frame). Pure maths: no Vision, no camera.
///
/// The coordinate system is whatever the points given to `around` use; the host passes
/// the detector's own (bottom-left origin, not mirrored) so the rect can go straight
/// back to it.
public struct HandRegion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// The whole image.
    public static let full = HandRegion(x: 0, y: 0, width: 1, height: 1)

    /// The region to look in next frame: the bounding box of `points` grown `scale`×
    /// around its centre, SQUARE IN PIXELS (so it is a square on the sensor, not in
    /// normalized space), at least `minSide` of the image height, slid back inside 0…1
    /// when it overhangs (a square bigger than the image is cut down to it first).
    /// Symmetric in the axes: mirrored points give the mirrored region.
    public static func around(points: [HandPoint], imageWidth: Double, imageHeight: Double,
                              scale: Double = 2.0, minSide: Double = 0.25) -> HandRegion {
        guard !points.isEmpty,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              imageWidth > 0, imageHeight > 0 else { return .full }
        let aspect = imageWidth / imageHeight
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let centre = HandPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)

        // Side in image heights: the bigger box side (x scaled to heights) grown by `scale`,
        // never smaller than `minSide`, never bigger than the image's shorter side.
        let box = max((maxX - minX) * aspect, maxY - minY)
        let side = min(max(box * scale, minSide), min(1, aspect))
        let width = side / aspect, height = side

        // Slide into the image: no shrinking while a shift is enough.
        let x = min(max(centre.x - width / 2, 0), 1 - width)
        let y = min(max(centre.y - height / 2, 0), 1 - height)
        return HandRegion(x: x, y: y, width: width, height: height)
    }

    /// A point given relative to this region (0…1 inside it) → the whole image's 0…1.
    public func unmap(_ p: HandPoint) -> HandPoint {
        HandPoint(x: x + p.x * width, y: y + p.y * height)
    }
}
