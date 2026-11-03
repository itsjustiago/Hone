import CoreGraphics

// The hand on screen as a white cartoon glove: `HandGloveGeometry` turns the 21 joints
// into shapes (pure, tested), `HandGlovePainter` shades them. CoreGraphics only.

// MARK: - Geometry

/// The glove's shapes, built from the 21 hand joints (MediaPipe order: 0 wrist · 1–4 thumb
/// CMC…tip · 5–8 index MCP…tip · 9–12 middle · 13–16 ring · 17–20 little) already placed on
/// the canvas, in pixels.
struct HandGloveGeometry {
    /// One finger: its joints from the base to the tip, the tube's radius at each, and the
    /// outline (the union of one tapered capsule per bone).
    struct Finger {
        var joints: [CGPoint]
        var radii: [CGFloat]
        var path: CGPath
    }

    /// Joints per finger, base to tip: thumb (from its CMC), index, middle, ring, little.
    static let fingerJoints: [[Int]] = [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12], [13, 14, 15, 16], [17, 18, 19, 20]]
    /// Each finger's base radius, in finger radii: a fat thumb, a slimmer little finger.
    private static let thickness: [CGFloat] = [1.1, 1, 1, 1, 0.9]
    /// Radius along a finger, base to tip, as a share of its base radius: the tips taper.
    private static let taper: [CGFloat] = [1, 1, 0.93, 0.85]
    /// Back to front: little finger first, thumb on top.
    private static let paintOrder = [4, 3, 2, 1, 0]
    /// Finger radius, in hand sizes: fat cartoon fingers that nearly touch at the knuckles.
    static let fingerRadius: CGFloat = 0.1
    /// Room around the silhouette for the drop shadow (offset (3, 6), blur 10), the ink
    /// outline and the halos and rings on the thumb and index tips.
    static let margin: CGFloat = 28

    /// Wrist to the middle of the index and middle knuckles, in pixels.
    let handSize: CGFloat
    /// The finger radius: `fingerRadius` of the hand size (22 pt for a 220 pt hand).
    let radius: CGFloat
    /// [thumb, index, middle, ring, little].
    let fingers: [Finger]
    /// Wrist, thumb base and the four knuckles, rounded by one finger radius.
    let palm: CGPath
    /// The glove's rolled cuff: a band across the wrist, flaring toward the arm.
    let cuff: CGPath
    /// Cuff, palm and fingers as one shape (a real union: one outline, no inner edges).
    let silhouette: CGPath
    /// Everything the glove can paint: the silhouette plus `margin`.
    let bounds: CGRect

    /// Indices into `fingers`, in paint order (little finger first, thumb on top).
    var drawOrder: [Int] { Self.paintOrder }

    init(points p: [CGPoint], handSize: CGFloat) {
        precondition(p.count >= 21, "21 hand joints expected")
        self.handSize = handSize
        let r = Self.fingerRadius * handSize
        radius = r

        var fingers = [Finger]()
        fingers.reserveCapacity(5)
        for (f, indices) in Self.fingerJoints.enumerated() {
            let joints = indices.map { p[$0] }
            let radii = Self.taper.map { $0 * Self.thickness[f] * r }
            var path = Self.capsule(joints[0], radii[0], joints[1], radii[1])
            for k in 1..<joints.count - 1 {
                path = path.union(Self.capsule(joints[k], radii[k], joints[k + 1], radii[k + 1]))
            }
            fingers.append(Finger(joints: joints, radii: radii, path: path))
        }
        self.fingers = fingers

        // Palm: the wrist widened across the hand (toward the thumb first, so the outline
        // never crosses itself), narrower than the knuckles.
        let wrist = p[0]
        let axis = (p[9] - wrist).unit ?? CGPoint(x: 0, y: -1)
        var across = CGPoint(x: -axis.y, y: axis.x)
        if (p[5] - p[17]).dot(across) < 0 { across = across * -1 }
        let half = 0.38 * (p[5] - p[17]).length
        let heel = wrist - axis * (0.04 * handSize)
        palm = Self.rounded([heel + across * half, p[1], p[5], p[9], p[13], p[17], heel - across * half], by: r)

        // Cuff: from just above the wrist to 0.12 hand sizes below it, wider than the palm and
        // flaring toward the arm.
        let top = wrist + axis * (0.03 * handSize), bottom = wrist - axis * (0.12 * handSize)
        let topHalf = half + 0.75 * r, bottomHalf = half + 1.05 * r // the palm reaches half + r
        cuff = Self.rounded([top + across * topHalf, bottom + across * bottomHalf,
                             bottom - across * bottomHalf, top - across * topHalf], by: 0.4 * r)

        silhouette = fingers.reduce(palm.union(cuff)) { $0.union($1.path) }
        bounds = silhouette.boundingBoxOfPath.insetBy(dx: -Self.margin, dy: -Self.margin)
    }

    /// A polygon grown by `radius` all round: round corners, no spikes.
    private static func rounded(_ corners: [CGPoint], by radius: CGFloat) -> CGPath {
        let polygon = CGMutablePath()
        polygon.addLines(between: corners)
        polygon.closeSubpath()
        return polygon.copy(strokingWithWidth: 2 * radius, lineCap: .round, lineJoin: .round, miterLimit: 10)
            .union(polygon)
    }

    /// Two circles and the outer tangents between them: a bone that narrows toward the tip
    /// without a step at the joints. Both arcs turn the same way, so every capsule has the
    /// same orientation.
    private static func capsule(_ a: CGPoint, _ ra: CGFloat, _ b: CGPoint, _ rb: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let d = (b - a).length
        guard d > abs(ra - rb) + 0.01 else {
            // One circle holds the other (a bone pointing at the camera).
            let (c, rr) = ra >= rb ? (a, ra) : (b, rb)
            path.addEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
            return path
        }
        let theta = atan2(b.y - a.y, b.x - a.x)
        let phi = acos((ra - rb) / d)
        path.addArc(center: a, radius: ra, startAngle: theta + phi, endAngle: theta - phi + 2 * .pi, clockwise: false)
        path.addArc(center: b, radius: rb, startAngle: theta - phi, endAngle: theta + phi, clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - Painter

/// Paints a `HandGloveGeometry` on a flipped canvas (origin top-left): drop shadow, ink
/// outline, a shaded palm and cuff, shaded fingers (back to front) and the click feedback on the
/// thumb and index tips. Light comes from the top left of the screen. Build one and keep
/// it: the gradients are made once.
final class HandGlovePainter {
    struct RGB {
        var r: CGFloat, g: CGFloat, b: CGFloat

        static func gray(_ v: CGFloat) -> RGB { RGB(r: v, g: v, b: v) }

        func blended(with other: RGB, _ t: CGFloat) -> RGB {
            RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
        }

        func cgColor(_ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        }
    }

    private let tint: RGB
    private let palmShade: CGGradient
    private let palmShadeBright: CGGradient
    private let fingerShade: CGGradient
    private let fingerShadeBright: CGGradient
    private let gloss: CGGradient

    /// How much of the tool colour a dragging glove takes.
    private static let brightMix: CGFloat = 0.2
    private static let ink = CGColor(gray: 0.12, alpha: 0.9)
    private static let seam = CGColor(gray: 0.25, alpha: 0.55)
    private static let crease = CGColor(gray: 0.3, alpha: 0.35)
    private static let highlight = CGColor(gray: 1, alpha: 0.6)
    private static let white = CGColor(gray: 1, alpha: 1)

    init(tint: RGB) {
        self.tint = tint
        // Palm: white at the top left, grey at the bottom right.
        let palm: [(CGFloat, RGB)] = [(0, .gray(1)), (1, .gray(0.80))]
        // Across a finger: a little dim at the lit edge, white just inside it, grey on the far side.
        let finger: [(CGFloat, RGB)] = [(0, .gray(0.95)), (0.3, .gray(1)), (1, .gray(0.78))]
        palmShade = Self.gradient(palm)
        palmShadeBright = Self.gradient(palm.map { ($0.0, $0.1.blended(with: tint, Self.brightMix)) })
        fingerShade = Self.gradient(finger)
        fingerShadeBright = Self.gradient(finger.map { ($0.0, $0.1.blended(with: tint, Self.brightMix)) })
        gloss = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [CGColor(gray: 1, alpha: 0.55), CGColor(gray: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    }

    private static func gradient(_ stops: [(CGFloat, RGB)]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: stops.map { $0.1.cgColor() } as CFArray,
                   locations: stops.map(\.0))!
    }

    /// `pinch` 0…1 lights the thumb and index tips; `ringed` (click, drag) rings them;
    /// `bright` (drag) tints the whole glove.
    func paint(_ glove: HandGloveGeometry, in ctx: CGContext, pinch: CGFloat, ringed: Bool, bright: Bool) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setShadow(offset: .zero, blur: 0, color: nil) // the glove casts its own shadows
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // 1. Drop shadow. Shadow offsets live in base space (y up), not in the flipped
        //    canvas: a negative height puts it below the glove.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 3, height: -6), blur: 10, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(glove.silhouette)
        ctx.setFillColor(Self.white)
        ctx.fillPath()
        ctx.restoreGState()

        // 2. Ink outline: the fills below cover its inner half, leaving a clean 1.5 pt line.
        ctx.addPath(glove.silhouette)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(Self.ink)
        ctx.strokePath()

        // 3. Palm: shaded from the top left, with a soft gloss.
        let box = glove.palm.boundingBoxOfPath
        ctx.saveGState()
        ctx.addPath(glove.palm)
        ctx.clip()
        ctx.drawLinearGradient(bright ? palmShadeBright : palmShade,
                               start: CGPoint(x: box.minX, y: box.minY), end: CGPoint(x: box.maxX, y: box.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let glossCenter = CGPoint(x: box.minX + box.width * 0.35, y: box.minY + box.height * 0.35)
        ctx.drawRadialGradient(gloss, startCenter: glossCenter, startRadius: 0,
                               endCenter: glossCenter, endRadius: min(box.width, box.height) * 0.5, options: [])
        ctx.restoreGState()

        // 4. Cuff over the palm's heel: the same shading, and an ink seam where it meets the palm.
        let band = glove.cuff.boundingBoxOfPath
        ctx.saveGState()
        ctx.addPath(glove.cuff)
        ctx.clip()
        ctx.drawLinearGradient(bright ? palmShadeBright : palmShade,
                               start: CGPoint(x: band.minX, y: band.minY), end: CGPoint(x: band.maxX, y: band.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.addPath(glove.cuff)
        ctx.setLineWidth(2.5)
        ctx.setStrokeColor(Self.seam)
        ctx.strokePath()
        ctx.restoreGState()

        // 5. Fingers, back to front.
        let shade = bright ? fingerShadeBright : fingerShade
        for i in glove.drawOrder {
            paintFinger(glove.fingers[i], in: ctx, shade: shade)
        }

        // 6. Feedback on the thumb and index tips.
        let tips = [glove.fingers[0].joints[3], glove.fingers[1].joints[3]]
        let r = glove.radius
        if pinch > 0.01 {
            let color = tint.cgColor(min(pinch, 1) * 0.9)
            let hr = r * (1 + 0.4 * min(pinch, 1))
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6, color: color)
            for tip in tips { ctx.addEllipse(in: CGRect(x: tip.x - hr, y: tip.y - hr, width: hr * 2, height: hr * 2)) }
            ctx.setFillColor(color)
            ctx.fillPath() // one fill: where the two halos meet they don't add up
            ctx.restoreGState()
        }
        if ringed {
            let outer = r + 6
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 3, color: CGColor(gray: 0, alpha: 0.45))
            ctx.setLineWidth(2.5)
            ctx.setStrokeColor(Self.white)
            for tip in tips { ctx.strokeEllipse(in: CGRect(x: tip.x - outer, y: tip.y - outer, width: outer * 2, height: outer * 2)) }
            ctx.restoreGState()
            let inner = outer - 2
            ctx.setLineWidth(1.5)
            ctx.setStrokeColor(tint.cgColor())
            for tip in tips { ctx.strokeEllipse(in: CGRect(x: tip.x - inner, y: tip.y - inner, width: inner * 2, height: inner * 2)) }
        }
    }

    /// One finger: shaded across its length, a seam where it lies over the palm or another
    /// finger, a highlight on the lit side and a crease at the two middle joints.
    private func paintFinger(_ finger: HandGloveGeometry.Finger, in ctx: CGContext, shade: CGGradient) {
        let j = finger.joints
        let base = j[0], tip = j[j.count - 1]
        let baseRadius = finger.radii[0]
        let firstBone = (j[1] - base).unit ?? CGPoint(x: 0, y: -1)
        // A curled finger can end on its own knuckle: then its first bone says where it points.
        let along = (tip - base).length > baseRadius ? (tip - base).unit ?? firstBone : firstBone
        let lit = along.normalTowardLight

        ctx.saveGState()
        ctx.addPath(finger.path)
        ctx.clip()
        ctx.drawLinearGradient(shade, start: base + lit * baseRadius, end: base - lit * baseRadius,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        // Past the knuckle only: no seam or crease across the palm where the finger starts.
        let reach = baseRadius * 20
        let side = CGPoint(x: -firstBone.y, y: firstBone.x)
        ctx.addLines(between: [base + side * reach, base + side * reach + firstBone * reach,
                               base - side * reach + firstBone * reach, base - side * reach])
        ctx.closePath()
        ctx.clip()

        // Seam: the finger's own edge, inner half only (the clip keeps the rest out).
        ctx.addPath(finger.path)
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(Self.seam)
        ctx.strokePath()

        // Highlight: from halfway along the first bone to just short of the tip.
        var line = [CGPoint]()
        line.append((j[0] + j[1]) * 0.5 + lit * (0.45 * (finger.radii[0] + finger.radii[1]) / 2))
        for k in 1..<j.count - 1 { line.append(j[k] + lit * (0.45 * finger.radii[k])) }
        let lastBone = (tip - j[j.count - 2]).unit ?? along
        line.append(tip - lastBone * (0.35 * finger.radii[j.count - 1]) + lit * (0.45 * finger.radii[j.count - 1]))
        ctx.addLines(between: line)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(Self.highlight)
        ctx.strokePath()

        // Creases at the two middle joints: short arcs across the finger, bowed toward the tip.
        for k in 1...2 {
            let dir = (j[k + 1] - j[k - 1]).unit ?? along
            let across = CGPoint(x: -dir.y, y: dir.x)
            let half = 0.45 * finger.radii[k]
            ctx.move(to: j[k] - across * half)
            ctx.addQuadCurve(to: j[k] + across * half, control: j[k] + dir * (0.5 * finger.radii[k]))
        }
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(Self.crease)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

// MARK: - Vector helpers (this file only)

private extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }

    var length: CGFloat { hypot(x, y) }
    func dot(_ o: CGPoint) -> CGFloat { x * o.x + y * o.y }

    /// Unit vector, or nil when too short to have a direction.
    var unit: CGPoint? {
        let l = length
        return l > 1e-6 ? CGPoint(x: x / l, y: y / l) : nil
    }

    /// The normal of this direction that faces the light (top left of a flipped canvas).
    var normalTowardLight: CGPoint {
        let n = CGPoint(x: -y, y: x)
        return n.dot(CGPoint(x: -1, y: -1)) >= 0 ? n : n * -1
    }
}
