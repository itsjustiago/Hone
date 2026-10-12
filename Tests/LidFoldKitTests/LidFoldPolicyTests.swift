import XCTest
@testable import LidFoldKit

private typealias Policy = LidFoldPolicy
private typealias Reason = LidFoldPolicy.FailOpenReason
private typealias Decision = LidFoldPolicy.Decision

/// A stand-in for the controller: it keeps the real detector, stillness and
/// reference fed from the same readings, carries out each decision the way the
/// controller does (capture, overlay, animation) and feeds the result back.
/// Pure and clock-free: time only moves when a test moves it.
private struct Rig {
    var policy = LidFoldPolicy()
    var detector = LidMotionDetector()
    var stillness = LidStillness()
    var motion = LidMotionReference()
    var animation = FoldVisualAnimation()

    var now: TimeInterval = 1000
    var angle: Double?
    var lastReadingAt: TimeInterval?
    var phase = LidMotionDetector.Phase.idle

    var sessionActive = true, systemAwake = true, displayAwake = true, hasDisplay = true
    var captureWanted = true
    /// Seconds after the capture starts until its first frame; nil = never arrives.
    var frameDelay: TimeInterval? = 0.2

    // The world as the decisions left it.
    private(set) var panelExists = false
    private(set) var captureRunning = false
    private(set) var captureStartedAt: TimeInterval = 0
    var hasFrame = false
    private(set) var overlayVisible = false
    private(set) var overlayVisibleSince: TimeInterval?
    private var visual = FoldVisualState.clear
    private var target = FoldVisualState.clear
    var demoAngle: Double?

    private(set) var last = Decision.idle
    /// Everything decided so far, to assert on whole timelines.
    private(set) var history: [Decision] = []

    init(angle: Double? = nil) {
        if let angle { _ = reading(angle) }
    }

    // MARK: Driving

    /// One sensor report: feeds detector, stillness and reference, then evaluates.
    @discardableResult
    mutating func reading(_ value: Double?, after dt: TimeInterval? = nil) -> Decision {
        now += dt ?? (phase == .moving ? 1.0 / 60 : 1.0 / 8)
        angle = value
        lastReadingAt = now
        phase = detector.observe(angle: value, at: now)
        let settled = stillness.observe(angle: value, at: now, delay: 2)
        motion.observe(angle: value, isStill: settled, clearWhenStill: true)
        return evaluate()
    }

    /// Time passes with no new sensor report (a timer tick).
    @discardableResult
    mutating func tick(_ dt: TimeInterval = 0.1) -> Decision {
        now += dt
        return evaluate()
    }

    /// Moves the lid from `from` to `to` in whole degrees over `seconds` at 60 Hz.
    @discardableResult
    mutating func sweep(from: Double, to: Double, seconds: TimeInterval) -> [Decision] {
        let steps = max(1, Int(seconds * 60))
        var out: [Decision] = []
        for step in 1...steps {
            let value = (from + (to - from) * Double(step) / Double(steps)).rounded()
            out.append(reading(value, after: 1.0 / 60))
        }
        return out
    }

    /// The lid rests at `value`; reports come at the idle rate, timer ticks in between.
    @discardableResult
    mutating func rest(at value: Double, seconds: TimeInterval) -> [Decision] {
        var out: [Decision] = []
        let end = now + seconds
        while now < end - 1e-9 {
            out.append(tick(0.05))
            out.append(reading(value, after: 0.075))
        }
        return out
    }

    /// Wake-up / restart: the sensor starts over, nothing is remembered.
    mutating func resetLid() {
        detector.reset(); stillness.reset(); motion.reset()
        phase = .idle; angle = nil; lastReadingAt = nil
    }

    // MARK: Evaluation

    mutating func input() -> Policy.Input {
        var i = Policy.Input(now: now, angle: demoAngle ?? angle, lastReadingAt: demoAngle == nil ? lastReadingAt : now)
        i.phase = phase
        i.isStill = stillness.isStill
        i.reference = demoAngle == nil ? motion.reference(clearAngle: 105) : 105
        i.sessionActive = sessionActive; i.systemAwake = systemAwake; i.displayAwake = displayAwake
        i.hasLiveBuiltInDisplay = hasDisplay
        i.captureWanted = captureWanted
        i.demoRunning = demoAngle != nil
        i.hasFrame = hasFrame
        i.overlayVisible = overlayVisible
        i.overlayVisibleSince = overlayVisibleSince
        i.visualIsClear = visual.isClear
        return i
    }

    @discardableResult
    mutating func evaluate() -> Decision {
        if captureRunning, !hasFrame, let delay = frameDelay, now - captureStartedAt >= delay { hasFrame = true }
        if overlayVisible { visual = animation.sample(target: target, at: now) }
        let decision = policy.evaluate(input())
        return carryOut(decision)
    }

    /// An event the controller routes to `policy.failOpen`.
    @discardableResult
    mutating func event(_ reason: Reason) -> Decision {
        carryOut(policy.failOpen(reason))
    }

    private mutating func carryOut(_ d: Decision) -> Decision {
        last = d; history.append(d)
        if d.failOpen != nil {
            panelExists = false; captureRunning = false; hasFrame = false
            overlayVisible = false; overlayVisibleSince = nil
            demoAngle = nil
            animation.reset(); visual = .clear; target = .clear
            return d
        }
        target = d.target
        panelExists = d.wantPanel
        if d.wantCapture && !captureRunning { captureRunning = true; captureStartedAt = now }
        if !d.wantCapture { captureRunning = false; hasFrame = false }
        if d.wantOverlay && !overlayVisible {
            overlayVisible = true; overlayVisibleSince = now
            animation.reset(); visual = .clear
        } else if !d.wantOverlay && overlayVisible {
            overlayVisible = false; overlayVisibleSince = nil
            animation.reset(); visual = .clear
        }
        return d
    }

