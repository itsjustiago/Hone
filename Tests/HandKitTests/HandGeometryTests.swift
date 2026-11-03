import XCTest
@testable import HandKit

// Port of handmouse.py's `selftest()` (minus `mix`, the border colour blend, which
// the HUD doesn't need).

private func pts(_ xy: [(Double, Double)]) -> [HandPoint] { xy.map { HandPoint(x: $0.0, y: $0.1) } }

final class GesturesTests: XCTestCase {
    private func run(_ seq: [(Double, Bool)]) -> [GestureEvent] {
        var g = Gestures()
        return seq.flatMap { g.update(t: $0.0, pinched: $0.1) }
    }

    func testTapIsALeftClickAfterTheDoubleWindow() {
        XCTAssertEqual(run([(0, true), (0.1, false), (0.5, false)]), [.leftClick])
    }

    func testDoubleTapIsARightClick() {
        XCTAssertEqual(run([(0, true), (0.1, false), (0.2, true), (0.3, false), (0.8, false)]), [.rightClick])
    }

    func testHoldIsADrag() {
        XCTAssertEqual(run([(0, true), (0.3, true), (0.6, false)]), [.dragStart, .dragEnd])
    }

    func testTapThenHoldIsAScroll() {
        XCTAssertEqual(run([(0, true), (0.1, false), (0.2, true), (0.5, true), (0.7, false)]), [.scrollStart, .scrollEnd])
    }

    func testNoPinchNoEvents() {
        XCTAssertEqual(run([(0, false), (0.5, false)]), [])
    }

    func testResetReleasesADrag() {
        var g = Gestures()
        _ = g.update(t: 0, pinched: true)
        _ = g.update(t: 0.3, pinched: true)
        XCTAssertEqual(g.reset(), [.dragEnd])
        XCTAssertEqual(g.state, .idle)
    }

    func testPinchHysteresis() {
        var p = Pinch()
        let on = 0.30, off = 0.40, mid = (on + off) / 2
        XCTAssertEqual([mid, on - 0.01, mid, off + 0.01, mid].map { p.update($0, on: on, off: off) },
                       [false, true, true, false, false])
    }
}

final class PoseTests: XCTestCase {
    func testPoseOf() {
        let out = Tuning.thumbOut
        XCTAssertEqual(poseOf(extended: [false, false, false, false], tuck: out - 0.1), .fist)
        XCTAssertEqual(poseOf(extended: [false, false, false, false], tuck: out + 0.1), .thumb)
        XCTAssertEqual(poseOf(extended: [true, false, false, true], tuck: out + 0.1), .rock)
        XCTAssertEqual(poseOf(extended: [true, false, false, true], tuck: out - 0.1), .point)  // thumb folded = not rock
        XCTAssertEqual(poseOf(extended: [true, true, true, true], tuck: out + 0.1), .point)    // open palm stays a cursor
        XCTAssertEqual(poseOf(extended: [true, false, false, false], tuck: 0.1), .fine)
        XCTAssertEqual(poseOf(extended: [true, false, false, false], tuck: out + 0.1), .fine)
    }

    func testThumbUp() {
        let zeros = [(Double, Double)](repeating: (0, 0), count: 16)
        let up = pts([(0, 0), (0, 0), (0.5, 0.5), (0.5, 0.4), (0.5, 0.3)] + zeros)    // joints 2, 3, 4 in a vertical line
        let bent = pts([(0, 0), (0, 0), (0.5, 0.5), (0.5, 0.4), (0.6, 0.4)] + zeros)  // tip bent sideways at the last joint
        let side = pts([(0, 0), (0, 0), (0.5, 0.5), (0.6, 0.5), (0.7, 0.5)] + zeros)  // straight but pointing sideways
        XCTAssertTrue(thumbUp(up))
        XCTAssertFalse(thumbUp(bent))
        XCTAssertFalse(thumbUp(side))
    }

    func testCtrlMove() {
        let f = false, t = true
        XCTAssertEqual(ctrlMove([t, f, f, f], thumbOut: f, thumbStraightUp: f), .paste)
        XCTAssertEqual(ctrlMove([t, f, f, t], thumbOut: f, thumbStraightUp: f), .enter)
        XCTAssertEqual(ctrlMove([f, f, f, t], thumbOut: t, thumbStraightUp: f), .undo)
        XCTAssertEqual(ctrlMove([f, f, f, f], thumbOut: t, thumbStraightUp: t), .duplicate)
        XCTAssertNil(ctrlMove([f, f, f, f], thumbOut: t, thumbStraightUp: f))  // bent
        XCTAssertNil(ctrlMove([f, f, f, f], thumbOut: f, thumbStraightUp: t))  // fist
        XCTAssertEqual(ctrlMove([t, t, t, t], thumbOut: t, thumbStraightUp: f), .neutral)
        XCTAssertEqual(ctrlMove([t, t, t, t], thumbOut: f, thumbStraightUp: f), .copy)
        XCTAssertNil(ctrlMove([t, t, f, f], thumbOut: t, thumbStraightUp: f))
    }
}

