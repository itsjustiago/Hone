import XCTest
@testable import HandKit

// Port of handmouse.py's `selftest()` (minus `mix`, the border colour blend, which
// the HUD doesn't need).

private func pts(_ xy: [(Double, Double)]) -> [HandPoint] { xy.map { HandPoint(x: $0.0, y: $0.1) } }

final class PinchTests: XCTestCase {
    func testPinchHysteresisAndDebounce() {
        var p = Pinch()
        let on = 0.30, off = 0.40, mid = (on + off) / 2
        // one frame under the line is not enough; two in a row flip it; mid-band holds it
        XCTAssertEqual([mid, on - 0.01, mid, on - 0.01, on - 0.01, mid, off + 0.01, mid, off + 0.01, off + 0.01]
                        .map { p.update($0, on: on, off: off) },
                       [false, false, false, false, true, true, true, true, true, false])
    }

    func testDebounceNeedsFramesInARow() {
        var d = Debounce()
        XCTAssertEqual([true, false, true, true, true, false, false].map { d.update($0, frames: 3) },
                       [false, false, false, false, true, true, true])
    }

    func testPrecisionGain() {
        XCTAssertEqual(precisionGain(speed: 0, fine: 0.4), 0.4)
        XCTAssertEqual(precisionGain(speed: Tuning.slowSpeed, fine: 0.4), 0.4)
        XCTAssertEqual(precisionGain(speed: (Tuning.slowSpeed + Tuning.fastSpeed) / 2, fine: 0.4), 0.7, accuracy: 1e-9)
        XCTAssertEqual(precisionGain(speed: 5, fine: 0.4), 1)
    }
}

final class PoseTests: XCTestCase {
    func testPoseOf() {
        XCTAssertEqual(poseOf(extended: [false, false, false, false], thumbOut: false), .fist)
        XCTAssertEqual(poseOf(extended: [false, false, false, false], thumbOut: true), .thumb)
        XCTAssertEqual(poseOf(extended: [true, false, false, true], thumbOut: true), .rock)
        XCTAssertEqual(poseOf(extended: [true, false, false, true], thumbOut: false), .point)  // thumb folded = not rock
        XCTAssertEqual(poseOf(extended: [true, true, true, true], thumbOut: true), .point)     // open palm stays a cursor
        XCTAssertEqual(poseOf(extended: [true, false, false, false], thumbOut: false), .point) // index alone: plain pointing
    }

    func testGesturePose() {
        let none = [false, false, false, false]
        XCTAssertEqual(gesturePose(extended: none, thumbOut: false, thumbUp: false, tight: true), .fist)
        XCTAssertEqual(gesturePose(extended: none, thumbOut: false, thumbUp: false, tight: false), .point)  // relaxed hand: no command
        XCTAssertEqual(gesturePose(extended: none, thumbOut: true, thumbUp: true, tight: false), .thumb)
        XCTAssertEqual(gesturePose(extended: none, thumbOut: true, thumbUp: false, tight: true), .fist)    // thumb out sideways
        XCTAssertEqual(gesturePose(extended: none, thumbOut: true, thumbUp: false, tight: false), .point)
        XCTAssertEqual(gesturePose(extended: [true, false, false, true], thumbOut: true, thumbUp: false, tight: false), .rock)
        XCTAssertEqual(gesturePose(extended: [true, false, false, true], thumbOut: false, thumbUp: false, tight: true), .point)
        XCTAssertEqual(gesturePose(extended: [true, true, true, true], thumbOut: true, thumbUp: true, tight: false), .point)
    }

    func testFistTightAndNearBox() {
        XCTAssertTrue(fistTight(FakeHand.fist.points))
        XCTAssertFalse(fistTight(FakeHand.relaxed.points))
        XCTAssertFalse(fistTight(FakeHand.open.points))
        XCTAssertTrue(extended(FakeHand.relaxed.points) == [false, false, false, false])  // curled, just not tight
        XCTAssertTrue(thumbUp(FakeHand.thumbsUp.points))
        XCTAssertFalse(thumbUp(FakeHand.relaxed.points))  // thumb out to the side

        let box = HandBox.default  // 0.50…0.95 × 0.40…0.85
        XCTAssertTrue(nearBox(HandPoint(x: 0.7, y: 0.65), box: box))     // inside
        XCTAssertTrue(nearBox(HandPoint(x: 0.7, y: 0.94), box: box))     // in the margin
        XCTAssertTrue(nearBox(HandPoint(x: 0.41, y: 0.35), box: box))
        XCTAssertFalse(nearBox(HandPoint(x: 0.7, y: 0.96), box: box))    // past the margin: hand going down
        XCTAssertFalse(nearBox(HandPoint(x: 1.06, y: 0.65), box: box))
        XCTAssertFalse(nearBox(HandPoint(x: 0.39, y: 0.65), box: box))
        XCTAssertFalse(nearBox(HandPoint(x: 0.7, y: 0.29), box: box))
    }

