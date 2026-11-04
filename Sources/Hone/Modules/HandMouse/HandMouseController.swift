import AppKit
import AVFoundation
import HandKit

/// Runs the hand mouse: camera → engine → Mac. Owns the tracker, the engine, the
/// performer and the HUD, and the two calibrations. The module only decides when the
/// shortcut exists; this decides what happens when it is pressed.
@MainActor
@Observable
final class HandMouseController {
    enum Calibration: Equatable {
        /// Sweep the index over the zone that should cover the screen.
        case area
        /// Hold the sideways hand that enters shortcut mode.
        case pose
    }

    /// The camera is running.
    private(set) var isTracking = false
    /// The camera is being asked for (first-time permission dialog).
    private(set) var isStarting = false
    private(set) var calibration: Calibration?
    /// Last failure worth showing in the Settings pane (PT-PT); cleared on the next start.
    private(set) var error: String?

    let settings: HandMouseSettings
    /// Diagnostic recording of the raw hand (Settings › Diagnóstico).
    let recorder = HandRecorder()
    /// Pipeline speed and tremor readouts (Settings › Diagnóstico).
    let quality = TrackingQuality()

    @ObservationIgnored private let tracker = HandTracker()
    @ObservationIgnored private let engine = HandMouseEngine()
    @ObservationIgnored private let performer = HandActionPerformer()
    @ObservationIgnored private let hud = HandMouseHUD()
    /// The whole hand drawn around the cursor (Settings › "Mostrar a mão no ecrã").
    @ObservationIgnored private let overlay = HandOverlay()

    /// Camera started only to calibrate: stops again when the calibration ends.
    @ObservationIgnored private var ownsCamera = false
    @ObservationIgnored private var pendingCalibration: Calibration?
    @ObservationIgnored private var appliedCameraID: String?
    @ObservationIgnored private var appliedEngine = HandTrackingEngine.mediapipe
    @ObservationIgnored private var didAlertDenied = false

    @ObservationIgnored private var lastHandSeen: TimeInterval?
    @ObservationIgnored private var actionStamp: TimeInterval = 0
    @ObservationIgnored private var lastActionLabel: String?
    @ObservationIgnored private var lastFollow: TimeInterval = 0

    @ObservationIgnored private var areaCalibrator: BoxCalibrator?
    @ObservationIgnored private var poseRecorder: CtrlPoseRecorder?
    @ObservationIgnored private var calibrationStart: TimeInterval?

    @ObservationIgnored private var messageToken = 0
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// A calibration gives up after this long without finishing.
    private static let areaTimeout: TimeInterval = 90
    private static let poseCountdown: TimeInterval = 3
    private static let poseDuration: TimeInterval = 5
    /// How long a gesture's name stays in the pill.
    private static let actionLife: TimeInterval = 1.5
    private static let messageLife: TimeInterval = 2.6

    init(settings: HandMouseSettings) {
        self.settings = settings
        settings.onChange = { [weak self] in self?.applySettings() }
        tracker.onFrame = { [weak self] t, hand in self?.handleFrame(t, hand) }
        tracker.onPreview = { [weak self] image in self?.hud.model.preview = image }
        tracker.onError = { [weak self] message in self?.trackerFailed(message) }
        tracker.onNotice = { [weak self] message in self?.fail(message) }
        hud.onEscape = { [weak self] in self?.cancelCalibration() }
        applySettings()
    }

    // MARK: Switching on and off

    /// The shortcut: on ↔ off. During a calibration it cancels it instead.
    func toggle() {
        if calibration != nil {
            cancelCalibration()
        } else if isTracking || isStarting {
            stopTracking()
        } else {
            startTracking()
        }
    }

    func startTracking() {
        guard !isTracking, !isStarting else { return }
        error = nil
        // Without Accessibility the events we post go nowhere.
        guard Permissions.shared.isAccessibilityTrusted else {
            Permissions.shared.requestAccessibility()
            fail("Precisa da permissão de Acessibilidade")
            return
        }
        switch HandTracker.authorization {
        case .authorized:
            begin()
        case .notDetermined:
            isStarting = true
            Task { @MainActor [weak self] in
                let granted = await HandTracker.requestAccess()
                guard let self, self.isStarting else { return }
                self.isStarting = false
                granted ? self.begin() : self.cameraDenied()
            }
        default:
            cameraDenied()
        }
    }

