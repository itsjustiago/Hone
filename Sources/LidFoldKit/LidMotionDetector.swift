import Foundation

/// Tells "the lid is being moved" from "the lid is resting" so the sensor can poll
/// fast only while it matters. Pure: no I/O and no clock of its own; the caller
/// passes `now`, which keeps it deterministic to test.
///
/// The sensor reports whole degrees, so a slow close shows up as 1° steps. The
/// anchor therefore only advances on meaningful movement: a 1° wobble while
/// resting never starts a movement, while a slow close keeps accumulating
/// against the same anchor until it crosses the threshold.
///
/// The threshold is 3° because a resting lid can flip between THREE neighbouring
/// values (98, 99, 100, 99, 98…). With the anchor on one extreme the other is 2°
/// away, so a 2° threshold made the anchor leap from extreme to extreme on every
/// swing and the lid never settled. ±1° of wobble can never reach 3°.
public struct LidMotionDetector {
    public enum Phase: Equatable, Sendable { case idle, moving }

    /// Distance from the anchor that starts a movement (idle -> moving).
    public static let startDelta = 3.0
    /// Distance from the anchor that counts as "still changing" while moving.
    /// Same as `startDelta` on purpose: a smaller one would let the sensor's own
    /// wobble on a resting lid keep restarting the settle timer and pin polling at 60 Hz.
    public static let keepDelta = 3.0
    /// Time without a `keepDelta` change before the lid counts as resting again.
    public static let settleDelay: TimeInterval = 1.5
    /// Longest gap between two readings that still proves continuity.
    public static let maxGap: TimeInterval = 1

    public private(set) var phase: Phase = .idle
    private var anchor: Double?
    private var lastChangeAt: TimeInterval = 0
    private var lastReadingAt: TimeInterval?

    public init() {}

    public mutating func reset() { self = LidMotionDetector() }

    @discardableResult
    public mutating func observe(angle: Double?, at now: TimeInterval) -> Phase {
        guard let angle, angle.isFinite, (0...180).contains(angle), now.isFinite else {
            reset(); return .idle
        }
        if let previous = lastReadingAt, now < previous || now - previous > Self.maxGap {
            // Missing reports, sleep or a clock that went backwards are no evidence
            // of motion or of rest: start over from this reading.
            reset()
        }
        lastReadingAt = now

        guard let current = anchor else {
            anchor = angle; lastChangeAt = now
            return phase
        }
        let delta = abs(angle - current)
        switch phase {
        case .idle:
            if delta >= Self.startDelta {
                anchor = angle; lastChangeAt = now; phase = .moving
            }
        case .moving:
            if delta >= Self.keepDelta {
                anchor = angle; lastChangeAt = now
            } else if now - lastChangeAt >= Self.settleDelay {
                phase = .idle
            }
        }
        return phase
    }
}
