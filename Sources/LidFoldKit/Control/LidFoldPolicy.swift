import Foundation

/// Every decision of the fold effect, as a pure state machine: no AppKit, no clock
/// of its own, no I/O. The controller only feeds it what it observed (`Input`) and
/// carries out what it answers (`Decision`), which keeps the rules that decide
/// when the screen is captured and covered testable without a screen.
///
/// The rule it exists to enforce: **a resting lid costs nothing.** Capture, panel
/// and fast timer exist only inside a session, and a session starts only when the
/// lid MOVES (`phase == .moving`) below `reference`, i.e. only when there is a
/// fold to show: closing it, or opening it back from below the reference. Waking
/// up, a lid adjusted above the reference, a closed-but-still lid or an old angle
/// never start one. (MacDuo captures whenever the angle is low, which keeps the
/// system's recording indicator lit.)
///
/// Failing open always wins: any doubt hides the overlay and stops the capture
/// at once, and the effect only returns on a NEW movement of the lid.
struct LidFoldPolicy {
    // MARK: - Tunables

    /// Longest silence from the sensor that still proves the angle is current.
    static let sensorTimeout: TimeInterval = 1
    /// With progress rising and no desktop frame for this long, give up the session.
    static let frameTimeout: TimeInterval = 1
    /// The capture outlives the end of a session by this long (as in MacDuo), so a
    /// lid that moves again right away finds it still warm.
    static let captureStopDelay: TimeInterval = 1.2
    /// Upper bound on the clearing animation before the overlay is hidden anyway.
    static let clearTimeout: TimeInterval = 1.5
    /// Longest the overlay may stay continuously visible. A real fold clears within
    /// seconds of the lid coming to rest, so this only ever catches a bug.
    static let watchdog: TimeInterval = 60
    /// Below this the fold is invisible; the overlay is not worth showing.
    static let minProgress = 0.0001

    // MARK: - Vocabulary

    enum Stage: Equatable {
        /// No session: nothing captured, no panel, no timer.
        case dormant
        /// The lid is moving (or a test runs): capture warm, overlay when ready.
        case folding
        /// The session is over: the fold animates away, then the capture stops.
        case clearing
    }

    enum FailOpenReason: Equatable {
        case sensorUnavailable
        case sensorStale
        case systemSleep
        case screensAsleep
        case sessionInactive
        case screenParametersChanged
        case spaceChanged
        case displayUnavailable
        case captureDisabled
        case captureUnavailable
        case captureFailed(String)
        case noFrame
        case rendererFailed(String)
        case watchdog
        case clockAnomaly
        case stopped

        /// What the user should hear about (shown as-is by the module, so PT-PT),
        /// or nil when the reason is routine.
        var failureMessage: String? {
            switch self {
            case .captureFailed(let reason): return "A captura do ecrã parou: \(reason)"
            case .captureUnavailable: return "O ecrã deixou de enviar imagens."
            case .noFrame: return "O ecrã não chegou a tempo."
            case .rendererFailed(let reason): return "A renderização falhou: \(reason)"
            case .watchdog: return "A sobreposição foi retirada por ficar tempo demais."
            default: return nil
            }
        }
    }

    /// Everything observed at one instant. The caller owns the clock.
    struct Input {
        var now: TimeInterval
        /// The angle that drives the visuals: the lid's, or the test sweep's.
        /// Nil means the sensor is absent or failing.
        var angle: Double?
        /// When `angle` was received.
        var lastReadingAt: TimeInterval?
        var phase: LidMotionDetector.Phase = .idle
        /// `LidStillness.isStill`, already fed with the same readings.
        var isStill = false
        /// `LidMotionReference.reference(clearAngle:)`, or the fixed one for a test.
        var reference = 105.0
        var sessionActive = true
        var systemAwake = true
        var displayAwake = true
        /// An active, unmirrored built-in display exists.
        var hasLiveBuiltInDisplay = true
        /// Capture mode (Duo) rather than the sourceless Fade.
        var captureWanted = true
        var demoRunning = false
        var hasFrame = false
        var overlayVisible = false
        var overlayVisibleSince: TimeInterval?
        /// The visual animation has fully returned to `.clear`.
        var visualIsClear = true