    /// Everything off: what a resting lid and a fail-open both must look like.
    var isResting: Bool {
        !panelExists && !captureRunning && !overlayVisible && policy.stage == .dormant && !last.needsTicks
    }
}

private func XCTAssertNothingWanted(_ d: Decision, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(d.wantPanel, "panel \(message)", file: file, line: line)
    XCTAssertFalse(d.wantCapture, "capture \(message)", file: file, line: line)
    XCTAssertFalse(d.wantOverlay, "overlay \(message)", file: file, line: line)
    XCTAssertFalse(d.needsTicks, "ticks \(message)", file: file, line: line)
}

final class LidFoldPolicyTests: XCTestCase {
    // MARK: - Scenarios

    /// A rig inside a fold: closed from 130 to 80, a frame delivered, overlay up.
    private func foldingRig(file: StaticString = #filePath, line: UInt = #line) -> Rig {
        var rig = Rig(angle: 130)
        rig.rest(at: 130, seconds: 1)
        rig.sweep(from: 130, to: 80, seconds: 1.5)
        XCTAssertTrue(rig.overlayVisible, "setup: the overlay should be up", file: file, line: line)
        XCTAssertTrue(rig.captureRunning, file: file, line: line)
        return rig
    }

    // MARK: - Resting lid = nothing

    func testRestingLidNeverWantsCaptureOrOverlay() {
        // Ten minutes at the idle rate, at an angle where MacDuo would be capturing.
        var rig = Rig()
        for _ in 0..<(8 * 60 * 10) {
            let d = rig.reading(60)
            XCTAssertEqual(d, .idle)
        }
        XCTAssertEqual(rig.policy.stage, .dormant)
        XCTAssertTrue(rig.isResting)
    }

    func testRestingLidNeedsNoTimer() {
        var rig = Rig(angle: 90)
        let decisions = rig.rest(at: 90, seconds: 5)
        XCTAssertTrue(decisions.allSatisfy { !$0.needsTicks && !$0.wantPanel })
    }

    func testWakingUpAtALowAngleStartsNothing() {
        var rig = Rig()
        rig.rest(at: 40, seconds: 3)
        rig.systemAwake = false; rig.displayAwake = false
        XCTAssertEqual(rig.evaluate(), .idle, "asleep and dormant: nothing to do")
        rig.systemAwake = true; rig.displayAwake = true
        rig.resetLid() // the sensor restarts from scratch
        let decisions = rig.rest(at: 40, seconds: 5)
        XCTAssertTrue(decisions.allSatisfy { $0 == .idle }, "still: no capture on wake")
        XCTAssertTrue(rig.isResting)
    }

    func testOneDegreeWobbleOnAClosedLidIsNotMovement() {
        var rig = Rig()
        rig.rest(at: 50, seconds: 2)
        for i in 0..<400 {
            XCTAssertEqual(rig.reading(i.isMultiple(of: 2) ? 50 : 51), .idle)
        }
    }

    func testAnOldFailOpenDoesNotLeaveAnythingBehind() {
        var rig = foldingRig()
        rig.event(.spaceChanged)
        XCTAssertTrue(rig.isResting)
        let decisions = rig.rest(at: 80, seconds: 5)
        XCTAssertTrue(decisions.allSatisfy { $0 == .idle })
    }

    // MARK: - Session start

    func testMovingBelowTheReferenceStartsASessionWithoutAnOverlay() {
        var rig = Rig(angle: 130)
        rig.rest(at: 130, seconds: 1)
        var firstCapture: Rig? = nil
        var snapshot: Decision?
        for step in 1...120 { // 130 -> 90 over two seconds
            let d = rig.reading((130 - Double(step) / 3).rounded(), after: 1.0 / 60)
            if d.wantCapture && firstCapture == nil { firstCapture = rig; snapshot = d }
            XCTAssertFalse(d.wantOverlay && !rig.hasFrame, "no overlay before there is a frame")
        }
        let started = try? XCTUnwrap(firstCapture)
        XCTAssertNotNil(started)
        XCTAssertLessThan(started?.angle ?? 200, 105, "starts only below the reference")
        XCTAssertEqual(started?.phase, .moving)
        XCTAssertEqual(snapshot?.wantPanel, true)
        XCTAssertEqual(snapshot?.needsTicks, true)
        XCTAssertEqual(snapshot?.wantOverlay, false)
    }

    func testTheReferenceItselfIsExclusive() {
        func decide(angle: Double, reference: Double = 105) -> Decision {
            var policy = LidFoldPolicy()
            var i = Policy.Input(now: 10, angle: angle, lastReadingAt: 10)
            i.phase = .moving
            i.reference = reference
            return policy.evaluate(i)
        }
        XCTAssertTrue(decide(angle: 104.9).wantCapture, "just below: there is a fold to show")
        XCTAssertEqual(decide(angle: 105), .idle, "at the reference the fold is still zero")
        XCTAssertEqual(decide(angle: 118.9), .idle, "the old +14° margin is gone")
        XCTAssertEqual(decide(angle: 160), .idle)
        XCTAssertTrue(decide(angle: 69.9, reference: 70).wantCapture)
        XCTAssertEqual(decide(angle: 70, reference: 70), .idle)
    }

