// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import Foundation

/// The angle a completed dwell left the lid at, used as the live reference for
/// the next movement. Without it, the first small move after the display clears
/// is measured from the user's saved "Clears at" setting, so a two-degree change
/// at 111 degrees would reapply the defocus of a 19-degree fold. Rebasing on the
/// resting angle keeps a small physical movement a small visual change while the
/// saved setting continues to act as the upper limit at which the desktop clears.
///
/// This helper stores no preferences and owns no dwell logic: the caller passes
/// the already validated stillness decision from `LidStillness`.
public struct LidMotionReference {
    /// The angle recorded by the most recent completed dwell, if any.
    public private(set) var restingAngle: Double?
    /// The previous stillness state, so only the edge into stillness re-anchors.
    private var wasStill = false

    public init() {}

    public mutating func reset() { self = LidMotionReference() }

    /// Records a new resting angle only on the transition into stillness. A held
    /// lid reporting one-degree jitter therefore never walks the anchor, and a
    /// later dwell at any angle replaces it in either direction.
    public mutating func observe(angle: Double?, isStill: Bool, clearWhenStill: Bool) {
        guard clearWhenStill, let angle, angle.isFinite, (0...180).contains(angle) else {
            reset(); return
        }
        if isStill && !wasStill { restingAngle = angle }
        wasStill = isStill
    }

    /// The angle the effect should start from: the resting angle when one exists,
    /// but never above the user's setting, which stays the clear limit. The floor
    /// keeps a reference usable when the lid came to rest already closed.
    public func reference(clearAngle: Double) -> Double {
        let setting = clearAngle.isFinite ? min(140, max(60, clearAngle)) : 105
        guard let resting = restingAngle, resting.isFinite else { return setting }
        return max(5, min(resting, setting))
    }
}
