import XCTest
@testable import LidFoldKit

/// Lifecycle only. `playTest` is never called here: it would put a panel on the
/// real screen, and the sensor is stopped before any run loop turn can start a
/// session of its own.
@MainActor
final class LidFoldControllerTests: XCTestCase {
    func testInitIsStoppedAndAtRest() {
        let controller = LidFoldController()
        XCTAssertEqual(controller.status, .stopped)
        XCTAssertFalse(controller.overlayVisible)
        XCTAssertTrue(controller.isResting)
        XCTAssertEqual(controller.observerCount, 0, "nothing listens before start()")
        XCTAssertTrue(controller.captureEnabled)
    }

    func testStopOnANeverStartedControllerIsHarmless() {
        let controller = LidFoldController()
        controller.stop()
        controller.stop()
        XCTAssertEqual(controller.status, .stopped)
        XCTAssertTrue(controller.isResting)
    }

    func testStartStopStopLeavesEverythingClean() {
        let controller = LidFoldController()
        var statuses: [LidFoldController.Status] = []
        controller.onStatusChange = { statuses.append($0) }

        controller.start()
        XCTAssertNotEqual(controller.status, .stopped, "start() must be visible in the status")
        XCTAssertTrue(controller.isResting, "a started but unmoved lid has no panel, capture or timer")
        XCTAssertFalse(controller.overlayVisible)

        controller.stop()
        controller.stop()
        XCTAssertEqual(controller.status, .stopped)
        XCTAssertTrue(controller.isResting)
        XCTAssertEqual(controller.observerCount, 0, "every observer is removed")
        XCTAssertFalse(controller.overlayVisible)
        XCTAssertEqual(statuses.last, .stopped)

        // Late callbacks (sensor, capture, timers) must find nothing to act on.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(controller.status, .stopped)
        XCTAssertTrue(controller.isResting)
        XCTAssertEqual(controller.observerCount, 0)
    }

    func testStartingTwiceDoesNotDoubleTheObservers() {
        let controller = LidFoldController()
        controller.start()
        let observers = controller.observerCount
        controller.start()
        XCTAssertEqual(controller.observerCount, observers)
        controller.stop()
        XCTAssertEqual(controller.observerCount, 0)
    }

    func testCanBeRestartedAfterStop() {
        let controller = LidFoldController()
        for _ in 0..<3 {
            controller.start()
            controller.stop()
            XCTAssertEqual(controller.status, .stopped)
            XCTAssertTrue(controller.isResting)
            XCTAssertEqual(controller.observerCount, 0)
        }
    }

    func testStoppedControllerDoesNotLeak() {
        weak var weakController: LidFoldController?
        autoreleasepool {
            let controller = LidFoldController()
            weakController = controller
            controller.start()
            controller.stop()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(weakController, "no retain cycle through the sensor, capture or observers")
    }

    func testTogglingCaptureWhileRestingChangesNothing() {
        let controller = LidFoldController()
        controller.start()
        controller.captureEnabled = false
        controller.captureEnabled = true
        controller.effect = .fallback
        XCTAssertTrue(controller.isResting)
        controller.stop()
        controller.captureEnabled = false // after stop: still nothing to do
        XCTAssertTrue(controller.isResting)
        XCTAssertEqual(controller.status, .stopped)
    }

    // MARK: - Pure helpers

    func testTestSweepStartsAndEndsJustAboveTheClearAngle() {
        let start = LidFoldController.demoAngle(0)
        let end = LidFoldController.demoAngle(1)
        let middle = LidFoldController.demoAngle(0.5)
        XCTAssertEqual(start, end, accuracy: 1e-9)
        XCTAssertGreaterThan(start, 105, "the sweep begins on a clear screen")
        XCTAssertLessThan(middle, 40, "and folds well past the effect")
        XCTAssertEqual(LidFoldController.demoAngle(-3), start, "clamped before the start")
        XCTAssertEqual(LidFoldController.demoAngle(4), end, accuracy: 1e-9, "clamped after the end")
        for step in 0...100 {
            XCTAssertTrue(LidFoldController.demoAngle(Double(step) / 100).isFinite)
        }
    }

    func testReducedMotionTurnsEveryEffectIntoAPlainFade() {
        let visual = FoldVisualState.at(angle: 70, reference: 105)
        for effect in FoldEffect.allCases {
            let plain = LidFoldController.uniforms(visual: visual, effect: effect, reducedMotion: false)
            let reduced = LidFoldController.uniforms(visual: visual, effect: effect, reducedMotion: true)
            XCTAssertEqual(plain.fadeOnly, 0, effect.title)
            XCTAssertEqual(reduced.fadeOnly, FoldUniforms.fadeDesktop, effect.title)
            XCTAssertEqual(reduced.progress, plain.progress, effect.title)
            XCTAssertEqual(plain.selectedEffect, effect)
        }
    }
}
