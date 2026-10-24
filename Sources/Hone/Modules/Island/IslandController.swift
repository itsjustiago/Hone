import AppKit
import Observation

/// Runs the island while the tool is on: reads the music, feeds `IslandState`,
/// and shows what it decides in the panel over the notch. Off, nothing runs: no
/// adapter, no panel, no timer, no observer.
@MainActor
final class IslandController {
    private let settings: IslandSettings
    /// Starts nothing until `start()` (see `NowPlayingClient`); kept across
    /// restarts so Settings can always read its status.
    let client = NowPlayingClient()

    private var panel: IslandPanel?
    private var state = IslandState()
    private var geometry: NotchGeometry?
    private var isRunning = false
    /// Bumped by `start()` and `stop()`: an observation armed by an older run
    /// fires once more after it ends, and must not re-arm.
    private var generation = 0

    /// The one pending wake-up, at `state.nextChange(after:)`. None while idle.
    private var timer: Timer?
    /// Re-checks the pointer after a hover exit that the pointer never made.
    private var hoverCheck: Timer?
    /// Polls for an app in full screen while there is a track to show. See `startCoverPoll`.
    private var coverTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private var hasTrack = false
    /// An app in full screen covers the notch: the panel stays away until it ends.
    private var covered = false
    /// What the state was last told about the pointer.
    private var hovering = false
    /// The cover and app name are worked out once per track, not per render.
    private var artworkKey: (id: String, data: Data?)?
    private var appKey: String?

    init(settings: IslandSettings) {
        self.settings = settings
    }

    /// The Settings line about the music source.
    var sourceStatus: IslandSourceStatus {
        IslandSourceStatus(status: client.status, hasTrack: client.track != nil)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let mine = generation

        state = IslandState(openOnHover: settings.openOnHover, peekOnTrackChange: settings.peekOnTrackChange)
        panel = IslandPanel(actions: IslandActions(
            hover: { [weak self] inside in self?.hoverChanged(inside) },
            click: { [weak self] in self?.clicked() },
            send: { [weak self] command in self?.client.send(command) },
            openApp: { [weak self] in self?.openPlayer() }
        ))
        geometry = NotchGeometry.current()
        observeScreens()
        observeFullScreen()
        observeSettings(mine)
        client.start()
        observeTrack(mine)
    }

    /// Idempotent: safe to call when stopped or twice in a row.
    func stop() {
        isRunning = false
        generation += 1
        client.stop()
        timer?.invalidate()
        timer = nil
        hoverCheck?.invalidate()
        hoverCheck = nil
        stopCoverPoll()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        panel?.close()
        panel = nil
        geometry = nil
        hasTrack = false
        covered = false
        hovering = false
        artworkKey = nil
        appKey = nil
    }

    // MARK: Inputs