        init(now: TimeInterval, angle: Double? = nil, lastReadingAt: TimeInterval? = nil) {
            self.now = now; self.angle = angle; self.lastReadingAt = lastReadingAt
        }

        var sensorIsFresh: Bool {
            guard let at = lastReadingAt else { return false }
            let age = now - at
            return age >= 0 && age <= LidFoldPolicy.sensorTimeout
        }
    }

    /// What the world must look like now. The controller reconciles toward it.
    struct Decision: Equatable {
        /// Hide the overlay, stop the capture and close the panel NOW.
        var failOpen: FailOpenReason?
        var wantPanel = false
        var wantCapture = false
        var wantOverlay = false
        /// Where the visual animation should head (`.clear` unless folding).
        var target: FoldVisualState = .clear
        /// The fast timer is needed (deadlines, overlay upkeep).
        var needsTicks = false

        static let idle = Decision()
    }

    // MARK: - State

    private(set) var stage: Stage = .dormant
    /// Set by a fail-open; cleared only when the lid has been seen at rest, so the
    /// effect returns on a new movement and not in the middle of the old one.
    private(set) var needsFreshMovement = false
    private var sessionUsesCapture = false
    /// The session is driven by the synthetic test sweep, not by the lid, so the
    /// lid sensor's absence or silence says nothing about it. Sticks through the
    /// clearing that follows the test; a real movement hands the session back.
    private var sessionIsDemo = false
    private var clearingSince: TimeInterval = 0
    private var waitingForFrameSince: TimeInterval?
    private var lastNow: TimeInterval?

    init() {}

    // MARK: - Events

    /// An event that is not state in `Input` (a Space change, a capture failure,
    /// `stop()`…). With no session there is nothing to hide, so it answers `.idle`.
    mutating func failOpen(_ reason: FailOpenReason) -> Decision {
        guard stage != .dormant else { return .idle }
        return failOpenNow(reason)
    }

    // MARK: - Evaluation

    mutating func evaluate(_ input: Input) -> Decision {
        guard input.now.isFinite else { return failOpen(.clockAnomaly) }
        if let last = lastNow, input.now < last {
            lastNow = input.now
            return failOpen(.clockAnomaly)
        }
        lastNow = input.now

        // The lid has been seen at rest: a later movement is a new one.
        if input.phase == .idle { needsFreshMovement = false }

        if stage != .dormant, let reason = failOpenReason(input) { return failOpenNow(reason) }

        switch stage {
        case .dormant: return evaluateDormant(input)
        case .folding: return evaluateFolding(input)
        case .clearing: return evaluateClearing(input)
        }
    }

    // MARK: - Stages

    /// There is a fold to show only below the reference. Capture is asked for
    /// nothing else: opening or adjusting the lid above it never lights the
    /// system's recording indicator.
    static func hasFold(angle: Double, reference: Double) -> Bool {
        FoldVisualState.at(angle: angle, reference: reference).progress > 0
    }

    private mutating func evaluateDormant(_ i: Input) -> Decision {
        guard i.systemAwake, i.displayAwake, i.sessionActive else { return .idle }
        if !i.demoRunning {
            guard !needsFreshMovement, i.phase == .moving, !i.isStill, i.sensorIsFresh,
                  let angle = i.angle, angle.isFinite,
                  Self.hasFold(angle: angle, reference: i.reference) else { return .idle }
        }
        guard i.hasLiveBuiltInDisplay else {
            needsFreshMovement = true // report once per movement, not once per reading
            return Decision(failOpen: .displayUnavailable)
        }
        stage = .folding
        sessionUsesCapture = i.captureWanted
        sessionIsDemo = i.demoRunning
        waitingForFrameSince = nil
        return evaluateFolding(i)
    }