    func testMovementAboveTheReferenceStartsNothing() {
        var rig = Rig(angle: 175)
        let decisions = rig.sweep(from: 175, to: 106, seconds: 2)
        XCTAssertTrue(decisions.allSatisfy { $0 == .idle })
        XCTAssertTrue(rig.isResting)
    }

    // MARK: - The capture follows the policy fold after fold

    /// The policy's own decisions, carried out on a real `CaptureSession` over a
    /// fake capture. The pure `Rig` cannot catch a latch that outlives a fold: it
    /// models the capture as a boolean.
    @MainActor
    func testEveryFoldAfterANormalEndAsksForTheCaptureAgain() async {
        let capture = FakeCapture()
        let session = CaptureSession(capture)
        var rig = Rig(angle: 130)
        rig.rest(at: 130, seconds: 1)
        for fold in 1...3 {
            var decisions = rig.sweep(from: 130, to: 80, seconds: 1.5)
            decisions += rig.rest(at: 80, seconds: 5)           // held: the display clears
            decisions += rig.sweep(from: 80, to: 130, seconds: 1.5)
            decisions += rig.rest(at: 130, seconds: 3)           // back at rest
            XCTAssertTrue(decisions.contains { $0.wantCapture }, "fold \(fold) wanted a capture")
            for decision in decisions {
                let task = session.reconcile(wantCapture: decision.wantCapture, request: .anyDisplay,
                                             isCurrent: { true }, onError: { _ in })
                await task?.value
            }
            XCTAssertEqual(capture.startCount, fold, "fold \(fold) must start its own capture")
            XCTAssertFalse(capture.isRunning, "and stop it when it ends")
            XCTAssertTrue(rig.isResting)
        }
    }

    // MARK: - The recording indicator only lights for a real fold

    /// A rig whose lid has rested at `angle` long enough for it to be the reference.
    private func restingRig(at angle: Double) -> Rig {
        var rig = Rig(angle: angle)
        rig.rest(at: angle, seconds: 3)
        XCTAssertEqual(rig.motion.reference(clearAngle: 105), min(angle, 105), "setup: the dwell set the reference")
        return rig
    }

    func testOpeningTheLidFromItsReferenceNeverWantsACapture() {
        var rig = restingRig(at: 100)
        let opening = rig.sweep(from: 100, to: 110, seconds: 1)
        XCTAssertTrue(opening.allSatisfy { $0 == .idle }, "opening is not a fold: no panel, no capture, no ticks")
        // And the same for readjusting upwards after the lid came to rest again.
        let settle = rig.rest(at: 110, seconds: 3)
        XCTAssertTrue(settle.allSatisfy { $0 == .idle })
        let nudge = rig.sweep(from: 110, to: 125, seconds: 1)
        XCTAssertTrue(nudge.allSatisfy { $0 == .idle })
        XCTAssertFalse(rig.history.contains { $0.wantCapture || $0.wantPanel || $0.wantOverlay })
        XCTAssertTrue(rig.isResting)
    }

    func testAdjustingTheLidAboveTheReferenceNeverWantsACapture() {
        // 110° -> 104° is a real 6° movement, but it ends above a reference of 100°.
        var rig = restingRig(at: 100)
        rig.sweep(from: 100, to: 112, seconds: 1)
        let down = rig.sweep(from: 112, to: 103, seconds: 1)
        XCTAssertTrue(down.allSatisfy { $0 == .idle })
        XCTAssertFalse(rig.history.contains { $0.wantCapture })
    }

    func testClosingFromTheReferenceWantsACaptureAsSoonAsItIsBelow() throws {
        var rig = restingRig(at: 105)
        var first: (angle: Double, decision: Decision)?
        for step in 1...60 where first == nil { // 105 -> 95 over one second
            let angle = (105 - Double(step) / 6).rounded()
            let decision = rig.reading(angle, after: 1.0 / 60)
            if decision.wantCapture { first = (angle, decision) }
        }
        let started = try XCTUnwrap(first)
        XCTAssertLessThan(started.angle, 105, "never at or above the reference")
        XCTAssertGreaterThanOrEqual(started.angle, 101, "and right away: as soon as the sensor calls it a movement")
        XCTAssertTrue(started.decision.wantPanel)
        XCTAssertFalse(started.decision.wantOverlay, "no frame yet")
        XCTAssertEqual(started.decision.target, FoldVisualState.at(angle: started.angle, reference: 105))
        XCTAssertGreaterThan(started.decision.target.progress, 0, "the capture was asked for with a fold to show")
    }

    func testEveryCaptureRequestComesWithAFoldToShow() {
        // Wobble the lid through the reference in both directions: whenever a
        // capture is wanted from rest, the angle must be below the reference.
        var rig = restingRig(at: 100)
        var angle = 100.0
        for step in 0..<400 {
            angle = 100 + 14 * sin(Double(step) / 25)
            let was = rig.policy.stage
            let d = rig.reading(angle.rounded(), after: 1.0 / 60)
            if was == .dormant && d.wantCapture {
                XCTAssertLessThan(angle.rounded(), 100, "step \(step): started a session above the reference")
            }
        }
    }

    func testALidThatRisesAboveTheReferenceAndComesBackKeepsOneSessionAndOneCapture() {
        var rig = restingRig(at: 100)
        rig.sweep(from: 100, to: 94, seconds: 0.5)
        XCTAssertTrue(rig.captureRunning)
        let rising = rig.sweep(from: 94, to: 110, seconds: 0.6)
        XCTAssertTrue(rising.last?.target.isClear ?? false, "above the reference nothing is left to show")
        let falling = rig.sweep(from: 110, to: 92, seconds: 0.6)
        XCTAssertTrue(falling.last?.wantCapture ?? false)
        XCTAssertFalse(falling.last?.target.isClear ?? true, "the fold follows the lid down again")
        XCTAssertNil(rig.history.compactMap(\.failOpen).first)
    }

