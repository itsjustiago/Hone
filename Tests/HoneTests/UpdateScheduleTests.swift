import XCTest
@testable import Hone

final class UpdateScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testFirstCheckIsAlwaysDue() {
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: nil, now: now))
    }

    func testCheckWithinTheGapIsSkipped() {
        let recent = now.addingTimeInterval(-(UpdateSchedule.minimumGap - 1))
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: recent, now: now))
    }

    func testCheckAfterTheGapIsDue() {
        let old = now.addingTimeInterval(-UpdateSchedule.minimumGap)
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: old, now: now))
    }

    func testPeriodicTimerIsNotThrottledAway() {
        // The timer fires every `period`; the gap must never swallow those ticks.
        XCTAssertGreaterThan(UpdateSchedule.period, UpdateSchedule.minimumGap)
    }
}
