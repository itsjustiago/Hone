import CoreGraphics
import Foundation
@testable import LidFoldKit

/// A lid sensor that never opens the HID device.
final class FakeSensor: LidSensing {
    var onReading: ((Double?) -> Void)?
    var onPhase: ((LidMotionDetector.Phase) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

/// A capture that never touches ScreenCaptureKit, so no stream and no recording
/// indicator are involved.
@MainActor
final class FakeCapture: CaptureControlling {
    struct Failure: Error {}

    let frames = FrameStore()
    var onFailure: ((String) -> Void)?
    var onUnavailable: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var running = false
    /// The next `start` throws this instead of running.
    var failNextStart: Error?

    var isRunning: Bool { running }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        startCount += 1
        if let error = failNextStart { failNextStart = nil; throw error }
        running = true
    }

    func stop() { stopCount += 1; running = false }
    func invalidateDisplayCache() {}
}

extension CaptureSession.Request {
    static let anyDisplay = CaptureSession.Request(displayID: 1, width: 100, height: 60, fps: 60)
}