    func testAfterTheSessionEndedAboveTheReferenceANewFoldStartsANewSession() {
        var rig = restingRig(at: 100)
        rig.sweep(from: 100, to: 94, seconds: 0.5)
        rig.sweep(from: 94, to: 112, seconds: 0.5)
        rig.rest(at: 112, seconds: 4)
        XCTAssertTrue(rig.isResting, "the first session is over")
        XCTAssertEqual(rig.motion.reference(clearAngle: 105), 105, "112 rests above the setting, capped at it")
        let again = rig.sweep(from: 112, to: 96, seconds: 0.8)
        XCTAssertTrue(again.contains { $0.wantCapture })
    }

    func testAMoveFromRestIsMeasuredFromTheRestingAngle() {
        // Rest at 70, then close a little: the effect is relative to 70, not 105.
        var rig = Rig(angle: 70)
        rig.rest(at: 70, seconds: 3)
        XCTAssertEqual(rig.motion.restingAngle, 70)
        let decisions = rig.sweep(from: 70, to: 64, seconds: 0.5)
        let target = decisions.last { $0.wantCapture }?.target
        XCTAssertEqual(target?.referenceAngle, 70)
        XCTAssertLessThan(target?.progress ?? 1, 0.15, "a small move stays a small fold")
    }

    func testTargetFollowsTheAngleAndReference() {
        var rig = foldingRig()
        let d = rig.reading(80, after: 1.0 / 60)
        XCTAssertEqual(d.target, FoldVisualState.at(angle: 80, reference: 105))
    }

    func testPhaseCanArriveBeforeTheReadingThatConfirmsIt() {
        // LidSensor delivers onPhase before onReading: stale stillness must not start a session.
        var policy = LidFoldPolicy()
        var i = Policy.Input(now: 5, angle: 100, lastReadingAt: 5)
        i.phase = .moving; i.isStill = true
        XCTAssertEqual(policy.evaluate(i), .idle)
        i.now = 5.016; i.lastReadingAt = 5.016; i.isStill = false
        XCTAssertTrue(policy.evaluate(i).wantCapture)
    }

    func testNothingStartsWhileTheSystemIsAsleepOrLocked() {
        for flag in 0..<3 {
            var policy = LidFoldPolicy()
            var i = Policy.Input(now: 5, angle: 90, lastReadingAt: 5)
            i.phase = .moving
            if flag == 0 { i.systemAwake = false }
            if flag == 1 { i.displayAwake = false }
            if flag == 2 { i.sessionActive = false }
            XCTAssertEqual(policy.evaluate(i), .idle, "flag \(flag)")
        }
    }

    // MARK: - The overlay needs a frame, or the Fade

    func testNoOverlayBeforeTheFirstFrame() {
        var rig = Rig(angle: 130)
        rig.frameDelay = nil
        rig.rest(at: 130, seconds: 1)
        let decisions = rig.sweep(from: 130, to: 100, seconds: 1.0)
        XCTAssertTrue(decisions.contains { $0.wantCapture })
        XCTAssertTrue(decisions.allSatisfy { !$0.wantOverlay }, "progress is rising but there is no frame")
    }

    func testOverlayAppearsOnceTheFrameArrives() {
        var rig = Rig(angle: 130)
        rig.frameDelay = nil
        rig.rest(at: 130, seconds: 1)
        rig.sweep(from: 130, to: 95, seconds: 1.0)
        XCTAssertFalse(rig.overlayVisible)
        rig.hasFrame = true
        let d = rig.reading(94, after: 1.0 / 60)
        XCTAssertTrue(d.wantOverlay)
        XCTAssertTrue(rig.overlayVisible)
    }

    func testFadeModeShowsTheOverlayWithoutAFrameOrACapture() {
        var rig = Rig(angle: 130)
        rig.captureWanted = false
        rig.frameDelay = nil
        rig.rest(at: 130, seconds: 1)
        rig.sweep(from: 130, to: 80, seconds: 1.5)
        XCTAssertTrue(rig.overlayVisible, "the Fade needs no frame")
        XCTAssertTrue(rig.history.allSatisfy { !$0.wantCapture }, "and never captures")
        rig.tick(0.5); rig.tick(0.5)
        XCTAssertNotEqual(rig.last.failOpen, .noFrame, "no frame deadline without a capture")
    }

    func testNoOverlayWhileProgressIsZero() {
        var rig = Rig(angle: 130)
        rig.rest(at: 130, seconds: 1)
        // Above the reference (105) there is no fold: nothing is captured or shown.
        let decisions = rig.sweep(from: 130, to: 106, seconds: 1.0)
        XCTAssertTrue(decisions.allSatisfy { !$0.wantCapture && !$0.wantOverlay && !$0.wantPanel })
    }

    // MARK: - No frame in time

    func testGivesUpAfterOneSecondOfRisingProgressWithoutAFrame() {
        var rig = Rig(angle: 130)
        rig.frameDelay = nil
        rig.rest(at: 130, seconds: 1)
        rig.sweep(from: 130, to: 100, seconds: 1.0)
        XCTAssertNil(rig.last.failOpen)
        // Hold the fold (no more than the stillness delay) and wait for the deadline.
        var gaveUpAfter: TimeInterval?
        let began = rig.now
        for _ in 0..<15 {
            let d = rig.reading(100, after: 0.075)
            if d.failOpen == .noFrame { gaveUpAfter = rig.now - began; break }
        }
        XCTAssertNotNil(gaveUpAfter)
        XCTAssertLessThan(gaveUpAfter ?? 9, 1.2)
        XCTAssertGreaterThan(gaveUpAfter ?? 0, 0.5)
        XCTAssertTrue(rig.isResting)
        XCTAssertFalse(rig.overlayVisible, "never shown")
    }

