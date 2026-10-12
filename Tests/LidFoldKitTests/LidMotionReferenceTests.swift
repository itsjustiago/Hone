// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import Foundation
import Testing
@testable import LidFoldKit

/// Feeds a run of readings that the dwell has already classified.
private func hold(_ reference: inout LidMotionReference, at angle: Double,
                  jitter: [Double] = [], clearWhenStill: Bool = true) {
    reference.observe(angle: angle, isStill: true, clearWhenStill: clearWhenStill)
    for offset in jitter {
        reference.observe(angle: angle+offset, isStill: true, clearWhenStill: clearWhenStill)
    }
}

private func move(_ reference: inout LidMotionReference, through angles: [Double],
                  clearWhenStill: Bool = true) {
    for angle in angles {
        reference.observe(angle: angle, isStill: false, clearWhenStill: clearWhenStill)
    }
}

@Test func withoutARestingAngleTheSavedSettingIsTheReference() {
    let reference = LidMotionReference()
    #expect(reference.restingAngle == nil)
    #expect(reference.reference(clearAngle: 105) == 105)
    #expect(reference.reference(clearAngle: 128.3) == 128.3)
    #expect(reference.reference(clearAngle: 60) == 60)
    #expect(reference.reference(clearAngle: 140) == 140)
    // The setting keeps its own documented limits.
    #expect(reference.reference(clearAngle: 40) == 60)
    #expect(reference.reference(clearAngle: 5) == 60)
    #expect(reference.reference(clearAngle: 200) == 140)
    #expect(reference.reference(clearAngle: .nan) == 105)
    #expect(reference.reference(clearAngle: .infinity) == 105)
    #expect(reference.reference(clearAngle: -.infinity) == 105)
}

/// The user's example: hold at 90, let the desktop clear, then move to 88. That
/// two-degree move must be measured from 90, not from the saved 128.3 setting.
@Test func aMoveAfterTheDwellIsMeasuredFromTheRestingAngle() {
    var reference = LidMotionReference()
    let saved = 128.3
    hold(&reference, at: 90)
    #expect(reference.restingAngle == 90)
    #expect(reference.reference(clearAngle: saved) == 90)

    move(&reference, through: [88])
    #expect(reference.reference(clearAngle: saved) == 90)   // Retained until the next dwell.
    let rebased = FoldMath.progress(angle: 88, clearAngle: reference.reference(clearAngle: saved))
    let stale = FoldMath.progress(angle: 88, clearAngle: saved)
    #expect(rebased > 0 && rebased < 0.01)
    #expect(stale > 0.15)
    #expect(rebased < stale/10)

    // Continuing to close from the same reference keeps building.
    let further = FoldMath.progress(angle: 75, clearAngle: reference.reference(clearAngle: saved))
    #expect(further > rebased)
    #expect(reference.reference(clearAngle: saved) == 90)
}

@Test func openingAboveTheRestingAngleStaysClear() {
    var reference = LidMotionReference()
    hold(&reference, at: 90)
    move(&reference, through: [92, 96, 104])
    let live = reference.reference(clearAngle: 128.3)
    #expect(live == 90)
    for angle in [90.0, 92, 96, 104, 130, 180] {
        #expect(FoldMath.progress(angle: angle, clearAngle: live) == 0)
    }
}

@Test func oneDegreeJitterDoesNotMoveTheAnchor() {
    var reference = LidMotionReference()
    hold(&reference, at: 90, jitter: [1, -1, 0, 1, -1, 1])
    #expect(reference.restingAngle == 90)
    #expect(reference.reference(clearAngle: 128.3) == 90)
}

@Test func aLaterDwellReAnchorsUpwardAndDownward() {
    var reference = LidMotionReference()
    hold(&reference, at: 90)
    move(&reference, through: [95, 102, 110])
    hold(&reference, at: 110, jitter: [-1, 1])
    #expect(reference.restingAngle == 110)          // No permanent downward ratchet.
    #expect(reference.reference(clearAngle: 128.3) == 110)
    move(&reference, through: [102, 88, 70])
    hold(&reference, at: 70)
    #expect(reference.reference(clearAngle: 128.3) == 70)
}

/// Repeated dwell, re-anchor and move cycles must leave exactly one reference:
/// the angle of the most recent completed dwell.
@Test func repeatedStillnessAndMovementTracksOnlyTheLastRest() {
    var reference = LidMotionReference()
    var expected = 0.0
    for rest in [120.0, 96, 108, 64, 140, 82] {
        move(&reference, through: [rest+9, rest+4, rest+2])
        hold(&reference, at: rest, jitter: [1, -1])
        expected = rest
        #expect(reference.restingAngle == expected)
        let live = reference.reference(clearAngle: 128.3)
        #expect(live == min(expected, 128.3))
        // Measured from the live reference, one degree is barely there and
        // further closing keeps building, whatever the rest angle was.
        let small = FoldMath.progress(angle: live-1, clearAngle: live)
        let medium = FoldMath.progress(angle: live-5, clearAngle: live)
        let large = FoldMath.progress(angle: live-15, clearAngle: live)
        #expect(small < 0.01)
        #expect(small < medium && medium < large)
    }
}

