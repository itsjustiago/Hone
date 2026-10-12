import CoreGraphics
import Foundation

/// What the controller needs from a screen capture. `DesktopCapture` is the real
/// one; tests use a fake, so no ScreenCaptureKit stream (and no recording
/// indicator) is ever involved.
@MainActor
protocol CaptureControlling: AnyObject {
    var frames: FrameStore { get }
    var isRunning: Bool { get }
    var onFailure: ((String) -> Void)? { get set }
    var onUnavailable: (() -> Void)? { get set }
    var onFirstFrame: (() -> Void)? { get set }
    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws
    func stop()
    func invalidateDisplayCache()
}

extension DesktopCapture: CaptureControlling {}

/// Carries out "capture on / capture off" for the controller, and owns the rule
/// that a session gets ONE start attempt: a failed start ends the session instead
/// of being retried on every sensor report.
///
/// That latch lives here, behind a single `stop()`, so it cannot be left set. It
/// once was a flag the controller reset only on fail-open: the normal end of a
/// fold stopped the stream without resetting it, and the next fold never asked
/// for a capture (so the effect worked on every other fold only).
@MainActor
final class CaptureSession {
    struct Request {
        let displayID: CGDirectDisplayID
        let width: Int
        let height: Int
        let fps: Int
    }

    private let capture: CaptureControlling
    /// A start was requested in this session and `stop()` has not run since.
    private(set) var requested = false
    /// Bumped by every `stop()`: a start still waiting for its turn after that
    /// belongs to a session that is gone and must not open a stream.
    private var epoch = 0

    init(_ capture: CaptureControlling) { self.capture = capture }

    /// Something of the capture still exists (or is on its way) and needs a `stop()`.
    var isActive: Bool { requested || capture.isRunning }

    /// Brings the capture in line with what the policy wants. `isCurrent` says
    /// whether the session that asked is still the live one when the async start
    /// gets to run; `onError` receives a failed start.
    @discardableResult
    func reconcile(wantCapture: Bool, request: Request?,
                   isCurrent: @escaping @MainActor () -> Bool,
                   onError: @escaping @MainActor (Error) -> Void) -> Task<Void, Never>? {
        guard wantCapture else {
            if isActive { stop() }
            return nil
        }
        guard let request, !requested, !capture.isRunning else { return nil }
        requested = true
        let startedIn = epoch
        return Task { [capture, weak self] in
            guard let self, self.epoch == startedIn, isCurrent() else { return }
            do {
                try await capture.start(displayID: request.displayID, width: request.width,
                                        height: request.height, fps: request.fps)
            } catch {
                onError(error)
            }
        }
    }

    /// The only way the capture stops: it also re-arms the next session's attempt.
    func stop() {
        capture.stop()
        requested = false
        epoch &+= 1
    }
}