    func testFrameDeadlineRestartsWhenProgressFallsBackToZero() {
        var policy = LidFoldPolicy()
        func input(_ t: TimeInterval, _ angle: Double) -> Policy.Input {
            var i = Policy.Input(now: t, angle: angle, lastReadingAt: t)
            i.phase = .moving
            return i
        }
        XCTAssertNil(policy.evaluate(input(0, 100)).failOpen)
        XCTAssertNil(policy.evaluate(input(0.8, 95)).failOpen)
        XCTAssertNil(policy.evaluate(input(0.9, 110)).failOpen, "progress back to zero")
        XCTAssertNil(policy.evaluate(input(1.5, 95)).failOpen, "a new rise starts a new deadline")
        XCTAssertNil(policy.evaluate(input(2.4, 94)).failOpen)
        XCTAssertEqual(policy.evaluate(input(2.5, 94)).failOpen, .noFrame)
    }

    func testAFrameInTimeCancelsTheDeadline() {
        var rig = Rig(angle: 130)
        rig.frameDelay = 0.6
        rig.rest(at: 130, seconds: 1)
        rig.sweep(from: 130, to: 100, seconds: 1.0)
        rig.reading(100, after: 0.4)
        rig.reading(100, after: 0.4)
        XCTAssertTrue(rig.overlayVisible)
        XCTAssertNil(rig.last.failOpen)
    }

    // MARK: - The end of a fold

    func testStillnessClearsTheFoldThenStopsTheCapture() throws {
        var rig = foldingRig()
        XCTAssertEqual(rig.last.target, FoldVisualState.at(angle: 80, reference: 105))
        // The lid rests. Until the 2 s dwell completes, the fold stays as it is.
        var sawClearTarget = false
        var clearingBegan: TimeInterval?
        var overlayGoneAt: TimeInterval?
        var captureStoppedAt: TimeInterval?
        let restBegan = rig.now
        for _ in 0..<400 {
            let d = rig.tick(0.05)
            let r = rig.reading(80, after: 0.075)
            for decision in [d, r] {
                if decision.target.isClear && decision.wantPanel && !sawClearTarget {
                    sawClearTarget = true; clearingBegan = rig.now
                }
                if sawClearTarget, !decision.wantOverlay, overlayGoneAt == nil { overlayGoneAt = rig.now }
                if sawClearTarget, !decision.wantCapture, captureStoppedAt == nil { captureStoppedAt = rig.now }
            }
            if rig.isResting { break }
        }
        let began = try XCTUnwrap(clearingBegan)
        XCTAssertGreaterThanOrEqual(began - restBegan, 2.0 - 0.01, "clears after the dwell, not before")
        XCTAssertLessThan(began - restBegan, 2.5)
        let gone = try XCTUnwrap(overlayGoneAt)
        XCTAssertGreaterThan(gone - began, 0.4, "the fold animates away first")
        XCTAssertLessThan(gone - began, 1.0)
        let stopped = try XCTUnwrap(captureStoppedAt)
        XCTAssertGreaterThanOrEqual(stopped - began, Policy.captureStopDelay - 0.01, "capture outlives the clear")
        XCTAssertLessThan(stopped - began, Policy.captureStopDelay + 0.2)
        XCTAssertGreaterThanOrEqual(stopped, gone, "never stops under a visible overlay")
        XCTAssertTrue(rig.isResting)
        XCTAssertEqual(rig.reading(80), .idle, "and stays that way")
    }

    /// Folding at 80 degrees with a frame and an overlay, then the lid comes to rest.
    private func clearingPolicy(visualIsClear: Bool) -> (LidFoldPolicy, Policy.Input) {
        var policy = LidFoldPolicy()
        var i = Policy.Input(now: 0, angle: 80, lastReadingAt: 0)
        i.phase = .moving
        _ = policy.evaluate(i)
        i.hasFrame = true; i.overlayVisible = true; i.overlayVisibleSince = 0; i.visualIsClear = visualIsClear
        i.now = 0.1; i.lastReadingAt = 0.1; i.isStill = true; i.phase = .idle
        let clearing = policy.evaluate(i)
        XCTAssertTrue(clearing.target.isClear); XCTAssertTrue(clearing.wantCapture)
        XCTAssertEqual(clearing.wantOverlay, !visualIsClear)
        return (policy, i)
    }

    func testAnAnimationThatNeverReportsClearIsHiddenByTheHardCap() {
        var (policy, i) = clearingPolicy(visualIsClear: false)
        i.now = 1.0; i.lastReadingAt = 1.0
        XCTAssertTrue(policy.evaluate(i).wantOverlay, "within the cap")
        i.now = 1.5; i.lastReadingAt = 1.5
        let before = policy.evaluate(i)
        XCTAssertTrue(before.wantOverlay); XCTAssertTrue(before.wantCapture)
        i.now = 1.7; i.lastReadingAt = 1.7 // 1.6 s after the clear began, cap is 1.5
        XCTAssertEqual(policy.evaluate(i), .idle, "overlay hidden by the cap, and the capture goes with it")
        XCTAssertEqual(policy.stage, .dormant)
    }

