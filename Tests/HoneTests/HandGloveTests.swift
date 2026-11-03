import CoreGraphics
import XCTest
@testable import Hone

/// The cartoon glove's shapes, from a synthetic open hand pointing up (canvas coordinates:
/// origin top-left, y down; wrist to knuckles ≈ 220 px, like the overlay draws it).
final class HandGloveTests: XCTestCase {
    private static let openHand: [CGPoint] = [
        (0, 0),                                                   // 0 wrist
        (-45, -40), (-85, -85), (-115, -125), (-140, -160),       // 1–4 thumb
        (-50, -210), (-60, -280), (-65, -325), (-68, -365),       // 5–8 index
        (0, -225), (0, -300), (0, -350), (0, -392),               // 9–12 middle
        (48, -212), (55, -282), (60, -328), (63, -365),           // 13–16 ring
        (90, -185), (105, -240), (113, -275), (120, -305),        // 17–20 little
    ].map { CGPoint(x: 300 + $0.0, y: 450 + $0.1) }

    private func glove(scale: CGFloat = 1) -> HandGloveGeometry {
        HandGloveGeometry(points: Self.openHand.map { CGPoint(x: $0.x * scale, y: $0.y * scale) },
                          handSize: 220 * scale)
    }

    func testSilhouetteHoldsEveryJoint() {
        let g = glove()
        for (i, p) in Self.openHand.enumerated() {
            XCTAssertTrue(g.silhouette.contains(p, using: .winding), "joint \(i) outside the glove")
        }
    }

    func testSilhouetteHasNoHolesWhereShapesOverlap() {
        // Where the palm and the index finger overlap (the index knuckle) and between the
        // knuckles (palm only), the union must still be solid.
        let g = glove()
        let p = Self.openHand
        XCTAssertTrue(g.silhouette.contains(CGPoint(x: (p[5].x + p[9].x) / 2, y: (p[5].y + p[9].y) / 2)))
        XCTAssertTrue(g.silhouette.contains(CGPoint(x: p[5].x, y: p[5].y + 10)))
        XCTAssertTrue(g.palm.contains(p[0]))
        XCTAssertTrue(g.silhouette.contains(CGPoint(x: p[0].x, y: p[0].y + 20))) // the cuff, below the wrist
    }

    func testBoundsLeaveRoomForTheShadow() {
        let g = glove()
        let shape = g.silhouette.boundingBoxOfPath
        XCTAssertTrue(g.bounds.insetBy(dx: 20, dy: 20).contains(shape))
        XCTAssertFalse(shape.isEmpty)
    }

    func testRadiiScaleWithTheHand() {
        let small = glove(), large = glove(scale: 2)
        XCTAssertEqual(small.radius, HandGloveGeometry.fingerRadius * 220, accuracy: 1e-9)
        XCTAssertEqual(large.radius, small.radius * 2, accuracy: 1e-9)
        for (a, b) in zip(small.fingers, large.fingers) {
            for (ra, rb) in zip(a.radii, b.radii) { XCTAssertEqual(rb, ra * 2, accuracy: 1e-9) }
        }
        // A fat thumb and tapering tips.
        XCTAssertEqual(small.fingers[0].radii[0], 1.1 * small.radius, accuracy: 1e-9)
        XCTAssertEqual(small.fingers[1].radii[3], 0.85 * small.radius, accuracy: 1e-9)
    }

    func testFiveFingersOfFourJoints() {
        let g = glove()
        XCTAssertEqual(g.fingers.count, 5)
        for finger in g.fingers {
            XCTAssertEqual(finger.joints.count, 4)
            XCTAssertEqual(finger.radii.count, 4)
        }
        XCTAssertEqual(g.fingers[0].joints.first, Self.openHand[1]) // thumb starts at its CMC
        XCTAssertEqual(g.fingers[4].joints.last, Self.openHand[20])
        XCTAssertEqual(g.drawOrder, [4, 3, 2, 1, 0])                 // little finger first, thumb on top
    }

    func testLittleFingerHasAShape() {
        let finger = glove().fingers[4]
        XCTAssertFalse(finger.path.isEmpty)
        XCTAssertTrue(finger.path.contains(Self.openHand[19]))
        XCTAssertFalse(finger.path.contains(Self.openHand[12])) // the middle tip is not in it
    }

    func testDegenerateHandStillBuilds() {
        // Every joint on one spot (a glitch frame): no crash, a round blob.
        let g = HandGloveGeometry(points: Array(repeating: CGPoint(x: 100, y: 100), count: 21), handSize: 220)
        XCTAssertTrue(g.silhouette.contains(CGPoint(x: 100, y: 100)))
        XCTAssertTrue(g.bounds.width.isFinite && g.bounds.height.isFinite)
    }
}