final class GeometryTests: XCTestCase {
    func testShapeDist() {
        XCTAssertEqual(shapeDist([0, 0, 1, 1], [0, 0, 1, 1]), 0)
        XCTAssertEqual(shapeDist([0, 0, 0, 0], [3, 4, 0, 0]), 2.5, accuracy: 1e-9)
    }

    /// 21 points at (0.5, 0.5) with the index tip at u, v of the default box.
    private func indexAt(_ u: Double, _ v: Double) -> [HandPoint] {
        let b = HandBox.default
        var p = [HandPoint](repeating: HandPoint(x: 0.5, y: 0.5), count: 21)
        p[8] = HandPoint(x: b.left + u * (b.right - b.left), y: b.top + v * (b.bottom - b.top))
        return p
    }

    func testEdgeSides() {
        let box = HandBox.default
        XCTAssertTrue(edgeSides(indexAt(0.5, 0.5), box: box) == (false, false, false, false))   // centre: quiet
        XCTAssertTrue(edgeSides(indexAt(0.5, 1.0), box: box) == (false, false, false, false))   // at the edge: quiet
        XCTAssertTrue(edgeSides(indexAt(0.99, 0.01), box: box) == (false, false, false, false))
        XCTAssertTrue(edgeSides(indexAt(0.5, 1.2), box: box).bottom)                            // outside: warn
        XCTAssertTrue(edgeSides(indexAt(-0.1, 0.5), box: box).left)
        var low = indexAt(0.5, 0.95)
        low[0] = HandPoint(x: 0.5, y: 0.999)                                                    // wrist at the bottom edge
        XCTAssertTrue(edgeSides(low, box: box) == (false, false, false, false))                 // index still inside: quiet
    }

    /// Wrist at 0; index..pinky knuckles at y = -length across width 0.3; fingertips at y = -r.
    private func hand(_ r: Double, length: Double = 0.5) -> [HandPoint] {
        var xy = [(Double, Double)](repeating: (0, 0), count: 5)
        for x in [-0.15, 0, 0.05, 0.15] { xy += [(x, -length), (0, 0), (0, 0), (x, -r)] }
        return pts(xy)
    }

    func testFlatCurl() {
        XCTAssertTrue(flatCurl(hand(1.5)) == (false, false))              // upright open hand (width/length 0.6)
        XCTAssertTrue(flatCurl(hand(0.25, length: 0.2)) == (true, true))  // tipped flat (short palm), tips pulled in
        XCTAssertTrue(flatCurl(hand(0.6, length: 0.2)) == (true, false))  // tipped flat, fingers still out
    }

    func testBoxFromDropsStrays() {
        var sweep = (0...1000).map { i in
            HandPoint(x: 0.5 + Double(i) / 1000 * 0.4, y: 0.1 + Double(i * 7 % 1001) / 1000 * 0.3)
        }
        sweep += [HandPoint(x: 0, y: 0), HandPoint(x: 1, y: 1)]
        let b = boxFrom(sweep)
        XCTAssertEqual(b.left, 0.5, accuracy: 0.02)
        XCTAssertEqual(b.top, 0.1, accuracy: 0.02)
        XCTAssertEqual(b.right, 0.9, accuracy: 0.02)
        XCTAssertEqual(b.bottom, 0.4, accuracy: 0.02)
    }
}

final class OneEuroTests: XCTestCase {
    func testJitterAtRestShrinks() {
        var e = OneEuro()
        let held = (0..<60).map { i in e(Double(i) / 30, 0.5 + (i % 2 == 1 ? 0.01 : -0.01), minCutoff: 0.8, beta: 6) }
        XCTAssertLessThan(held[30...].max()! - held[30...].min()!, 0.006)  // ±0.01 jitter at rest shrinks a lot
    }

    func testBarelyLagsARealMove() {
        var e = OneEuro()
        let moved = (0...30).map { i in e(Double(i) / 30, Double(i) / 30, minCutoff: 0.8, beta: 6) }  // 1 box/s
        XCTAssertGreaterThan(moved.last!, 0.9)
    }
}
