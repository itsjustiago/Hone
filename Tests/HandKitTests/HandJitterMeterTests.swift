import XCTest
@testable import HandKit

/// A fixed-seed Gaussian source (SplitMix64 + Box–Muller): no system randomness, same
/// numbers on every run.
private struct Gaussian {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    private mutating func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return (Double(z >> 11) + 0.5) / Double(1 << 53) // (0, 1)
    }

    mutating func next(sigma: Double) -> Double {
        let u1 = uniform(), u2 = uniform()
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

final class HandJitterMeterTests: XCTestCase {
    func testNoiseReadsAsItsRMSDistance() {
        // σ per axis → the RMS distance to the centre is σ·√2.
        let sigma = 0.003
        var rng = Gaussian(seed: 42)
        var meter = HandJitterMeter()
        var readings: [Double] = []
        for i in 0..<300 {
            let t = Double(i) / 30
            meter.add(t: t, point: HandPoint(x: 0.5 + rng.next(sigma: sigma), y: 0.4 + rng.next(sigma: sigma)))
            if i >= 40, let j = meter.jitter { readings.append(j) }
        }
        XCTAssertGreaterThan(readings.count, 200, "a resting hand should read almost always")
        let mean = readings.reduce(0, +) / Double(readings.count)
        XCTAssertEqual(mean, sigma * 2.0.squareRoot(), accuracy: sigma * 2.0.squareRoot() * 0.25)
    }

    func testMovingHandReadsNil() {
        var meter = HandJitterMeter()
        for i in 0..<60 {
            let t = Double(i) / 30
            meter.add(t: t, point: HandPoint(x: 0.3 + 0.2 * t, y: 0.4)) // 0.2 per second: span 0.2 ≫ 0.02
        }
        XCTAssertNil(meter.jitter)
    }

    func testTooFewSamplesReadNil() {
        var meter = HandJitterMeter()
        for i in 0..<9 { meter.add(t: Double(i) / 30, point: HandPoint(x: 0.5, y: 0.5)) }
        XCTAssertNil(meter.jitter)
        meter.add(t: 9.0 / 30, point: HandPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(meter.jitter ?? -1, 0, accuracy: 1e-12) // 10 identical samples: still, no shake
    }

    func testOldSamplesLeaveTheWindow() {
        var meter = HandJitterMeter()
        // A move, then a second of stillness: the move is out of the window and it reads again.
        for i in 0..<30 { meter.add(t: Double(i) / 30, point: HandPoint(x: 0.1 + Double(i) * 0.01, y: 0.5)) }
        XCTAssertNil(meter.jitter)
        for i in 30..<70 { meter.add(t: Double(i) / 30, point: HandPoint(x: 0.5, y: 0.5)) }
        XCTAssertNotNil(meter.jitter)
    }

    func testResetClearsTheWindow() {
        var meter = HandJitterMeter()
        for i in 0..<30 { meter.add(t: Double(i) / 30, point: HandPoint(x: 0.5, y: 0.5)) }
        XCTAssertNotNil(meter.jitter)
        meter.reset()
        XCTAssertNil(meter.jitter)
    }

    func testRestSpanIsConfigurable() {
        var strict = HandJitterMeter(restSpan: 0.005)
        var loose = HandJitterMeter(restSpan: 0.05)
        for i in 0..<30 {
            let p = HandPoint(x: 0.5 + (i.isMultiple(of: 2) ? 0.01 : -0.01), y: 0.5)
            strict.add(t: Double(i) / 30, point: p)
            loose.add(t: Double(i) / 30, point: p)
        }
        XCTAssertNil(strict.jitter)
        XCTAssertEqual(loose.jitter ?? -1, 0.01, accuracy: 1e-9)
    }
}