    func testCaptureOutlivesTheOverlayByItsLingerTime() {
        var (policy, i) = clearingPolicy(visualIsClear: true)
        // The animation is already clear: the overlay is done at once, the capture is not.
        i.now = 0.5; i.lastReadingAt = 0.5
        let lingering = policy.evaluate(i)
        XCTAssertFalse(lingering.wantOverlay)
        XCTAssertTrue(lingering.wantCapture, "kept warm in case the lid moves again")
        XCTAssertTrue(lingering.needsTicks)
        i.overlayVisible = false
        i.now = 1.2; i.lastReadingAt = 1.2 // 1.1 s after the clear began
        XCTAssertTrue(policy.evaluate(i).wantCapture)
        i.now = 1.35; i.lastReadingAt = 1.35 // 1.25 s
        XCTAssertEqual(policy.evaluate(i), .idle)
    }

    func testMovingAgainWhileClearingResumesTheSameSession() {
        var rig = foldingRig()
        // Rest long enough for the clear to begin, but not to finish.
        var cleared = false
        while !cleared {
            rig.tick(0.05)
            cleared = rig.reading(80, after: 0.075).target.isClear
        }
        let decisions = rig.sweep(from: 80, to: 70, seconds: 0.4)
        XCTAssertTrue(decisions.allSatisfy { $0.wantCapture }, "the warm capture is kept, not restarted")
        XCTAssertFalse(decisions.last?.target.isClear ?? true, "and the fold follows the lid again")
        XCTAssertNil(rig.last.failOpen)
    }

    func testOpeningTheLidBackAboveTheReferenceEndsTheSession() {
        var rig = foldingRig()
        rig.sweep(from: 80, to: 130, seconds: 1.0)
        // The overlay was handed back, the capture winds down.
        for _ in 0..<60 { rig.reading(130, after: 1.0 / 60) }
        rig.rest(at: 130, seconds: 2)
        XCTAssertTrue(rig.isResting)
        XCTAssertNil(rig.history.compactMap(\.failOpen).first, "a normal end is not a fail-open")
    }

    func testAFullCloseHoldAndReopenLeavesNothingBehind() {
        var rig = Rig(angle: 140)
        rig.rest(at: 140, seconds: 1)
        rig.sweep(from: 140, to: 60, seconds: 3)
        rig.rest(at: 60, seconds: 4)
        rig.sweep(from: 60, to: 140, seconds: 3)
        rig.rest(at: 140, seconds: 4)
        XCTAssertTrue(rig.isResting)
        XCTAssertTrue(rig.history.compactMap(\.failOpen).isEmpty)
        XCTAssertTrue(rig.history.contains { $0.wantOverlay })
        // The capture is wanted only between the first movement and the end of the second.
        let captureSpan = rig.history.filter(\.wantCapture).count
        XCTAssertGreaterThan(captureSpan, 0)
        XCTAssertFalse(rig.history.suffix(40).contains { $0.wantCapture })
    }

    // MARK: - Fail-open: every reason

    private func assertFailsOpen(_ rig: inout Rig, _ reason: Reason, file: StaticString = #filePath, line: UInt = #line) {
        let d = rig.last
        XCTAssertEqual(d.failOpen, reason, file: file, line: line)
        XCTAssertNothingWanted(d, "after \(reason)", file: file, line: line)
        XCTAssertTrue(rig.isResting, "after \(reason)", file: file, line: line)
        XCTAssertEqual(rig.policy.stage, .dormant, file: file, line: line)
        XCTAssertFalse(rig.overlayVisible, file: file, line: line)
    }

    func testFailOpenOnNilReading() {
        var rig = foldingRig()
        rig.reading(nil)
        assertFailsOpen(&rig, .sensorUnavailable)
    }

    func testFailOpenWhenTheSensorGoesSilent() {
        var rig = foldingRig()
        rig.tick(0.5)
        XCTAssertNil(rig.last.failOpen, "half a second of silence is fine")
        rig.tick(0.45) // 0.95 s since the last report
        XCTAssertNil(rig.last.failOpen)
        rig.tick(0.1) // beyond one second
        assertFailsOpen(&rig, .sensorStale)
    }

    func testFailOpenOnSystemSleep() {
        var rig = foldingRig()
        rig.systemAwake = false; rig.tick()
        assertFailsOpen(&rig, .systemSleep)
    }

    func testFailOpenOnScreensAsleep() {
        var rig = foldingRig()
        rig.displayAwake = false; rig.tick()
        assertFailsOpen(&rig, .screensAsleep)
    }

    func testFailOpenOnSessionResignation() {
        var rig = foldingRig()
        rig.sessionActive = false; rig.tick()
        assertFailsOpen(&rig, .sessionInactive)
    }

    func testFailOpenWhenTheBuiltInDisplayIsGoneMirroredOrInactive() {
        var rig = foldingRig()
        rig.hasDisplay = false; rig.tick()
        assertFailsOpen(&rig, .displayUnavailable)
    }

    func testFailOpenWhenCaptureIsSwitchedOffMidFold() {
        var rig = foldingRig()
        rig.captureWanted = false; rig.tick()
        assertFailsOpen(&rig, .captureDisabled)
    }

    func testSwitchingCaptureOnMidFoldWaitsForTheNextFold() {
        var rig = Rig(angle: 130)
        rig.captureWanted = false
        rig.rest(at: 130, seconds: 1)
        rig.sweep(from: 130, to: 80, seconds: 1.5)
        XCTAssertTrue(rig.overlayVisible)
        rig.captureWanted = true
        rig.tick()
        XCTAssertNil(rig.last.failOpen)
        XCTAssertFalse(rig.last.wantCapture, "this fold stays a Fade")
    }