    private func observeTrack(_ mine: Int) {
        guard isRunning, mine == generation else { return }
        let track = withObservationTracking { client.track } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observeTrack(mine) } }
        }
        trackChanged(track)
    }

    private func observeSettings(_ mine: Int) {
        guard isRunning, mine == generation else { return }
        let (openOnHover, peek) = withObservationTracking {
            (settings.openOnHover, settings.peekOnTrackChange)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observeSettings(mine) } }
        }
        // The flags are plain fields of the state: changing them keeps the track.
        guard openOnHover != state.openOnHover || peek != state.peekOnTrackChange else { return }
        state.openOnHover = openOnHover
        state.peekOnTrackChange = peek
        apply()
    }

    private func observeScreens() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [(NotificationCenter, NSNotification.Name)] = [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
        ]
        for (center, name) in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            }
            observers.append((center, token))
        }
    }

    /// An app can go full screen on its own Space (the Space changes, or the app in
    /// front does) or with no sign at all, which the poll catches.
    private func observeFullScreen() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [(NSNotification.Name, Bool)] = [
            (NSWorkspace.activeSpaceDidChangeNotification, true),
            (NSWorkspace.didActivateApplicationNotification, false),
        ]
        for (name, spaceChanged) in names {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.frontChanged(spaceChanged: spaceChanged) }
            }
            observers.append((workspace, token))
        }
    }

    private func screensChanged() {
        guard isRunning else { return }
        geometry = NotchGeometry.current()
        updateCover()
        apply()
        confirmPointer()
    }

    private func frontChanged(spaceChanged: Bool) {
        // Without a track the panel is off the screen anyway: nothing to hide or show.
        guard isRunning, hasTrack else { return }
        refreshCover()
        // Back from a full-screen Space the window server hid the panel without telling
        // us, so what the state holds about the pointer may be stale.
        if spaceChanged { confirmPointer() }
        // The notification comes while the Space is still sliding: look again once it settles.
        coverTimer?.fireDate = Date().addingTimeInterval(0.7)
    }

    /// Looks at the screen again and, if the answer changed, shows or hides the panel.
    private func refreshCover() {
        guard isRunning, updateCover() else { return }
        apply()
        // The panel comes back under a pointer that may be resting on the notch.
        if !covered { confirmPointer() }
    }

    /// Whether an app in full screen covers the notch now. Returns whether that
    /// changed; the caller decides when to `apply()`.
    @discardableResult
    private func updateCover() -> Bool {
        let now = geometry.map { IslandFullScreen.current(on: $0) } ?? false
        guard now != covered else { return false }
        covered = now
        return true
    }

    /// A borderless window can go full screen with no Space change and no change of
    /// the app in front (a game when it finishes loading, a player's own full screen,
    /// Keynote), so nothing announces it: the screen is looked at every few seconds.
    /// Only while there is a track to show; without one the panel is away anyway.
    private func startCoverPoll() {
        guard coverTimer == nil else { return }
        let poll = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCover() }
        }
        poll.tolerance = 0.5
        RunLoop.main.add(poll, forMode: .common)
        coverTimer = poll
    }

    private func stopCoverPoll() {
        coverTimer?.invalidate()
        coverTimer = nil
    }

    /// Tells the state where the pointer really is, after the panel moved or came
    /// back: what it was told earlier may no longer be true.
    private func confirmPointer() {
        // No hover for an island that isn't there.
        guard isRunning, !covered, let geometry else { return }
        let now = Date()
        let frame = geometry.islandFrame(for: state.presentation(at: now))
        switch IslandHover.correction(hovering: hovering, hasTrack: hasTrack,
                                      pointerInside: IslandHover.pointerInside(NSEvent.mouseLocation, frame: frame)) {
        case .none:
            return
        case .enter:
            hovering = true
            state.handle(.hoverEntered, at: now)
        case .exit:
            hoverCheck?.invalidate()
            hoverCheck = nil
            hovering = false
            state.handle(.hoverExited, at: now)
        }
        apply()
    }

    private func trackChanged(_ track: NowPlayingTrack?) {
        let now = Date()
        let hadTrack = hasTrack
        if let track {
            state.handle(.track(id: track.id, isPlaying: track.isPlaying), at: now)
            hasTrack = true
            show(track)
        } else {
            state.handle(.trackCleared, at: now)
            hasTrack = false
            hovering = false
        }
        if hasTrack != hadTrack {
            if hasTrack {
                // Look before the first `apply()`: a track that starts while an app is in
                // full screen must not flash the island over it.
                updateCover()
                startCoverPoll()
            } else {
                stopCoverPoll()
            }
        }
        // A pointer already resting on the notch gets no new "entered" from AppKit.
        if let geometry, !covered, IslandHover.shouldReenter(
            hadTrack: hadTrack, hasTrack: hasTrack,
            pointerInside: IslandHover.pointerInside(
                NSEvent.mouseLocation, frame: geometry.islandFrame(for: state.presentation(at: now)))
        ) {
            hovering = true
            state.handle(.hoverEntered, at: now)
        }
        apply()
    }

    /// Fills the view's model, decoding the cover and naming the app only when
    /// they change.
    private func show(_ track: NowPlayingTrack) {
        guard let model = panel?.model else { return }
        if artworkKey?.id != track.id || artworkKey?.data != track.artwork {
            artworkKey = (track.id, track.artwork)
            model.artwork = IslandArtwork.make(from: track.artwork)
        }
        let app = "\(track.bundleID ?? "")|\(track.pid ?? 0)"
        if app != appKey {
            appKey = app
            model.appName = IslandPlayerApp.name(bundleID: track.bundleID, pid: track.pid)
        }
        model.track = track
    }

    private func hoverChanged(_ inside: Bool) {
        guard isRunning else { return }
        if inside {
            hoverCheck?.invalidate()
            hoverCheck = nil
            // Without a track the state ignores it; marking it here would swallow
            // the real "entered" once a track arrives.
            guard hasTrack, !hovering else { return }
            hovering = true
            state.handle(.hoverEntered, at: Date())
            apply()
        } else {
            guard hovering else { return }
            if panel?.containsMouse == true {
                // The content swapped under a pointer that never left: look again shortly.
                scheduleHoverCheck()
                return
            }
            hoverCheck?.invalidate()
            hoverCheck = nil
            hovering = false
            state.handle(.hoverExited, at: Date())
            apply()
        }
    }

    private func releaseHover() {
        hoverCheck?.invalidate()
        hoverCheck = nil
        guard IslandHover.correction(hovering: hovering, hasTrack: hasTrack, pointerInside: false) == .exit
        else { return }
        hovering = false
        state.handle(.hoverExited, at: Date())
    }

    private func scheduleHoverCheck() {
        hoverCheck?.invalidate()
        let check = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hoverChanged(false) }
        }
        RunLoop.main.add(check, forMode: .common)
        hoverCheck = check
    }

    private func clicked() {
        guard isRunning else { return }
        // A click proves the pointer is over the island, even if it never moved.
        if !hovering { hoverChanged(true) }
        state.handle(.clicked, at: Date())
        apply()
    }

    private func openPlayer() {
        guard let track = client.track else { return }
        IslandPlayerApp.activate(bundleID: track.bundleID, pid: track.pid)
    }

    // MARK: Output

    /// Shows what the state says now and sleeps until it may say something else.
    private func apply() {
        timer?.invalidate()
        timer = nil
        guard isRunning, let panel else { return }
        guard let geometry, !covered else {
            // No notch to draw on (another Mac, the lid closed, the screen off), or an app
            // in full screen covers it. The panel leaves, and the pointer can no longer be
            // over it: let go of the hover too, or the island would come back open and stuck.
            releaseHover()
            panel.hide()
            return
        }
        let now = Date()
        panel.show(state.presentation(at: now), on: geometry, keepsWindow: hasTrack)
        guard let next = state.nextChange(after: now) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        // Common modes: it must fire while a menu is open too.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// The app behind the music: its name for the player, and bringing it forward.
enum IslandPlayerApp {
    @MainActor
    static func name(bundleID: String?, pid: Int32?) -> String? {
        if let app = running(bundleID: bundleID, pid: pid), let name = app.localizedName { return name }
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    @MainActor
    static func activate(bundleID: String?, pid: Int32?) {
        if let app = running(bundleID: bundleID, pid: pid) {
            app.activate()
        } else if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// The process the user sees: the pid's app when it is a regular one (not a
    /// helper), else the first running app with the bundle id.
    @MainActor
    private static func running(bundleID: String?, pid: Int32?) -> NSRunningApplication? {
        let byPID = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        if let byPID, byPID.activationPolicy == .regular { return byPID }
        if let bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        return byPID
    }
}
