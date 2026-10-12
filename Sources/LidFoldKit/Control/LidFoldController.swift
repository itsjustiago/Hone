// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import AppKit
import IOKit.ps
import MetalKit
import OSLog

/// The "iPhone Duo" screen effect, as one object: it listens to the lid, and while
/// the lid MOVES it folds the built-in display (captured, or a plain black fade).
///
/// This class is glue. Every decision (when to capture, when to cover, when to
/// fail open) lives in `LidFoldPolicy`; here those decisions are carried out and
/// the world is fed back to it. Everything is torn down again once the lid rests:
/// a resting lid means no capture, no panel, no renderer and no fast timer. Only
/// the notification observers and the sensor's slow poll stay.
///
/// Never touches brightness, display sleep or power assertions: Sleepy owns those.
/// It registers no hot key and no event tap.
@MainActor
public final class LidFoldController {
    public enum Status: Equatable {
        /// `start()` has not been called, or `stop()` has.
        case stopped
        /// Listening. Does nothing visible until the lid moves.
        case running
        /// `playTest` is sweeping a synthetic angle.
        case testing
        /// No lid angle sensor on this Mac (or it stopped answering).
        case unsupported
        /// No Metal device.
        case noMetal
        /// No active, unmirrored built-in display (clamshell mode, mirroring…).
        case waitingForDisplay
        /// The last session ended on an error; the next movement tries again.
        case failed(String)
    }

    public private(set) var status = Status.stopped
    public var onStatusChange: ((Status) -> Void)?

    /// The fold style. Takes effect on the next drawn frame.
    public var effect = FoldEffect.fallback
    /// True: the Duo effect with the live desktop, when Screen Recording is
    /// allowed. False, or without permission: the black Fade, which captures
    /// nothing. Read at the start of each fold; switching it off mid-fold ends it.
    public var captureEnabled = true {
        didSet { if oldValue != captureEnabled { update() } }
    }

    public private(set) var overlayVisible = false
    public var onOverlayVisibilityChanged: ((Bool) -> Void)?

    // MARK: - Collaborators

    private var policy = LidFoldPolicy()
    private let sensor: LidSensing
    private let capture: CaptureControlling
    private let captureSession: CaptureSession
    private var overlay: FoldOverlay?
    private var timer: Timer?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private let journal = Logger(subsystem: "com.tiagof.hone", category: "lidfold")

    // MARK: - Fixed look (MacDuo's defaults; no settings yet)

    private static let clearAngle = 105.0
    private static let stillnessDelay: TimeInterval = 2
    private static let perspective: Float = 0.7
    // MacDuo's 0.65 smeared the whole screen as soon as the lid moved.
    private static let blur: Float = 0.12
    private static let shadow: Float = 0.65

    // MARK: - Observed world

    private var started = false
    private var phase = LidMotionDetector.Phase.idle
    private var lastAngle: Double?
    private var lastReadingAt: TimeInterval?
    private var stillness = LidStillness()
    private var motion = LidMotionReference()
    private var sessionActive = true
    private var systemAwake = true
    private var displayAwake = true
    /// The sensor was stopped for sleep and no wake notification has restarted it yet.
    private var sensorAsleep = false

    private struct LiveDisplay {
        let screen: NSScreen
        let id: CGDirectDisplayID
        let frame: NSRect
        let scale: CGFloat
        let maxFPS: Int
    }
    private var liveDisplay: LiveDisplay?
    private var displayCheckedAt: TimeInterval = -.infinity
    private var hasScreenAccess = false
    private var accessCheckedAt: TimeInterval = -.infinity

    // MARK: - Session upkeep

    private var animation = FoldVisualAnimation()
    private var target = FoldVisualState.clear
    private var visual = FoldVisualState.clear
    private var fadeMode = false
    private var reducedMotion = false
    private var overlayRevealed = false
    private var overlayVisibleSince: TimeInterval?
    /// Bumped whenever a session ends, so late async results are recognised as stale.
    private var generation: UInt64 = 0
    private var fps = 60
    private var powerCheckedAt: TimeInterval = -.infinity

    private var demoStart: TimeInterval?
    private var demoDuration: TimeInterval = 8

    private var noMetal = false
    private var sensorMissing = false
    private var waitingForDisplay = false
    private var failureMessage: String?

    // MARK: - Lifecycle

    public convenience init() {
        self.init(sensor: LidSensor(), capture: DesktopCapture())
    }

