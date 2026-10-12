import AppKit
import XCTest
@testable import LidFoldKit

/// The controller on a fake sensor and a fake capture: no HID device, no
/// ScreenCaptureKit stream, no panel ordered onto the screen.
@MainActor
final class LidFoldControllerLifecycleTests: XCTestCase {
    private let workspace = NSWorkspace.shared.notificationCenter

    private func makeStarted() throws -> (LidFoldController, FakeSensor, FakeCapture) {
        let sensor = FakeSensor(), capture = FakeCapture()
        let controller = LidFoldController(sensor: sensor, capture: capture)
        controller.start()
        try XCTSkipIf(controller.observerCount == 0, "no Metal device: start() does not listen")
        return (controller, sensor, capture)
    }

    /// Observers are delivered on the main queue, so give it a turn.
    private func post(_ name: Notification.Name, on center: NotificationCenter? = nil) {
        (center ?? workspace).post(name: name, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: - Dropping the controller (defect 3)

    func testDroppingAStartedControllerStopsTheSensorAndTheCapture() throws {
        let sensor = FakeSensor(), capture = FakeCapture()
        var controller: LidFoldController? = LidFoldController(sensor: sensor, capture: capture)
        controller?.start()
        try XCTSkipIf(controller?.observerCount == 0, "no Metal device: nothing was started")
        XCTAssertEqual(sensor.startCount, 1)
        XCTAssertEqual(sensor.stopCount, 0)

        controller = nil // the owner lets go without calling stop()

        XCTAssertEqual(sensor.stopCount, 1, "the sensor must not keep polling for nobody")
        XCTAssertEqual(capture.stopCount, 1, "nor the capture keep a stream open")
        XCTAssertFalse(capture.isRunning)
    }

    func testTeardownClosesThePanelAndStopsEverything() throws {
        guard let overlay = FoldOverlay.make(frame: NSRect(x: 0, y: 0, width: 200, height: 120)) else {
            throw XCTSkip("no Metal device")
        }
        let sensor = FakeSensor(), capture = FakeCapture()
        let session = CaptureSession(capture)
        Teardown(overlay: overlay, captureSession: session, sensor: sensor).run()
        XCTAssertNil(overlay.panel.contentView, "the panel is torn down")
        XCTAssertFalse(overlay.panel.isVisible)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(sensor.stopCount, 1)
    }

    func testTeardownFromAnotherThreadHopsToTheMainQueue() {
        let sensor = FakeSensor(), capture = FakeCapture()
        let teardown = Teardown(overlay: nil, captureSession: CaptureSession(capture), sensor: sensor)
        let done = expectation(description: "released on the main queue")
        DispatchQueue.global().async {
            teardown.run()
            DispatchQueue.main.async { done.fulfill() }
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(sensor.stopCount, 1)
    }

    // MARK: - Status after a forced clean (defect 6)

    func testSystemSleepEndsARunningTestInTheStatus() throws {
        let (controller, _, _) = try makeStarted()
        controller.beginDemoStatusForTesting()
        XCTAssertEqual(controller.status, .testing)
        post(NSWorkspace.willSleepNotification)
        XCTAssertNotEqual(controller.status, .testing, "a test that was cut short is no longer running")
        controller.stop()
    }

    func testAScreenChangeEndsARunningTestInTheStatus() throws {
        let (controller, _, _) = try makeStarted()
        controller.beginDemoStatusForTesting()
        XCTAssertEqual(controller.status, .testing)
        post(NSApplication.didChangeScreenParametersNotification, on: .default)
        XCTAssertNotEqual(controller.status, .testing)
        controller.stop()
    }

    // MARK: - One wake cycle restarts the sensor once (defect 7)

    func testAWakeRestartsTheSensorOnceHoweverManyNotificationsItBrings() throws {
        let (controller, sensor, _) = try makeStarted()
        XCTAssertEqual(sensor.startCount, 1)
        for cycle in 1...2 {
            post(NSWorkspace.willSleepNotification)
            post(NSWorkspace.screensDidSleepNotification)
            XCTAssertEqual(sensor.startCount, cycle, "asleep: no restart")
            post(NSWorkspace.didWakeNotification)
            post(NSWorkspace.screensDidWakeNotification)
            post(NSWorkspace.sessionDidBecomeActiveNotification)
            XCTAssertEqual(sensor.startCount, cycle + 1, "cycle \(cycle): one restart for three wake notifications")
        }
        controller.stop()
    }

    func testTheSensorWaitsForTheDisplayAndTheSessionBeforeItRestarts() throws {
        let (controller, sensor, _) = try makeStarted()
        post(NSWorkspace.willSleepNotification)
        post(NSWorkspace.screensDidSleepNotification)
        post(NSWorkspace.sessionDidResignActiveNotification)
        post(NSWorkspace.didWakeNotification)
        XCTAssertEqual(sensor.startCount, 1, "the display is still off and the session still locked")
        post(NSWorkspace.screensDidWakeNotification)
        XCTAssertEqual(sensor.startCount, 1, "still locked")
        post(NSWorkspace.sessionDidBecomeActiveNotification)
        XCTAssertEqual(sensor.startCount, 2)
        controller.stop()
    }

    func testAWakeWithoutASleepDoesNotRestartTheSensor() throws {
        let (controller, sensor, _) = try makeStarted()
        post(NSWorkspace.didWakeNotification)
        post(NSWorkspace.screensDidWakeNotification)
        XCTAssertEqual(sensor.startCount, 1, "nothing was stopped, so nothing needs restarting")
        controller.stop()
    }

    func testAfterStopAWakeStartsNothing() throws {
        let (controller, sensor, _) = try makeStarted()
        post(NSWorkspace.willSleepNotification)
        controller.stop()
        post(NSWorkspace.didWakeNotification)
        XCTAssertEqual(sensor.startCount, 1)
    }
}
