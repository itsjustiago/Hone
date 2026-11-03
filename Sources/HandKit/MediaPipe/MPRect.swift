import Foundation

/// A rotated rectangle of the camera image: the region the landmark model looks at.
/// Centre and size are normalized to the image (0…1); `rotation` in radians, clockwise
/// on screen (the rect's "up" tips towards +x), so a hand pointing right is +π/2.
public struct MPRect: Equatable, Sendable {
    public var cx: Double
    public var cy: Double
    public var w: Double
    public var h: Double
    public var rotation: Double

    public init(cx: Double, cy: Double, w: Double, h: Double, rotation: Double) {
        self.cx = cx; self.cy = cy; self.w = w; self.h = h; self.rotation = rotation
    }

    /// Target angle of the tasks `HandDetectorGraph`: `set_rotation_vector_target_angle(90)`
    /// is RADIANS there (≡ 2.0354 rad), not degrees. The default, to match the shipped graph.
    public static let palmTargetAngle = 90.0
    /// What the legacy graph meant (`..._degrees: 90`): an upright palm gives rotation 0.
    public static let palmTargetAngleLegacy = Double.pi / 2

    /// `RectTransformationCalculator` settings that grow a palm into a hand rect.
    static let palmScale = 2.6, palmShiftY = -0.5
    /// Same, for the rect carried to the next frame.
    static let trackScale = 2.0, trackShiftY = -0.1
    /// Landmarks `HandLandmarksToRectCalculator` looks at.
    static let trackLandmarkIDs = [0, 1, 2, 3, 5, 6, 9, 10, 13, 14, 17, 18]

    /// Hand rect from a palm detection already in image space (`unprojected`): rotated so
    /// wrist → middle MCP points up, then grown and shifted towards the fingers.
    /// Fewer than 3 keypoints → rotation 0.
    public static func fromPalm(_ d: MPDetection, imageWidth: Double, imageHeight: Double,
                                targetAngle: Double = palmTargetAngle) -> MPRect {
        var rotation = 0.0
        if d.keypoints.count > 2 {
            let x0 = d.keypoints[0].x * imageWidth, y0 = d.keypoints[0].y * imageHeight
            let x1 = d.keypoints[2].x * imageWidth, y1 = d.keypoints[2].y * imageHeight
            rotation = MPMath.normalizeRadians(targetAngle - atan2(-(y1 - y0), x1 - x0))
        }
        let raw = MPRect(cx: (d.box.xmin + d.box.xmax) / 2, cy: (d.box.ymin + d.box.ymax) / 2,
                         w: d.box.width, h: d.box.height, rotation: rotation)
        return raw.transformed(scale: palmScale, shiftY: palmShiftY, squareLong: true,
                               imageWidth: imageWidth, imageHeight: imageHeight)
    }

    /// Rect for the next frame from this frame's 21 landmarks (normalized to the image),
    /// as `HandLandmarksToRectCalculator`. nil when the points are not 21 finite values
    /// or the image size is not positive.
    public static func fromLandmarks(_ points: [HandPoint], imageWidth iw: Double, imageHeight ih: Double) -> MPRect? {
        guard points.count == MPLandmarks.count, iw > 0, ih > 0,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }

        // Rotation: wrist → mean of (index MCP, ring MCP) averaged with the middle MCP, target π/2.
        let x0 = points[0].x * iw, y0 = points[0].y * ih
        let x1 = ((points[5].x + points[13].x) / 2 + points[9].x) / 2 * iw
        let y1 = ((points[5].y + points[13].y) / 2 + points[9].y) / 2 * ih
        let rotation = MPMath.normalizeRadians(Double.pi / 2 - atan2(-(y1 - y0), x1 - x0))

        let used = trackLandmarkIDs.map { points[$0] }
        let xs = used.map(\.x), ys = used.map(\.y)
        // Rotation pivot is the centre of the axis-aligned box of those points.
        let ax = (xs.max()! + xs.min()!) / 2, ay = (ys.max()! + ys.min()!) / 2

        // Bounding box in the un-rotated frame (pixels around the pivot).
        let c = cos(-rotation), s = sin(-rotation)
        let rotated = used.map { p -> (x: Double, y: Double) in
            let ox = (p.x - ax) * iw, oy = (p.y - ay) * ih
            return (ox * c - oy * s, ox * s + oy * c)
        }
        let rx = rotated.map(\.x), ry = rotated.map(\.y)
        let pcx = (rx.max()! + rx.min()!) / 2, pcy = (ry.max()! + ry.min()!) / 2

        // Centre goes back through the rotation.
        let cr = cos(rotation), sr = sin(rotation)
        let centerX = pcx * cr - pcy * sr + iw * ax
        let centerY = pcx * sr + pcy * cr + ih * ay
        let raw = MPRect(cx: centerX / iw, cy: centerY / ih,
                         w: (rx.max()! - rx.min()!) / iw, h: (ry.max()! - ry.min()!) / ih,
                         rotation: rotation)
        return raw.transformed(scale: trackScale, shiftY: trackShiftY, squareLong: true,
                               imageWidth: iw, imageHeight: ih)
    }

    /// `RectTransformationCalculator`, in its order: shift along the rect's own axes (by
    /// the size BEFORE squaring), square to the longer side in pixels, then scale.
    public func transformed(scaleX: Double, scaleY: Double, shiftX: Double = 0, shiftY: Double,
                            squareLong: Bool = true, imageWidth iw: Double, imageHeight ih: Double) -> MPRect {
        var r = self
        if rotation == 0 {
            r.cx += w * shiftX
            r.cy += h * shiftY
        } else {
            let c = cos(rotation), s = sin(rotation)
            r.cx += (iw * w * shiftX * c - ih * h * shiftY * s) / iw
            r.cy += (iw * w * shiftX * s + ih * h * shiftY * c) / ih
        }
        var width = w, height = h
        if squareLong {
            let long = max(w * iw, h * ih)
            width = long / iw
            height = long / ih
        }
        r.w = width * scaleX
        r.h = height * scaleY
        return r
    }

    public func transformed(scale: Double, shiftX: Double = 0, shiftY: Double,
                            squareLong: Bool = true, imageWidth: Double, imageHeight: Double) -> MPRect {
        transformed(scaleX: scale, scaleY: scale, shiftX: shiftX, shiftY: shiftY, squareLong: squareLong,
                    imageWidth: imageWidth, imageHeight: imageHeight)
    }

    /// The four corners in image PIXELS: top-left, top-right, bottom-right, bottom-left of
    /// the rect's own frame, each turned by `rotation` around the centre (x' = x·cos − y·sin,
    /// y' = x·sin + y·cos, y down). Warping these onto a square's corners gives the crop,
    /// the same as OpenCV's `boxPoints` + `getPerspectiveTransform` in mediapipe.
    public func corners(imageWidth: Double, imageHeight: Double) -> [HandPoint] {
        let px = cx * imageWidth, py = cy * imageHeight
        let hw = w * imageWidth / 2, hh = h * imageHeight / 2
        let c = cos(rotation), s = sin(rotation)
        return [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { dx, dy in
            HandPoint(x: px + dx * c - dy * s, y: py + dx * s + dy * c)
        }
    }
}