@Test func aLowRestingAngleIsNotRaisedToTheSettingFloor() {
    var reference = LidMotionReference()
    hold(&reference, at: 45)
    #expect(reference.reference(clearAngle: 105) == 45)
    #expect(reference.reference(clearAngle: 60) == 45)
    #expect(reference.reference(clearAngle: 140) == 45)
    // A lid that came to rest closed still yields a usable reference.
    hold(&reference, at: 45, jitter: [])             // No edge: still 45.
    move(&reference, through: [20, 8])
    hold(&reference, at: 0)
    #expect(reference.restingAngle == 0)
    #expect(reference.reference(clearAngle: 105) == 5)
    move(&reference, through: [4])
    hold(&reference, at: 3)
    #expect(reference.reference(clearAngle: 105) == 5)
}

@Test func aRestingAngleAboveTheSettingCapsAtTheSetting() {
    var reference = LidMotionReference()
    hold(&reference, at: 170)
    #expect(reference.restingAngle == 170)
    #expect(reference.reference(clearAngle: 128.3) == 128.3)
    #expect(reference.reference(clearAngle: 105) == 105)
    #expect(reference.reference(clearAngle: 200) == 140)
    #expect(reference.reference(clearAngle: 40) == 60)
    #expect(reference.reference(clearAngle: .nan) == 105)
    move(&reference, through: [150])
    hold(&reference, at: 141)
    #expect(reference.reference(clearAngle: 140) == 140)
}

@Test func turningOffClearWhenStillDropsTheReference() {
    var reference = LidMotionReference()
    hold(&reference, at: 90)
    reference.observe(angle: 90, isStill: true, clearWhenStill: false)
    #expect(reference.restingAngle == nil)
    #expect(reference.reference(clearAngle: 128.3) == 128.3)
    // Re-enabling while the lid is already still re-anchors at the current angle
    // instead of reviving the cleared edge.
    reference.observe(angle: 111, isStill: true, clearWhenStill: true)
    #expect(reference.restingAngle == 111)
}

@Test func invalidReadingsAndResetClearTheReferenceAndTheEdge() {
    let invalid: [Double?] = [nil, Double.nan, Double.infinity, -Double.infinity, 181, -1, 200]
    for reading in invalid {
        var reference = LidMotionReference()
        hold(&reference, at: 90)
        reference.observe(angle: reading, isStill: true, clearWhenStill: true)
        #expect(reference.restingAngle == nil)
        #expect(reference.reference(clearAngle: 128.3) == 128.3)
        // The cleared edge means the next valid still reading anchors afresh.
        reference.observe(angle: 100, isStill: true, clearWhenStill: true)
        #expect(reference.restingAngle == 100)
    }
    var reference = LidMotionReference()
    hold(&reference, at: 90)
    reference.reset()
    #expect(reference.restingAngle == nil)
    #expect(reference.reference(clearAngle: 105) == 105)
    reference.observe(angle: 90, isStill: true, clearWhenStill: true)
    #expect(reference.restingAngle == 90)
}

/// Whatever the history, the reference stays inside the documented range and
/// never rises above the user's own clear limit.
@Test func theReferenceStaysFiniteBoundedAndAtMostTheSetting() {
    var reference = LidMotionReference()
    var still = false
    for step in 0...400 {
        let angle = 90+40*sin(Double(step)/7)
        still = step%13 == 0 ? !still : still
        reference.observe(angle: angle, isStill: still, clearWhenStill: true)
        for setting in [60.0, 90, 105, 128.3, 140, .nan, 200] {
            let live = reference.reference(clearAngle: setting)
            let clamped = setting.isFinite ? Swift.min(140, Swift.max(60, setting)) : 105
            #expect(live.isFinite)
            #expect(live >= 5 && live <= 140)
            #expect(live <= clamped)
            if let resting = reference.restingAngle {
                #expect(live == Swift.max(5, Swift.min(resting, clamped)))
            } else {
                #expect(live == clamped)
            }
        }
    }
}

/// A resting lid flipping between three neighbouring values still counts as
/// still (the stillness anchor tolerates it), so the resting angle is recorded
/// once and the wobble never walks it. With a 2° anchor threshold the lid never
/// settled and the reference stayed on the saved setting.
@Test func aThreeValueWobbleStillAnchorsTheReferenceOnce() {
    var stillness = LidStillness()
    var reference = LidMotionReference()
    let cycle: [Double] = [98, 99, 100, 99]
    var seen = Set<Double>()
    for tick in 0..<240 { // 30 s at the idle rate
        let angle = cycle[tick % cycle.count]
        let settled = stillness.observe(angle: angle, at: Double(tick)/8)
        reference.observe(angle: angle, isStill: settled, clearWhenStill: true)
        if let resting = reference.restingAngle { seen.insert(resting) }
    }
    #expect(seen.count == 1, "one dwell, one anchor")
    #expect(reference.restingAngle.map { (98.0...100).contains($0) } == true)
}