    /// Camera off, button released, picker closed. Safe to call when already off.
    func stopTracking() {
        isStarting = false
        pendingCalibration = nil
        endCalibration()
        guard isTracking else { refreshHUD(); return }
        isTracking = false
        ownsCamera = false
        recorder.stop() // keep what was recorded
        tracker.stop()
        quality.reset()
        performer.perform(engine.reset())
        performer.releaseAll()
        lastHandSeen = nil
        removeObservers()
        hud.model.landmarks = nil
        hud.model.status = HandStatus()
        hud.model.recentAction = nil
        overlay.hide()
        refreshHUD()
    }

    private func begin() {
        applySettings()
        screensChanged()
        _ = engine.reset()
        tracker.cameraID = settings.cameraID
        tracker.engine = settings.engine
        appliedCameraID = settings.cameraID
        appliedEngine = settings.engine
        tracker.wantsPreview = previewWanted
        quality.reset()
        tracker.start()
        isTracking = true
        lastHandSeen = nil
        lastActionLabel = nil
        observeSystem()
        if let pending = pendingCalibration {
            pendingCalibration = nil
            ownsCamera = true
            startCalibration(pending)
        }
        refreshHUD()
    }

    /// The screens as macOS arranges them (full frames, global CG points); the box maps
    /// the built-in display, where the camera is, else the primary.
    private func screensChanged() {
        let screens = NSScreen.screens
        let frames = HandActionPerformer.screenFrames(screens)
        let home = screens.firstIndex { $0.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false } ?? 0
        engine.desktop = HandDesktop(
            screens: frames.map { HandRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) },
            home: home)
    }

    private func cameraDenied() {
        let text = "Sem acesso à câmara. Ativa-o em Definições do Sistema › Privacidade e segurança › Câmara."
        fail(text)
        guard !didAlertDenied else { return }
        didAlertDenied = true
        let alert = NSAlert()
        alert.messageText = "O Rato de Mão precisa da câmara"
        alert.informativeText = "Ativa o Hone em Definições do Sistema › Privacidade e segurança › Câmara."
        alert.addButton(withTitle: "Abrir Definições")
        alert.addButton(withTitle: "Agora não")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    private func trackerFailed(_ message: String) {
        stopTracking()
        fail(message)
    }

    /// A problem the user should see: in the pane and for a moment on screen.
    private func fail(_ text: String) {
        error = text
        flash(text, isError: true)
    }

    // MARK: Calibration

    /// Point with the index only and sweep the zone that should cover the screen; an
    /// open hand finishes. Starts the camera itself when it is off.
    func calibrateArea() { requestCalibration(.area) }

    /// Hold the sideways hand that enters shortcut mode for a few seconds.
    func recordShortcutPose() { requestCalibration(.pose) }

    /// Drops the recorded pose: shortcut mode then only comes on through the lock.
    func forgetShortcutPose() { settings.config.ctrlPose = nil }

    func cancelCalibration() {
        guard calibration != nil else { return }
        let owned = ownsCamera
        endCalibration()
        if owned { stopTracking() }
        flash("Calibração cancelada", isError: false)
    }

    private func requestCalibration(_ kind: Calibration) {
        guard calibration == nil else { return }
        if isTracking {
            startCalibration(kind)
            refreshHUD()
        } else {
            pendingCalibration = kind
            startTracking()
        }
    }

    private func startCalibration(_ kind: Calibration) {
        performer.perform(engine.reset()) // let go of a held button before the engine goes quiet
        performer.releaseAll()
        calibration = kind
        calibrationStart = nil
        switch kind {
        case .area:
            areaCalibrator = BoxCalibrator()
            hud.model.calibration = HandHUDCalibration(
                title: "Calibrar a área",
                detail: "Só o indicador esticado: percorre a zona que queres para o ecrã. Mão aberta termina · Esc cancela")
        case .pose:
            poseRecorder = CtrlPoseRecorder()
            hud.model.calibration = HandHUDCalibration(
                title: "Prepara a mão de atalhos",
                detail: "Mão de lado, como a vais usar · começa em \(Int(Self.poseCountdown))s · Esc cancela")
        }
        hud.listenForEscape(true)
        refreshHUD()
    }

    /// Drops the calibration state; leaves the camera as it is.
    private func endCalibration() {
        guard calibration != nil else { return }
        calibration = nil
        areaCalibrator = nil
        poseRecorder = nil
        calibrationStart = nil
        hud.listenForEscape(false)
        hud.model.calibration = nil
        refreshHUD()
    }

    private func finishCalibration(_ text: String, isError: Bool = false) {
        let owned = ownsCamera
        endCalibration()
        if owned { stopTracking() }
        flash(text, isError: isError)
    }

    private func calibrate(_ kind: Calibration, _ t: TimeInterval, _ hand: HandLandmarks?) {
        let start = calibrationStart ?? t
        calibrationStart = start
        let elapsed = t - start

        switch kind {
        case .area:
            guard let calibrator = areaCalibrator else { return }
            if elapsed > Self.areaTimeout {
                finishCalibration("Calibração cancelada: demorou demasiado", isError: true)
                return
            }
            if let box = calibrator.process(t: t, hand: hand) {
                settings.config.box = box
                finishCalibration("Área calibrada")
                return
            }
            let count = calibrator.samples.count
            hud.model.calibration = HandHUDCalibration(
                title: "Calibrar a área",
                detail: count == 0
                    ? "Só o indicador esticado: percorre a zona que queres para o ecrã · Esc cancela"
                    : "\(count) pontos · mão aberta termina · Esc cancela",
                progress: nil,
                samples: calibrator.samples,
                box: calibrator.currentBox)

        case .pose:
            guard let recorder = poseRecorder else { return }
            if elapsed < Self.poseCountdown {
                let left = Int((Self.poseCountdown - elapsed).rounded(.up))
                hud.model.calibration = HandHUDCalibration(
                    title: "Prepara a mão de atalhos",
                    detail: "Mão de lado, como a vais usar · começa em \(left)s · Esc cancela")
                return
            }
            let recording = elapsed - Self.poseCountdown
            if recording >= Self.poseDuration {
                if let pose = recorder.finish() {
                    settings.config.ctrlPose = pose
                    finishCalibration("Pose de atalhos guardada")
                } else {
                    finishCalibration("Não vi a mão que chegue. Tenta outra vez", isError: true)
                }
                return
            }
            if let hand { recorder.add(hand) }
            hud.model.calibration = HandHUDCalibration(
                title: "A gravar a pose",
                detail: hand == nil ? "Não vejo a mão" : "Mantém a mão assim · Esc cancela",
                progress: recording / Self.poseDuration)
        }
    }

    // MARK: Frames

    private func handleFrame(_ t: TimeInterval, _ hand: HandLandmarks?) {
        guard isTracking else { return }
        if hand != nil || lastHandSeen == nil { lastHandSeen = t }
        if recorder.isRecording { recorder.add(t: t, hand: hand) } // the raw hand, before the engine
        applyCameraAspect()

        if let kind = calibration {
            calibrate(kind, t, hand)
        } else {
            let actions = engine.process(t: t, hand: hand)
            performer.perform(actions)
            noteActions(actions, t)
            if autoOffExpired(t) { return }
        }
        updateQuality(t, hand)
        updateHUD(t, hand)
        if settings.showHandOverlay { overlay.update(hand: calibration == nil ? hand : nil, status: engine.status) }
    }

    /// The engine and the overlay measure in frame heights: they need the real frame shape
    /// (16:9 at 720p, 4:3 on a VGA-only camera), known once the first frame is in.
    private func applyCameraAspect() {
        let size = tracker.frameSize
        guard size.height > 0 else { return }
        let aspect = Double(size.width) / Double(size.height)
        if engine.cameraAspect != aspect {
            engine.cameraAspect = aspect
            overlay.cameraAspect = CGFloat(aspect)
        }
    }

    /// Feeds the diagnostics: the raw hand, and the cursor only while it follows the hand.
    private func updateQuality(_ t: TimeInterval, _ hand: HandLandmarks?) {
        var cursor: (x: Double, y: Double)?
        if calibration == nil {
            switch engine.status.mode {
            case .pointing, .slow: cursor = engine.status.cursor
            default: break
            }
        }
        quality.update(t: t, hand: hand, cursor: cursor, tracker: tracker)
    }

    /// The engine never clears its last action label, so the HUD gives it a short life.
    private func noteActions(_ actions: [HandAction], _ t: TimeInterval) {
        let label = engine.status.lastAction
        let acted = actions.contains { if case .moveCursor = $0 { return false } else { return true } }
        if acted || label != lastActionLabel { actionStamp = t }
        lastActionLabel = label
    }

    private func autoOffExpired(_ t: TimeInterval) -> Bool {
        let minutes = settings.autoOffMinutes
        guard minutes > 0, let seen = lastHandSeen, t - seen > Double(minutes) * 60 else { return false }
        stopTracking()
        flash("Desligado: sem mão há \(minutes) min", isError: false)
        return true
    }

    private func updateHUD(_ t: TimeInterval, _ hand: HandLandmarks?) {
        let model = hud.model
        if calibration == nil {
            if model.status != engine.status { model.status = engine.status }
            let recent = t - actionStamp < Self.actionLife ? engine.status.lastAction : nil
            if model.recentAction != recent { model.recentAction = recent }
        } else if model.status != HandStatus() {
            model.status = HandStatus()
            model.recentAction = nil
        }
        if model.showPreview { model.landmarks = hand }
        if t - lastFollow > 0.25 {
            lastFollow = t
            hud.followCursor()
        }
    }

    // MARK: Settings

    /// Pushes the live settings into a running session.
    private func applySettings() {
        engine.config = settings.config
        performer.dryRun = settings.watchOnly
        performer.glide = settings.glide
        hud.model.watchOnly = settings.watchOnly
        hud.model.box = settings.config.box
        overlay.style = settings.handStyle
        tracker.wantsPreview = previewWanted
        if isTracking, settings.cameraID != appliedCameraID || settings.engine != appliedEngine {
            // A different camera or engine: restart the capture, keep the session.
            appliedCameraID = settings.cameraID
            appliedEngine = settings.engine
            tracker.stop()
            tracker.cameraID = settings.cameraID
            tracker.engine = settings.engine
            tracker.start()
            quality.reset()
        }
        refreshHUD()
    }

    private var previewWanted: Bool {
        isTracking && (settings.showCameraPreview || calibration != nil)
    }

    // MARK: HUD

    private func refreshHUD() {
        let model = hud.model
        let busy = isTracking && (settings.showHUD || settings.showCameraPreview || calibration != nil)
        model.showPreview = previewWanted
        model.showPill = settings.showHUD || calibration != nil || model.message != nil
        tracker.wantsPreview = previewWanted
        if !previewWanted { model.preview = nil; model.landmarks = nil }
        if busy || model.message != nil {
            hud.show()
            hud.followCursor()
        } else {
            hud.hide()
        }
        if isTracking && settings.showHandOverlay { overlay.show() } else { overlay.hide() }
    }

    /// A line in the pill for a moment, whatever the mode.
    private func flash(_ text: String, isError: Bool) {
        messageToken += 1
        let token = messageToken
        hud.model.message = HandHUDMessage(text: text, isError: isError)
        refreshHUD()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.messageLife))
            guard let self, self.messageToken == token else { return }
            self.hud.model.message = nil
            self.refreshHUD()
        }
    }

    // MARK: System events

    /// The camera must not outlive the screen it was meant for; screen changes keep the
    /// engine's screens right.
    private func observeSystem() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let sleeps: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (distributed, Notification.Name("com.apple.screenIsLocked")),
        ]
        for (center, name) in sleeps {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopTracking() }
            }
            observers.append((center, token))
        }
        // Screens plugged in, out or rearranged while running.
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        observers.append((NotificationCenter.default, screens))
    }

    private func removeObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }
}
