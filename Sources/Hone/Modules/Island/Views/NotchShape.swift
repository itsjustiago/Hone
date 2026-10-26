import SwiftUI

/// The island's outline: glued to the top edge of the screen like the physical
/// notch. Its top corners flare out in concave "ears" (the top edge is the full
/// width, the body `earRadius` narrower on each side) and its bottom corners are
/// rounded. Both radii animate, so the shape morphs as the island grows.
struct NotchShape: Shape {
    var earRadius: CGFloat
    var bottomRadius: CGFloat

    /// `IslandFrameProbe` only: told of every outline SwiftUI asks for, as it is
    /// that frame (the rect and both radii). `nil` in the app: one check a call.
    nonisolated(unsafe) static var probe: ((CGRect, CGFloat, CGFloat) -> Void)?

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(earRadius, bottomRadius) }
        set { earRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        Self.probe?(rect, earRadius, bottomRadius)
        // Radii never exceed what the rect can hold, so tiny sizes stay a valid shape.
        let ear = max(0, min(earRadius, rect.width / 4, rect.height / 2))
        let body = rect.width - 2 * ear
        let bottom = max(0, min(bottomRadius, body / 2, rect.height - ear))
        let left = rect.minX + ear, right = rect.maxX - ear
        let top = rect.minY, base = rect.maxY

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: top))
        // Left ear: concave, from the screen edge down into the body.
        path.addQuadCurve(to: CGPoint(x: left, y: top + ear), control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: base - bottom))
        path.addQuadCurve(to: CGPoint(x: left + bottom, y: base), control: CGPoint(x: left, y: base))
        path.addLine(to: CGPoint(x: right - bottom, y: base))
        path.addQuadCurve(to: CGPoint(x: right, y: base - bottom), control: CGPoint(x: right, y: base))
        path.addLine(to: CGPoint(x: right, y: top + ear))
        // Right ear, mirrored.
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top), control: CGPoint(x: right, y: top))
        path.closeSubpath()
        return path
    }
}
