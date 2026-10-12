// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import Foundation

/// A configurable dwell with hysteresis for the sensor's integer-degree reports.
/// The anchor only advances on meaningful movement, so slow motion accumulates
/// instead of being mistaken for a series of stationary one-degree steps.
///
/// The anchor moves only for a reading 3° or more away (the same threshold as
/// `LidMotionDetector`): a resting lid can flip between three neighbouring values
/// (98, 99, 100, 99…), and with a 2° threshold the anchor would leap between the
/// extremes forever and the lid would never count as still.
public struct LidStillness {
    /// Distance from the anchor that restarts the dwell.
    public static let moveDelta = 3.0

    public private(set) var isStill = false
    private var anchor: Double?
    private var stationarySince: TimeInterval?
    private var lastReadingAt: TimeInterval?

    public init() {}

    public mutating func reset() { self = LidStillness() }

    @discardableResult
    public mutating func observe(angle: Double?, at now: TimeInterval, delay: TimeInterval = 2) -> Bool {
        guard let angle, angle.isFinite, (0...180).contains(angle), now.isFinite else {
            reset(); return false
        }
        if let previous = lastReadingAt, now < previous || now-previous > 1 {
            reset() // Missing reports or sleep are not evidence of a stationary lid.
        }
        lastReadingAt = now
        let interval = delay.isFinite ? min(5,max(1,delay)) : 2
        if anchor == nil || abs(angle-anchor!) >= Self.moveDelta {
            anchor = angle; stationarySince = now; isStill = false
        } else if let since = stationarySince, now-since >= interval {
            isStill = true
        }
        return isStill
    }
}