    func testFailOpenWhenTheFrameDisappearsUnderTheOverlay() {
        var rig = foldingRig()
        rig.hasFrame = false
        rig.frameDelay = nil
        rig.tick()
        assertFailsOpen(&rig, .captureUnavailable)
    }

    func testFailOpenOnTheWatchdogAfterSixtySecondsOfOverlay() {
        // Keep the lid wobbling by more than the resting threshold so no dwell ends the fold.
        var rig = foldingRig()
        let began = rig.overlayVisibleSince ?? rig.now
        var failed: Reason?
        var elapsed = 0.0
        var up = false
        while failed == nil && elapsed < 70 {
            up.toggle()
            let d = rig.reading(up ? 85 : 80, after: 0.1)
            elapsed = rig.now - began
            failed = d.failOpen
            if failed == nil { XCTAssertTrue(rig.overlayVisible, "still up at \(elapsed)") }
        }
        XCTAssertEqual(failed, .watchdog)
        XCTAssertGreaterThanOrEqual(elapsed, Policy.watchdog)
        XCTAssertLessThan(elapsed, Policy.watchdog + 0.5)
        assertFailsOpen(&rig, .watchdog)
    }

    func testTheWatchdogIsContinuousVisibilityNotSessionAge() {
        // A fold that hides and shows again restarts the clock.
        var policy = LidFoldPolicy()
        var i = Policy.Input(now: 100, angle: 80, lastReadingAt: 100)
        i.phase = .moving; i.hasFrame = true
        i.overlayVisible = true; i.overlayVisibleSince = 100
        _ = policy.evaluate(i)
        i.now = 159.9; i.lastReadingAt = 159.9
        XCTAssertNil(policy.evaluate(i).failOpen)
        i.now = 160; i.lastReadingAt = 160
        XCTAssertEqual(policy.evaluate(i).failOpen, .watchdog)
    }

    func testFailOpenOnEveryExternalEvent() {
        let events: [Reason] = [.screenParametersChanged, .spaceChanged, .captureFailed("boom"), .captureUnavailable,
                                .rendererFailed("gpu"), .noFrame, .stopped, .clockAnomaly]
        for reason in events {
            var rig = foldingRig()
            let d = rig.event(reason)
            XCTAssertEqual(d.failOpen, reason)
            assertFailsOpen(&rig, reason)
        }
    }

    func testFailOpenOnANonFiniteClock() {
        var rig = foldingRig()
        rig.now = .nan
        rig.evaluate()
        assertFailsOpen(&rig, .clockAnomaly)
    }

    func testFailOpenWhenTheClockGoesBackwards() {
        var rig = foldingRig()
        rig.now -= 5
        rig.lastReadingAt = rig.now
        rig.evaluate()
        assertFailsOpen(&rig, .clockAnomaly)
    }

    func testClockTroubleWhileDormantIsIgnored() {
        var policy = LidFoldPolicy()
        var i = Policy.Input(now: .nan, angle: 90, lastReadingAt: 1)
        i.phase = .moving
        XCTAssertEqual(policy.evaluate(i), .idle)
        i.now = 10; i.lastReadingAt = 10
        XCTAssertTrue(policy.evaluate(i).wantCapture)
        _ = policy.failOpen(.stopped)
        i.now = 5; i.lastReadingAt = 5
        XCTAssertEqual(policy.evaluate(i), .idle, "backwards while dormant: nothing to hide, nothing to start")
    }

    func testFailureReasonsCarryAMessageAndRoutineOnesDoNot() {
        XCTAssertNotNil(Reason.captureFailed("x").failureMessage)
        XCTAssertNotNil(Reason.captureUnavailable.failureMessage)
        XCTAssertNotNil(Reason.noFrame.failureMessage)
        XCTAssertNotNil(Reason.rendererFailed("x").failureMessage)
        XCTAssertNotNil(Reason.watchdog.failureMessage)
        for routine: Reason in [.systemSleep, .screensAsleep, .sessionInactive, .spaceChanged, .screenParametersChanged,
                                .stopped, .sensorStale, .sensorUnavailable, .displayUnavailable, .captureDisabled] {
            XCTAssertNil(routine.failureMessage, "\(routine)")
        }
    }

    // MARK: - After a fail-open

    func testNoOverlayAfterFailOpenUntilTheLidMovesAnew() {
        var rig = foldingRig()
        rig.event(.spaceChanged)
        XCTAssertTrue(rig.policy.needsFreshMovement)
        // The lid keeps moving through the same gesture: nothing comes back.
        let continuing = rig.sweep(from: 80, to: 70, seconds: 0.5) + rig.sweep(from: 70, to: 60, seconds: 0.5)
        XCTAssertTrue(continuing.allSatisfy { $0 == .idle }, "same movement, still failed open")
        // It comes to rest...
        rig.rest(at: 60, seconds: 3)
        XCTAssertFalse(rig.policy.needsFreshMovement)
        XCTAssertTrue(rig.isResting)
        // ...and a new movement is a new session.
        let again = rig.sweep(from: 60, to: 50, seconds: 0.5)
        XCTAssertTrue(again.contains { $0.wantCapture && $0.wantPanel })
        XCTAssertNil(again.compactMap(\.failOpen).first)
    }

    func testNoOverlayAfterASensorFailureUntilItRecoversAndMoves() {
        var rig = foldingRig()
        rig.reading(nil)
        assertFailsOpen(&rig, .sensorUnavailable)
        rig.resetLid() // the sensor restarts
        rig.rest(at: 80, seconds: 2)
        XCTAssertTrue(rig.isResting)
        let again = rig.sweep(from: 80, to: 70, seconds: 0.5)
        XCTAssertTrue(again.contains { $0.wantCapture })
    }

