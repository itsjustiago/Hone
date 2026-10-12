import XCTest
@testable import LidFoldKit

/// Pure logic only: the clock is whatever the test passes in.
final class LidMotionDetectorTests: XCTestCase {
    private let step = 1.0 / 8   // idle polling period

    /// Feeds `angle` every `step` in (start, end], returning the phase after the last one.
    @discardableResult
    private func feed(_ d: inout LidMotionDetector, angle: Double, after start: TimeInterval,
                      through end: TimeInterval) -> LidMotionDetector.Phase {
        var phase = d.phase
        var t = start + step
        while t <= end {
            phase = d.observe(angle: angle, at: t)
            t += step
        }
        return phase
    }

    func testStartsIdleAndStaysIdleWhenHeld() {
        var d = LidMotionDetector()
        XCTAssertEqual(d.phase, .idle)
        d.observe(angle: 100, at: 0)
        XCTAssertEqual(feed(&d, angle: 100, after: 0, through: 30), .idle)
    }

    func testOneDegreeWobbleNeverStartsMovement() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 0)
        for tick in 1...200 {
            // 99, 100, 101, 99... always within 1° of the anchor.
            let phase = d.observe(angle: 100 + Double(tick % 3 - 1), at: Double(tick) * step)
            XCTAssertEqual(phase, .idle)
        }
    }

    func testThreeDegreesFromTheAnchorStartsMovement() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 0)
        XCTAssertEqual(d.observe(angle: 99, at: step), .idle)
        XCTAssertEqual(d.observe(angle: 98, at: 2 * step), .idle, "2° is inside the sensor's own wobble")
        XCTAssertEqual(d.observe(angle: 97, at: 3 * step), .moving)
    }

    func testSlowCloseAccumulatesAgainstTheAnchor() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 0)
        // One degree every 4 s: far too slow for any step-to-step rule, but it
        // is measured against the unmoved anchor.
        XCTAssertEqual(d.observe(angle: 99, at: 0.5), .idle)
        XCTAssertEqual(d.observe(angle: 99, at: 1.5), .idle)
        XCTAssertEqual(d.observe(angle: 99, at: 2.5), .idle)
        XCTAssertEqual(d.observe(angle: 98, at: 3.0), .idle)
        XCTAssertEqual(d.observe(angle: 97, at: 4.0), .moving, "3° from the anchor, however slowly")
    }

    func testAOneDegreePerSecondCloseStillAccumulatesAndFires() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 0)
        var firedAt: TimeInterval?
        // One reading per 1/8 s, the angle drops 1° every second.
        for tick in 1...80 {
            let t = Double(tick) * step
            if d.observe(angle: 100 - (t).rounded(.down), at: t) == .moving && firedAt == nil { firedAt = t }
        }
        XCTAssertEqual(firedAt, 3, "the third degree is the first to reach the threshold")
    }

    func testAnchorOnlyAdvancesOnSignificantMovement() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 0)
        // Drifting 1° and back must not drag the anchor along.
        XCTAssertEqual(d.observe(angle: 101, at: 0.5), .idle)
        XCTAssertEqual(d.observe(angle: 100, at: 1.0), .idle)
        XCTAssertEqual(d.observe(angle: 99, at: 1.5), .idle)
        XCTAssertEqual(d.observe(angle: 98, at: 2.0), .idle)
        XCTAssertEqual(d.observe(angle: 97, at: 2.5), .moving)
    }

    func testStaysMovingWhileThreeDegreeChangesKeepComing() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 0)
        XCTAssertEqual(d.observe(angle: 97, at: step), .moving)
        var angle = 97.0
        var t = step
        // A 3° step every second: each one restarts the settle timer.
        for _ in 0..<30 {
            angle -= 3
            XCTAssertEqual(d.observe(angle: angle, at: t + step), .moving)
            t += step
            XCTAssertEqual(feed(&d, angle: angle, after: t, through: t + 0.875), .moving)
            t += 0.875
        }
    }

    /// A resting lid flipping between three neighbouring values, as seen on the
    /// real sensor. With a 2° threshold and the anchor on an extreme, the far
    /// extreme was 2° away and the anchor leapt back and forth forever.
    func testThreeValueWobbleNeverStartsMovementWhateverTheAnchor() {
        for start in [98.0, 99, 100] {
            var d = LidMotionDetector()
            d.observe(angle: start, at: 0)
            let cycle: [Double] = [98, 99, 100, 99]
            var moving = 0
            for tick in 1...240 { // 30 s at the idle rate
                if d.observe(angle: cycle[tick % cycle.count], at: Double(tick) * step) == .moving { moving += 1 }
            }
            XCTAssertEqual(moving, 0, "anchor started at \(start)")
        }
    }

    func testThreeValueWobbleDoesNotKeepAMovementAlive() {
        for start in [98.0, 99, 100] {
            var d = LidMotionDetector()
            d.observe(angle: 140, at: 0)
            XCTAssertEqual(d.observe(angle: start, at: step), .moving)
            let cycle: [Double] = [98, 99, 100, 99]
            var t = step
            var phase = LidMotionDetector.Phase.moving
            for tick in 0..<40 { // 5 s of wobble after the lid stopped
                t += step
                phase = d.observe(angle: cycle[tick % cycle.count], at: t)
            }
            XCTAssertEqual(phase, .idle, "anchor started at \(start)")
        }
    }

    func testRestingWobbleDoesNotKeepMovingAlive() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 0)
        XCTAssertEqual(d.observe(angle: 90, at: 0.125), .moving)
        // The lid has stopped but the sensor flips between 90 and 91.
        var t = 0.125
        var phase = LidMotionDetector.Phase.moving
        for tick in 1...24 {
            t += step
            phase = d.observe(angle: 90 + Double(tick % 2), at: t)
        }
        XCTAssertEqual(phase, .idle, "3 s of ±1° wobble must settle back to idle")
    }

    func testReturnsToIdleAfterSettleDelayWithoutChange() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 0)
        XCTAssertEqual(d.observe(angle: 90, at: 0.125), .moving)
        // The sensor keeps reporting 90: the 1.5 s count starts at the last change.
        XCTAssertEqual(feed(&d, angle: 90, after: 0.125, through: 0.125 + 1.375), .moving)
        XCTAssertEqual(d.observe(angle: 90, at: 0.125 + 1.5), .idle)
        XCTAssertEqual(d.observe(angle: 90, at: 0.125 + 1.625), .idle)
    }

    func testAThreeDegreeChangeRestartsTheSettleTimer() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 0)
        d.observe(angle: 90, at: 0.125)
        feed(&d, angle: 90, after: 0.125, through: 1)
        XCTAssertEqual(d.observe(angle: 87, at: 1.125), .moving)
        XCTAssertEqual(feed(&d, angle: 87, after: 1.125, through: 2.5), .moving, "1.375 s since the last change")
        XCTAssertEqual(d.observe(angle: 87, at: 2.625), .idle)
    }

    func testATwoDegreeChangeDoesNotRestartTheSettleTimer() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 0)
        d.observe(angle: 90, at: 0.125)
        feed(&d, angle: 90, after: 0.125, through: 1)
        XCTAssertEqual(d.observe(angle: 88, at: 1.125), .moving, "still inside the settle delay")
        XCTAssertEqual(feed(&d, angle: 88, after: 1.125, through: 1.5), .moving)
        XCTAssertEqual(d.observe(angle: 88, at: 1.625), .idle, "1.5 s since the last 3° change")
    }

    func testIdleAnchorIsTheRestingAngleAfterAMovement() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 0)
        d.observe(angle: 90, at: 0.125)
        XCTAssertEqual(feed(&d, angle: 90, after: 0.125, through: 1.75), .idle)
        XCTAssertEqual(d.observe(angle: 89, at: 1.875), .idle, "1° from the new resting anchor")
        XCTAssertEqual(d.observe(angle: 88, at: 2), .idle, "2° from it")
        XCTAssertEqual(d.observe(angle: 87, at: 2.125), .moving)
    }

    func testInvalidReadingsResetToIdleAndNeedAFreshAnchor() {
        let invalid: [Double?] = [nil, .nan, .infinity, -.infinity, -1, 181]
        for bad in invalid {
            var d = LidMotionDetector()
            d.observe(angle: 100, at: 0)
            XCTAssertEqual(d.observe(angle: 80, at: 0.1), .moving)
            XCTAssertEqual(d.observe(angle: bad, at: 0.2), .idle, "\(String(describing: bad))")
            XCTAssertEqual(d.phase, .idle)
            // A far-away valid angle only re-seeds the anchor; it is not motion.
            XCTAssertEqual(d.observe(angle: 40, at: 0.3), .idle)
            XCTAssertEqual(d.observe(angle: 37, at: 0.4), .moving)
        }
    }

    func testRangeEdgesAreValid() {
        var d = LidMotionDetector()
        d.observe(angle: 0, at: 0)
        XCTAssertEqual(d.observe(angle: 3, at: 0.1), .moving)
        d.observe(angle: 180, at: 0.2)
        XCTAssertEqual(d.observe(angle: 180, at: 0.3), .moving, "180 is still a valid reading")
    }

    func testGapOverOneSecondResetsButExactlyOneSecondDoesNot() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 0)
        XCTAssertEqual(d.observe(angle: 90, at: 0.125), .moving)
        XCTAssertEqual(d.observe(angle: 80, at: 1.125), .moving, "a 1 s gap still proves continuity")
        XCTAssertEqual(d.observe(angle: 60, at: 2.25), .idle, "1.125 s gap: sleep or lost reports")
        XCTAssertEqual(d.observe(angle: 57, at: 2.375), .moving, "the reading after the gap was only the new anchor")
    }

    func testClockGoingBackwardsResets() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 10)
        XCTAssertEqual(d.observe(angle: 90, at: 10.1), .moving)
        XCTAssertEqual(d.observe(angle: 80, at: 9.0), .idle)
        XCTAssertEqual(d.observe(angle: 77, at: 9.1), .moving)
    }

    func testNonFiniteClockResets() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 0)
        XCTAssertEqual(d.observe(angle: 90, at: 0.1), .moving)
        XCTAssertEqual(d.observe(angle: 90, at: .nan), .idle)
        XCTAssertEqual(d.observe(angle: 90, at: .infinity), .idle)
        XCTAssertEqual(d.observe(angle: 90, at: 1), .idle)
    }

    func testResetForgetsEverything() {
        var d = LidMotionDetector()
        d.observe(angle: 100, at: 0)
        XCTAssertEqual(d.observe(angle: 90, at: 0.1), .moving)
        d.reset()
        XCTAssertEqual(d.phase, .idle)
        XCTAssertEqual(d.observe(angle: 50, at: 0.2), .idle)
    }
}
