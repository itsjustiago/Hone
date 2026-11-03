import Foundation

/// Hand landmarks per frame → mouse/keyboard actions. Port of `main()` in
/// handmouse.py (MisaelDdS/Gumball_Hand, MIT). Pure: no I/O, no clocks — the
/// caller passes the frame time.
///
/// STUB: the API is fixed; the body is being ported.
public final class HandMouseEngine {
    public var config: HandConfig
    public private(set) var status = HandStatus()
    /// How many screens the host has (for `nextScreen` wrap-around bookkeeping).
    public var screenCount: Int = 1

    public init(config: HandConfig = HandConfig()) {
        self.config = config
    }

    /// One camera frame. `hand` = nil when no hand is seen. `t` = monotonic seconds.
    public func process(t: TimeInterval, hand: HandLandmarks?) -> [HandAction] {
        []
    }

    /// Tracking is stopping: release a held button, close the picker. Leaves the
    /// engine ready to start fresh.
    public func reset() -> [HandAction] {
        []
    }
}

/// Calibrates the active area: point with the index only and sweep the zone;
/// an open hand held for 0.3 s with enough points finishes.
/// Port of `calibrate()` / `box_from()`.
public final class BoxCalibrator {
    public init() {}
    /// Index-tip samples collected so far.
    public private(set) var samples: [HandPoint] = []
    /// The box so far (nil until enough samples).
    public var currentBox: HandBox? { nil }
    /// Feed a frame. Returns the finished box once the open hand has been held,
    /// or nil while still collecting. A box smaller than 0.1 in either side is rejected
    /// (returns nil and keeps collecting).
    public func process(t: TimeInterval, hand: HandLandmarks?) -> HandBox? { nil }
    public func restart() { samples = [] }
}

/// Records the shortcut-mode hand pose: feed frames for ~5 s while the user holds
/// it, then `finish()`. Port of `capture_pose()`.
public final class CtrlPoseRecorder {
    public init() {}
    public private(set) var frameCount = 0
    public func add(_ hand: HandLandmarks) {}
    /// nil if fewer than 30 frames were seen.
    public func finish() -> CtrlPose? { nil }
}