    private mutating func evaluateFolding(_ i: Input) -> Decision {
        if i.demoRunning { sessionIsDemo = true }
        // A finished test clears without the lid sensor: on a Mac without one the
        // angle is nil by then, and that must not count as a failure.
        if sessionIsDemo && !i.demoRunning { return beginClearing(i) }
        guard let angle = i.angle, angle.isFinite else { return failOpenNow(.sensorUnavailable) }
        let target = FoldVisualState.at(angle: angle, reference: i.reference)
        // The lid is at rest, or back above the reference: nothing left to show.
        if !sessionIsDemo && (i.isStill || target.progress <= 0) { return beginClearing(i) }

        let showing = target.progress > Self.minProgress
        if showing && sessionUsesCapture && !i.hasFrame {
            let since = waitingForFrameSince ?? i.now
            waitingForFrameSince = since
            if i.now - since >= Self.frameTimeout { return failOpenNow(.noFrame) }
        } else {
            waitingForFrameSince = nil
        }
        // Showing needs a desktop frame (or the Fade). Once up, the overlay stays
        // until its animation has handed the screen back, even if the lid opens.
        let ready = !sessionUsesCapture || i.hasFrame
        let wantOverlay = showing ? ready : (i.overlayVisible && !i.visualIsClear)
        return Decision(wantPanel: true, wantCapture: sessionUsesCapture, wantOverlay: wantOverlay,
                        target: target, needsTicks: true)
    }

    private mutating func beginClearing(_ i: Input) -> Decision {
        stage = .clearing
        clearingSince = i.now
        waitingForFrameSince = nil
        return evaluateClearing(i)
    }

    private mutating func evaluateClearing(_ i: Input) -> Decision {
        if resumes(i) {
            stage = .folding
            sessionIsDemo = i.demoRunning
            return evaluateFolding(i)
        }
        let elapsed = i.now - clearingSince
        let overlayDone = !i.overlayVisible || i.visualIsClear || elapsed >= Self.clearTimeout
        if overlayDone && elapsed >= Self.captureStopDelay {
            stage = .dormant
            return .idle
        }
        return Decision(wantPanel: true,
                        wantCapture: sessionUsesCapture,
                        wantOverlay: i.overlayVisible && !overlayDone,
                        target: .clear, needsTicks: true)
    }

    /// The lid moves again (or a test starts) before the capture has stopped.
    private func resumes(_ i: Input) -> Bool {
        if i.demoRunning { return true }
        guard i.phase == .moving, !i.isStill, let angle = i.angle, angle.isFinite else { return false }
        return Self.hasFold(angle: angle, reference: i.reference)
    }

    // MARK: - Fail-open

    private func failOpenReason(_ i: Input) -> FailOpenReason? {
        if !i.systemAwake { return .systemSleep }
        if !i.displayAwake { return .screensAsleep }
        if !i.sessionActive { return .sessionInactive }
        if !i.demoRunning && !sessionIsDemo {
            if i.angle == nil { return .sensorUnavailable }
            if !i.sensorIsFresh { return .sensorStale }
        }
        if !i.hasLiveBuiltInDisplay { return .displayUnavailable }
        // Capture switched off mid-session: stop being recorded right away.
        if sessionUsesCapture && !i.captureWanted { return .captureDisabled }
        if sessionUsesCapture && i.overlayVisible && !i.hasFrame { return .captureUnavailable }
        if let since = i.overlayVisibleSince, i.now - since >= Self.watchdog { return .watchdog }
        return nil
    }

    private mutating func failOpenNow(_ reason: FailOpenReason) -> Decision {
        stage = .dormant
        needsFreshMovement = true
        sessionUsesCapture = false
        sessionIsDemo = false
        waitingForFrameSince = nil
        return Decision(failOpen: reason)
    }
}