    func testExtendedByBendAngle() {
        XCTAssertEqual(extended(FakeHand.open.points), [true, true, true, true])
        XCTAssertEqual(extended(FakeHand.fist.points), [false, false, false, false])
        XCTAssertEqual(extended(FakeHand.rock.points), [true, false, false, true])
        // leaning at the camera: bones a third as long, still straight → still extended
        XCTAssertEqual(extended(FakeHand.open.with { $0.tilt = 0.35 }.points), [true, true, true, true])
    }

    func testExtendedHysteresisAndShortBones() {
        // index bent ~60° at its middle joint: curled from scratch, kept extended if it was
        var p = FakeHand.open.points
        let pip = p[6]
        let len = 0.045 / Tuning.aspect
        let a = 60.0 * .pi / 180
        p[8] = HandPoint(x: pip.x + sin(a) * len, y: pip.y - cos(a) * 0.045)
        XCTAssertFalse(extended(p)[0])
        XCTAssertTrue(extended(p, was: [true, true, true, true])[0])
        // finger aimed at the camera (bones collapse to a dot): keeps whatever it was
        var dot = FakeHand.open.points
        for j in 6...8 { dot[j] = HandPoint(x: dot[5].x, y: dot[5].y - 0.001 * Double(j - 5)) }
        XCTAssertTrue(extended(dot, was: [true, true, true, true])[0])
        XCTAssertFalse(extended(dot, was: [false, true, true, true])[0])
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

    /// Point at u, v of the default box.
    private func at(_ u: Double, _ v: Double) -> HandPoint {
        let b = HandBox.default
        return HandPoint(x: b.left + u * (b.right - b.left), y: b.top + v * (b.bottom - b.top))
    }

    func testEdgeSides() {
        let box = HandBox.default
        XCTAssertTrue(edgeSides(at(0.5, 0.5), box: box) == (false, false, false, false))   // centre: quiet
        XCTAssertTrue(edgeSides(at(0.5, 1.0), box: box) == (false, false, false, false))   // at the edge: quiet
        XCTAssertTrue(edgeSides(at(0.99, 0.01), box: box) == (false, false, false, false))
        XCTAssertTrue(edgeSides(at(0.5, 1.2), box: box).bottom)                            // outside: warn
        XCTAssertTrue(edgeSides(at(-0.1, 0.5), box: box).left)
    }

    func testControlPointIsTheKnuckleMidpoint() {
        let p = FakeHand.open.points
        XCTAssertEqual(controlPoint(p).x, (p[5].x + p[9].x) / 2, accuracy: 1e-12)
        XCTAssertEqual(controlPoint(FakeHand.open.with { $0.thumb = .pinchIndex }.points), controlPoint(p))  // pinching doesn't move it
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
        XCTAssertFalse(flatCurl(hand(1.5, length: 0.27)).flat)            // a slight tilt (1.1) no longer counts as flat
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

final class LandmarkSmootherTests: XCTestCase {
    func testDoubtfulJointsKeepTheirSpotOnTheHand() {
        var sm = LandmarkSmoother()
        let a = FakeHand.open.landmarks
        _ = sm(0, a)
        // whole hand shifts right; the thumb tip is reported far off with low confidence
        var moved = FakeHand.open.at(0.825, 0.625).points
        moved[4] = HandPoint(x: 0, y: 0)
        var conf = [Double](repeating: 0.9, count: 21)
        conf[4] = 0.1
        let out = sm(10, HandLandmarks(points: moved, confidence: conf)!)  // long gap: the filter jumps
        XCTAssertEqual(out[4].x, a[4].x + 0.1, accuracy: 0.002)  // carried along with the hand, not to (0, 0)
        XCTAssertEqual(out[4].y, a[4].y, accuracy: 0.002)
    }
}
