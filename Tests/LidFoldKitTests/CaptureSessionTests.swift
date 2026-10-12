import XCTest
@testable import LidFoldKit

/// The capture latch: a session gets one start attempt, and every way the capture
/// stops must re-arm the next session. Before `CaptureSession` the latch was a flag
/// the controller reset only on fail-open, so after a normal fold end the second
/// fold never asked for a capture (the effect worked on every other fold).
@MainActor
final class CaptureSessionTests: XCTestCase {
    private func want(_ on: Bool, _ session: CaptureSession,
                      onError: @escaping @MainActor (Error) -> Void = { _ in }) async {
        let task = session.reconcile(wantCapture: on, request: .anyDisplay, isCurrent: { true }, onError: onError)
        await task?.value
    }

    func testASecondFoldAsksForTheCaptureAgainAfterANormalEnd() async {
        let capture = FakeCapture()
        let session = CaptureSession(capture)
        await want(true, session)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertTrue(capture.isRunning)

        await want(false, session)   // the fold ends: the policy stops wanting it
        XCTAssertFalse(capture.isRunning)
        XCTAssertFalse(session.isActive)

        await want(true, session)    // the next fold
        XCTAssertEqual(capture.startCount, 2, "the second fold must capture too")
        XCTAssertTrue(capture.isRunning)
    }

    func testASessionGetsOneStartAttemptEvenWhenItFails() async {
        let capture = FakeCapture()
        capture.failNextStart = FakeCapture.Failure()
        let session = CaptureSession(capture)
        var errors = 0
        await want(true, session) { _ in errors += 1 }
        await want(true, session) { _ in errors += 1 }   // the next sensor reports
        await want(true, session) { _ in errors += 1 }
        XCTAssertEqual(capture.startCount, 1, "no retry on every report")
        XCTAssertEqual(errors, 1)
        XCTAssertTrue(session.isActive, "the failed attempt still has to be stopped")

        await want(false, session)
        XCTAssertFalse(session.isActive)
        await want(true, session)
        XCTAssertEqual(capture.startCount, 2, "a new session tries again")
    }

    func testAStartThatLosesTheRaceWithTheEndOfTheSessionNeverOpensAStream() async {
        let capture = FakeCapture()
        let session = CaptureSession(capture)
        let task = session.reconcile(wantCapture: true, request: .anyDisplay, isCurrent: { true }, onError: { _ in })
        session.reconcile(wantCapture: false, request: .anyDisplay, isCurrent: { true }, onError: { _ in })
        await task?.value
        XCTAssertEqual(capture.startCount, 0, "that session was over before its start got to run")
        XCTAssertFalse(capture.isRunning)
        await want(true, session)
        XCTAssertEqual(capture.startCount, 1)
    }

    func testAStaleSessionTokenSkipsTheStart() async {
        let capture = FakeCapture()
        let session = CaptureSession(capture)
        let task = session.reconcile(wantCapture: true, request: .anyDisplay, isCurrent: { false }, onError: { _ in })
        await task?.value
        XCTAssertEqual(capture.startCount, 0)
    }

    func testNoRequestMeansNoStart() async {
        let capture = FakeCapture()
        let session = CaptureSession(capture)
        let task = session.reconcile(wantCapture: true, request: nil, isCurrent: { true }, onError: { _ in })
        XCTAssertNil(task)
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(capture.startCount, 0)
    }

    func testNotWantingItWhileNothingIsActiveDoesNotTouchTheCapture() async {
        let capture = FakeCapture()
        let session = CaptureSession(capture)
        for _ in 0..<50 { await want(false, session) }
        XCTAssertEqual(capture.stopCount, 0, "a resting lid does no work")
    }

    func testAnExternalStopRearmsTheLatch() async {
        // fail-open and stop() end the capture through `stop()` directly.
        let capture = FakeCapture()
        let session = CaptureSession(capture)
        await want(true, session)
        session.stop()
        XCTAssertFalse(session.requested)
        await want(true, session)
        XCTAssertEqual(capture.startCount, 2)
    }
}