    func testANilReadingWhileDormantIsHarmless() {
        var rig = Rig(angle: 80)
        XCTAssertEqual(rig.reading(nil), .idle)
        XCTAssertEqual(rig.reading(nil), .idle)
        XCTAssertTrue(rig.isResting)
    }

    func testNoBuiltInDisplayAtTheStartOfAMovementReportsOnceAndCapturesNothing() {
        var rig = Rig(angle: 130)
        rig.hasDisplay = false
        rig.rest(at: 130, seconds: 1)
        let decisions = rig.sweep(from: 130, to: 80, seconds: 1.5)
        XCTAssertEqual(decisions.compactMap(\.failOpen), [.displayUnavailable], "once per movement")
        XCTAssertTrue(decisions.allSatisfy { !$0.wantCapture && !$0.wantOverlay && !$0.wantPanel })
        // Back on the display, a new movement works.
        rig.hasDisplay = true
        rig.rest(at: 80, seconds: 3)
        XCTAssertTrue(rig.sweep(from: 80, to: 70, seconds: 0.5).contains { $0.wantCapture })
    }

    func testStopLeavesNoStateForARestart() {
        var rig = foldingRig()
        rig.event(.stopped)
        XCTAssertTrue(rig.isResting)
        // The controller builds a fresh policy on start(); a fresh one is dormant and quiet.
        XCTAssertEqual(LidFoldPolicy().stage, .dormant)
        XCTAssertFalse(LidFoldPolicy().needsFreshMovement)
    }

    func testEventsWhileDormantAnswerIdle() {
        var policy = LidFoldPolicy()
        for reason: Reason in [.spaceChanged, .screenParametersChanged, .captureFailed("late"), .stopped] {
            XCTAssertEqual(policy.failOpen(reason), .idle)
        }
        XCTAssertFalse(policy.needsFreshMovement, "nothing to latch without a session")
    }

    // MARK: - The test sweep

    func testATestSessionNeedsNoSensorNorMovement() {
        var rig = Rig() // no readings at all: a Mac without the sensor
        rig.demoAngle = 113
        let d = rig.evaluate()
        XCTAssertTrue(d.wantPanel); XCTAssertTrue(d.wantCapture); XCTAssertTrue(d.needsTicks)
        XCTAssertNil(d.failOpen)
        rig.demoAngle = 60
        rig.tick(0.3)
        rig.tick(0.3)
        XCTAssertTrue(rig.overlayVisible)
        for _ in 0..<40 { rig.demoAngle = 60; rig.tick(0.1) } // long silence from a sensor that does not exist
        XCTAssertNil(rig.history.compactMap(\.failOpen).first)
    }

    func testATestIgnoresStillnessAndEndsWhenTheTestEnds() {
        var rig = Rig()
        rig.demoAngle = 60
        for _ in 0..<12 { rig.tick(0.1) }
        rig.stillness = {
            var s = LidStillness()
            _ = s.observe(angle: 60, at: 0, delay: 2)
            _ = s.observe(angle: 60, at: 2.5, delay: 2)
            return s
        }()
        // (stillness is fed from `reading` in real use; the sweep must not depend on it)
        rig.demoAngle = 60
        XCTAssertTrue(rig.tick(0.1).wantOverlay)
        // The test is over: the fold clears and everything winds down, sensor or not.
        rig.demoAngle = nil
        var sawClear = false
        for _ in 0..<40 {
            let d = rig.tick(0.05)
            XCTAssertNil(d.failOpen, "ending a test on a Mac without a sensor is not a failure")
            if d.target.isClear && d.wantPanel { sawClear = true }
            if rig.isResting { break }
        }
        XCTAssertTrue(sawClear)
        XCTAssertTrue(rig.isResting)
    }

    func testATestIsCancelledByAnyFailOpen() {
        var rig = Rig()
        rig.demoAngle = 60
        for _ in 0..<5 { rig.tick(0.1) }
        rig.systemAwake = false
        let d = rig.tick(0.1)
        XCTAssertEqual(d.failOpen, .systemSleep)
        XCTAssertNil(rig.demoAngle, "the rig, like the controller, drops the test")
        XCTAssertTrue(rig.isResting)
    }

    func testATestWithoutABuiltInDisplayFailsAtOnce() {
        var rig = Rig()
        rig.hasDisplay = false
        rig.demoAngle = 100
        XCTAssertEqual(rig.evaluate().failOpen, .displayUnavailable)
        XCTAssertNil(rig.demoAngle)
    }

    func testATestStartsEvenRightAfterAFailOpen() {
        var rig = foldingRig()
        rig.event(.spaceChanged)
        XCTAssertTrue(rig.policy.needsFreshMovement)
        rig.demoAngle = 100
        XCTAssertTrue(rig.evaluate().wantCapture, "asking for a test is a deliberate new start")
    }

    func testATestInFadeModeNeverCaptures() {
        var rig = Rig()
        rig.captureWanted = false
        rig.demoAngle = 70
        for _ in 0..<10 { rig.tick(0.1) }
        XCTAssertTrue(rig.overlayVisible)
        XCTAssertTrue(rig.history.allSatisfy { !$0.wantCapture })
    }

    func testATestTakesOverARunningLidSession() {
        var rig = foldingRig()
        rig.demoAngle = 60
        for _ in 0..<5 { rig.tick(0.1) } // longer than the sensor timeout, yet fine: the test drives
        rig.demoAngle = nil
        XCTAssertNil(rig.history.compactMap(\.failOpen).first)
    }
}
