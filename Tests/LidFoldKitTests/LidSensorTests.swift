import XCTest
@testable import LidFoldKit

/// No test here needs the sensor: they run the same on a Mac without one.
final class LidSensorTests: XCTestCase {
    // MARK: - Fail-open bookkeeping

    func testHealthReportsNothingForShortFailureStreaks() {
        var health = LidReadHealth()
        XCTAssertFalse(health.recordFailure(at: 0))
        XCTAssertFalse(health.recordFailure(at: 0.5))
        XCTAssertFalse(health.recordFailure(at: 0.99))
    }

    func testHealthFailsOpenOnceAfterOneContinuousSecond() {
        var health = LidReadHealth()
        XCTAssertFalse(health.recordFailure(at: 10))
        XCTAssertTrue(health.recordFailure(at: 11))
        XCTAssertFalse(health.recordFailure(at: 11.1), "reported only once per streak")
        XCTAssertFalse(health.recordFailure(at: 60))
    }

    func testHealthIsTimeBasedNotCountBased() {
        // Same wall-clock span at 8 Hz and at 60 Hz gives the same answer.
        for rate in [8.0, 60.0] {
            var health = LidReadHealth()
            var reports = 0
            for tick in 0...Int(rate * 3) where health.recordFailure(at: Double(tick) / rate) { reports += 1 }
            XCTAssertEqual(reports, 1, "rate \(rate)")
        }
    }

    func testHealthRecoversAndCanFailOpenAgain() {
        var health = LidReadHealth()
        _ = health.recordFailure(at: 0)
        XCTAssertTrue(health.recordFailure(at: 1))
        health.recordSuccess()
        XCTAssertFalse(health.recordFailure(at: 5))
        XCTAssertFalse(health.recordFailure(at: 5.9))
        XCTAssertTrue(health.recordFailure(at: 6))
    }

    func testASuccessInTheMiddleRestartsTheStreak() {
        var health = LidReadHealth()
        _ = health.recordFailure(at: 0)
        _ = health.recordFailure(at: 0.8)
        health.recordSuccess()
        XCTAssertFalse(health.recordFailure(at: 1.2))
        XCTAssertFalse(health.recordFailure(at: 2.1), "0.9 s since the new streak began")
    }

    // MARK: - Polling rates

    func testPollingRatesMatchTheAdaptiveContract() {
        XCTAssertEqual(LidSensor.idleRate, 8)
        XCTAssertEqual(LidSensor.movingRate, 60)
    }

    // MARK: - System probe and lifecycle (tolerate a missing sensor)

    func testIsSupportedDoesNotCrash() {
        _ = LidSensor.isSupported()
    }

    /// After `stop()` returns nothing else reaches the callbacks, even if a
    /// reading was already queued for the main thread.
    func testNoCallbacksAfterStop() {
        let sensor = LidSensor()
        var readings = 0
        var phases = 0
        sensor.onReading = { _ in readings += 1 }
        sensor.onPhase = { _ in phases += 1 }

        sensor.start()
        // Without a sensor `nil` arrives at once; with one, a reading does.
        let first = expectation(description: "first callback")
        sensor.onReading = { _ in readings += 1; first.fulfill() }
        wait(for: [first], timeout: 5)

        sensor.stop()
        let readingsAtStop = readings
        let phasesAtStop = phases
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(readings, readingsAtStop)
        XCTAssertEqual(phases, phasesAtStop)
    }

    func testStartStopStartAgainDoesNotLeakOrCrash() {
        let sensor = LidSensor()
        sensor.start()
        sensor.start()   // idempotent
        sensor.stop()
        sensor.start()
        sensor.stop()
        sensor.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func testDroppingARunningSensorStopsItsTimer() {
        weak var weakSensor: LidSensor?
        autoreleasepool {
            let sensor = LidSensor()
            weakSensor = sensor
            sensor.start()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(weakSensor, "the sensor must not keep itself alive")
    }
}