    /// The seam for tests: a fake sensor and a fake capture keep them off the
    /// HID device and ScreenCaptureKit.
    init(sensor: LidSensing, capture: CaptureControlling) {
        self.sensor = sensor
        self.capture = capture
        self.captureSession = CaptureSession(capture)
        sensor.onReading = { [weak self] angle in self?.handleReading(angle) }
        sensor.onPhase = { [weak self] phase in self?.handlePhase(phase) }
        capture.onFirstFrame = { [weak self] in self?.update() }
        capture.onUnavailable = { [weak self] in self?.report(.captureUnavailable) }
        capture.onFailure = { [weak self] reason in
            guard let self else { return }
            let token = self.generation
            // ScreenCaptureKit can report the failure before AppKit posts the
            // topology change that explains it; decide after that main-queue turn.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.started, token == self.generation else { return }
                self.refreshDisplay(force: true)
                self.report(self.liveDisplay == nil ? .displayUnavailable : .captureFailed(reason))
            }
        }
    }

    deinit {
        for observer in observers { observer.center.removeObserver(observer.token) }
        timer?.invalidate()
        // An owner that drops the controller without `stop()` must not leave the
        // panel on screen or the stream recording.
        Teardown(overlay: overlay, captureSession: captureSession, sensor: sensor).run()
    }

    public func start() {
        guard !started else { return }
        started = true
        policy = LidFoldPolicy()
        resetLidState()
        failureMessage = nil
        guard MTLCreateSystemDefaultDevice() != nil else {
            noMetal = true
            refreshStatus()
            return
        }
        noMetal = false
        sessionActive = true; systemAwake = true; displayAwake = true; sensorAsleep = false
        refreshDisplay(force: true)
        installObservers()
        sensor.start()
        refreshStatus()
    }

    /// Releases everything: sensor, capture, panel, renderer, observers, timers.
    /// Safe to call at any time, any number of times.
    public func stop() {
        if started { _ = policy.failOpen(.stopped) }
        started = false
        forceClean()
        sensor.stop()
        removeObservers()
        resetLidState()
        liveDisplay = nil
        sensorAsleep = false
        noMetal = false; sensorMissing = false; waitingForDisplay = false; failureMessage = nil
        refreshStatus()
    }

    /// Sweeps a synthetic lid angle through the real pipeline (panel, capture or
    /// Fade) so the effect can be seen without touching the lid. Needs no sensor.
    /// Cancels itself on any fail-open or `stop()`. Returns false when it could not
    /// begin (not started, no Metal, no usable built-in display).
    @discardableResult
    public func playTest(duration: TimeInterval = 8) -> Bool {
        guard started, !noMetal, duration.isFinite, duration > 0 else { return false }
        demoStart = ProcessInfo.processInfo.systemUptime
        demoDuration = duration
        failureMessage = nil
        refreshDisplay(force: true)
        refreshStatus()
        update()
        return demoStart != nil
    }

    // MARK: - Sensor

    private func handleReading(_ angle: Double?) {
        guard started else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastAngle = angle
        lastReadingAt = now
        if angle == nil { phase = .idle }
        let settled = stillness.observe(angle: angle, at: now, delay: Self.stillnessDelay)
        motion.observe(angle: angle, isStill: settled, clearWhenStill: true)
        if sensorMissing != (angle == nil) {
            sensorMissing = angle == nil
            refreshStatus()
        }
        update()
    }

    private func handlePhase(_ next: LidMotionDetector.Phase) {
        guard started else { return }
        phase = next
        update()
    }

    private func resetLidState() {
        phase = .idle
        lastAngle = nil
        lastReadingAt = nil
        stillness.reset()
        motion.reset()
    }

    // MARK: - The loop

    /// Feeds the policy what the world looks like now and carries out its answer.
    /// Called per sensor report, per capture event and (during a session only) per
    /// timer tick.
    private func update() {
        guard started, !noMetal else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let start = demoStart, now - start > demoDuration {
            demoStart = nil
            refreshStatus()
        }
        let demoRunning = demoStart != nil
        let busy = demoRunning || phase == .moving || policy.stage != .dormant
        if busy {
            refreshDisplay()
            refreshScreenAccess(now: now)
        }

        var input: LidFoldPolicy.Input
        if let start = demoStart {
            input = LidFoldPolicy.Input(now: now, angle: Self.demoAngle((now - start) / demoDuration), lastReadingAt: now)
            input.reference = Self.clearAngle
        } else {
            input = LidFoldPolicy.Input(now: now, angle: lastAngle, lastReadingAt: lastReadingAt)
            input.reference = motion.reference(clearAngle: Self.clearAngle)
        }
        input.phase = phase
        input.isStill = stillness.isStill
        input.sessionActive = sessionActive
        input.systemAwake = systemAwake
        input.displayAwake = displayAwake
        input.hasLiveBuiltInDisplay = liveDisplay != nil
        input.captureWanted = captureEnabled && hasScreenAccess
        input.demoRunning = demoRunning
        input.hasFrame = capture.frames.hasFrame
        input.overlayVisible = overlayVisible
        input.overlayVisibleSince = overlayVisibleSince
        input.visualIsClear = visual.isClear
        apply(policy.evaluate(input), now: now)
    }

    private func apply(_ decision: LidFoldPolicy.Decision, now: TimeInterval) {
        if let reason = decision.failOpen { failOpen(reason); return }
        // Resting lid: nothing exists, nothing to reconcile.
        if decision == .idle && overlay == nil && timer == nil && !overlayVisible && !captureSession.isActive { return }

        let token = generation
        target = decision.target
        if decision.wantPanel {
            guard ensureOverlay() else { report(.rendererFailed("Não foi possível criar a sobreposição.")); return }
        } else {
            releaseOverlay()
        }
        reconcileCapture(wanted: decision.wantCapture)
        if decision.wantOverlay { showOverlay(now: now) }
        else if overlayVisible { hideOverlay() }
        // The first draw can fail open on the spot and end the session: its timer
        // and frame rate are no longer ours to set.
        guard token == generation else { return }
        if decision.needsTicks { startTimer() } else { stopTimer() }
        refreshFrameRate(now: now)
    }

    // MARK: - Fail-open

    /// Something is wrong or uncertain: ask the policy, and if it had a session to
    /// end, clean up. Late events (a stream that fails after the session is over)
    /// find a dormant policy and change nothing.
    private func report(_ reason: LidFoldPolicy.FailOpenReason) {
        let decision = policy.failOpen(reason)
        if let reason = decision.failOpen { failOpen(reason) }
    }

    private func failOpen(_ reason: LidFoldPolicy.FailOpenReason) {
        journal.notice("Fail-open: \(String(describing: reason), privacy: .public)")
        // Before the clean-up, so the status it refreshes already carries the message.
        if let message = reason.failureMessage { failureMessage = message }
        forceClean()
    }

    /// Hides the overlay, stops the capture and releases the panel, the renderer,
    /// the timer and any test, whatever the policy believes.
    private func forceClean() {
        generation &+= 1
        demoStart = nil
        hideOverlay()
        captureSession.stop()
        releaseOverlay()
        stopTimer()
        target = .clear
        refreshStatus() // a test that was running no longer is
    }

    // MARK: - Overlay

    private func ensureOverlay() -> Bool {
        if overlay != nil { return true }
        guard let display = liveDisplay,
              let built = FoldOverlay.make(frame: display.frame, screen: display.screen) else { return false }
        fadeMode = !(captureEnabled && hasScreenAccess)
        reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        failureMessage = nil
        powerCheckedAt = -.infinity
        let renderer = built.renderer
        renderer.frames = capture.frames
        renderer.fadeWithoutCapture = fadeMode
        renderer.parameters = { [weak self] in
            guard let self else { return FoldUniforms() }
            return Self.uniforms(visual: self.target, effect: self.effect, reducedMotion: self.reducedMotion)
        }
        renderer.animatedState = { [weak self] in self?.animatedState() }
        renderer.onFailure = { [weak self] reason in self?.report(.rendererFailed(reason)) }
        renderer.onPresented = { [weak self] in self?.overlayPresented() }
        overlay = built
        refreshStatus()
        return true
    }

    private func releaseOverlay() {
        guard let built = overlay else { return }
        hideOverlay()
        built.tearDown()
        overlay = nil
    }

    /// Reveal once the first frame has actually been presented, then follow the
    /// animation. Later presentations must never undo the fade.
    private func overlayPresented() {
        guard started, overlayVisible, !overlayRevealed, let panel = overlay?.panel else { return }
        if !fadeMode && !capture.frames.hasFrame { return }
        overlayRevealed = true
        // The Fade carries its coverage in the pixels; with the desktop it is the window's alpha.
        panel.alphaValue = fadeMode ? 1 : CGFloat(animation.value.coverage)
    }

    private func animatedState() -> FoldVisualState {
        let state = animation.sample(target: overlayVisible ? target : .clear,
                                     at: ProcessInfo.processInfo.systemUptime)
        visual = state
        if overlayVisible, overlayRevealed, !fadeMode, let panel = overlay?.panel,
           panel.alphaValue != CGFloat(state.coverage) {
            panel.alphaValue = CGFloat(state.coverage)
        }
        return state
    }

    private func showOverlay(now: TimeInterval) {
        guard let overlay, !overlayVisible else { return }
        let token = generation
        overlay.renderer.resetProgress(to: 0)
        animation.reset(); visual = .clear
        overlay.panel.alphaValue = 0
        overlayRevealed = false
        overlayVisible = true
        overlayVisibleSince = now
        overlay.panel.orderFrontRegardless()
        // Let the view own and retire its drawable: one explicit draw, then the
        // display-paced loop.
        overlay.view.isPaused = true
        overlay.view.draw()
        // That draw can fail open on the spot (the renderer reports synchronously),
        // which already hid and tore down everything and told the owner so.
        guard token == generation, self.overlay != nil, overlayVisible else { return }
        overlay.view.isPaused = false
        onOverlayVisibilityChanged?(true)
    }

    private func hideOverlay() {
        let wasVisible = overlayVisible
        if let overlay {
            overlay.panel.orderOut(nil)
            overlay.panel.alphaValue = 0
            overlay.view.isPaused = true
            overlay.view.releaseDrawables()
            overlay.renderer.releaseTransientResources()
        }
        animation.reset(); visual = .clear
        overlayVisible = false
        overlayRevealed = false
        overlayVisibleSince = nil
        if wasVisible { onOverlayVisibilityChanged?(false) }
    }

    // MARK: - Capture

    private func reconcileCapture(wanted: Bool) {
        let request = liveDisplay.map {
            CaptureSession.Request(displayID: $0.id, width: Int($0.frame.width * $0.scale),
                                   height: Int($0.frame.height * $0.scale), fps: min(60, fps))
        }
        let token = generation
        captureSession.reconcile(wantCapture: wanted, request: request, isCurrent: { [weak self] in
            self?.generation == token
        }, onError: { [weak self] error in
            let reason = error.localizedDescription
            // A start can fail just before the topology change that explains it.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.started, token == self.generation else { return }
                self.refreshDisplay(force: true)
                self.report(self.liveDisplay == nil ? .displayUnavailable : .captureFailed(reason))
            }
        })
    }

    /// Core Graphics' preflight shows no dialog. Only asked while something is
    /// happening, and at most every couple of seconds.
    private func refreshScreenAccess(now: TimeInterval) {
        guard captureEnabled else { hasScreenAccess = false; return }
        guard now - accessCheckedAt >= 2 else { return }
        accessCheckedAt = now
        hasScreenAccess = CGPreflightScreenCaptureAccess()
    }

    // MARK: - Display

    private func refreshDisplay(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - displayCheckedAt >= 0.25 else { return }
        displayCheckedAt = now
        liveDisplay = Self.findLiveDisplay()
        let waiting = liveDisplay == nil
        if waitingForDisplay != waiting {
            waitingForDisplay = waiting
            refreshStatus()
        }
    }

    /// The built-in display, if it is active and not mirrored.
    private static func findLiveDisplay() -> LiveDisplay? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            guard CGDisplayIsBuiltin(id) != 0, CGDisplayIsActive(id) != 0 else { continue }
            guard CGDisplayIsInMirrorSet(id) == 0 else { return nil }
            return LiveDisplay(screen: screen, id: id, frame: screen.frame, scale: screen.backingScaleFactor,
                               maxFPS: screen.maximumFramesPerSecond)
        }
        return nil
    }

    /// Caps drawing by power state and heat, like MacDuo. Checked every 2 s at most.
    private func refreshFrameRate(now: TimeInterval) {
        guard let overlay, let display = liveDisplay else { return }
        if now - powerCheckedAt >= 2 {
            powerCheckedAt = now
            let info = ProcessInfo.processInfo
            fps = FoldFramePacing.rate(maximum: display.maxFPS, externalPower: Self.isOnExternalPower(),
                lowPower: info.isLowPowerModeEnabled,
                thermalPressure: info.thermalState == .serious || info.thermalState == .critical, moving: true)
        }
        let rate = demoStart != nil || !stillness.isStill ? fps : min(60, fps)
        if overlay.view.preferredFramesPerSecond != rate { overlay.view.preferredFramesPerSecond = rate }
    }

    private static func isOnExternalPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        return IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? == kIOPSACPowerValue
    }

    // MARK: - Timer

    /// Runs only while a session exists: it serves the deadlines (no frame, silent
    /// sensor, clearing, watchdog) that no sensor report would trigger.
    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - System events

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.report(.spaceChanged) }
        // Sleep, display sleep and lock: end everything and stop reading the lid.
        observe(workspace, NSWorkspace.willSleepNotification) { $0.goToSleep(system: false, display: nil, session: nil, .systemSleep) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.goToSleep(system: nil, display: false, session: nil, .screensAsleep) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.goToSleep(system: nil, display: nil, session: false, .sessionInactive) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.wake(system: true, display: nil, session: nil) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.wake(system: nil, display: true, session: nil) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.wake(system: nil, display: nil, session: true) }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.screenParametersChanged() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping (LidFoldController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
        observers.append((center, token))
    }

    private func removeObservers() {
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
    }

    private func goToSleep(system: Bool?, display: Bool?, session: Bool?, _ reason: LidFoldPolicy.FailOpenReason) {
        guard started else { return }
        if let system { systemAwake = system }
        if let display { displayAwake = display }
        if let session { sessionActive = session }
        report(reason)
        forceClean()
        resetLidState()
        sensor.stop()
        sensorAsleep = true
    }

    private func wake(system: Bool?, display: Bool?, session: Bool?) {
        guard started else { return }
        if let system { systemAwake = system }
        if let display { displayAwake = display }
        if let session { sessionActive = session }
        // A display wake must not reactivate another user's session.
        guard systemAwake, displayAwake, sessionActive else { return }
        refreshDisplay(force: true)
        // One sleep ends in up to three notifications (system wake, screens wake,
        // session active). Restarting the sensor on each would discard a movement
        // report already in flight, so only the first one does.
        guard sensorAsleep else { return }
        sensorAsleep = false
        resetLidState()
        sensor.start()
    }

    private func screenParametersChanged() {
        guard started else { return }
        capture.invalidateDisplayCache()
        refreshDisplay(force: true)
        report(.screenParametersChanged)
        forceClean()
    }

    // MARK: - Status

    private func refreshStatus() {
        let next: Status
        if !started { next = .stopped }
        else if noMetal { next = .noMetal }
        else if demoStart != nil { next = .testing }
        else if let failureMessage { next = .failed(failureMessage) }
        else if sensorMissing { next = .unsupported }
        else if waitingForDisplay { next = .waitingForDisplay }
        else { next = .running }
        guard next != status else { return }
        status = next
        onStatusChange?(next)
    }

    // MARK: - Pure helpers

    /// MacDuo's test sweep: from just above the clear angle down toward closed and back.
    static func demoAngle(_ t: Double) -> Double {
        clearAngle + 8 - sin(min(1, max(0, t)) * .pi) * (clearAngle - 12)
    }

    /// Reduce Motion swaps the effect for a plain fade of the desktop.
    static func uniforms(visual: FoldVisualState, effect: FoldEffect, reducedMotion: Bool) -> FoldUniforms {
        FoldUniforms(visual: visual, effect: effect, perspective: perspective, blur: blur, shadow: shadow,
                     reducedMotion: reducedMotion)
    }

    // MARK: - Test hooks

    /// True when nothing of a session exists: no panel, no capture, no timer.
    var isResting: Bool {
        overlay == nil && timer == nil && !overlayVisible && !captureSession.isActive && policy.stage == .dormant
    }
    var observerCount: Int { observers.count }
    /// Shows the "test running" status without a panel, a capture or a timer.
    func beginDemoStatusForTesting() {
        demoStart = ProcessInfo.processInfo.systemUptime
        refreshStatus()
    }
}

/// What must not outlive the controller: the panel on screen, the running stream
/// and the sensor. It holds those pieces and never the controller, so `deinit`
/// (which is not main-actor isolated) can hand it to the main queue.
struct Teardown: @unchecked Sendable { // crosses threads on purpose; only touched on the main queue
    let overlay: FoldOverlay?
    let captureSession: CaptureSession
    let sensor: LidSensing

    /// Right away when already on the main thread, otherwise on its next turn.
    func run() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { release() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { release() } }
        }
    }

    @MainActor
    private func release() {
        overlay?.tearDown()
        captureSession.stop()
        sensor.stop()
    }
}
