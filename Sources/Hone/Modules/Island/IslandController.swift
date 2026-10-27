import AppKit
import Observation

/// Runs the island while the tool is on: reads the music and Claude Code's
/// sessions, feeds `IslandState`, and shows what it decides in the panel over the
/// notch. Off, nothing runs: no adapter, no monitor, no panel, no timer, no observer.
@MainActor
final class IslandController {
    private let settings: IslandSettings
    /// Starts nothing until `start()` (see `NowPlayingClient`); kept across
    /// restarts so Settings can always read its status.
    let client = NowPlayingClient()
    /// Claude Code's sessions: on while the island runs and the setting is on.
    private let claudeMonitor = ClaudeActivityMonitor()

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
    /// Polls for an app in full screen while something can show on its own, or the
    /// island is covered. See `startCoverPoll`.
    private var coverTimer: Timer?
    /// One look at the screen once a Space has settled, when there is no poll to bring forward.
    private var settleCheck: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// What the island may show of the raw now-playing: music apps only.
    private var filter = IslandMusicFilter()
    /// The last raw now-playing, with its app resolved: what the filter runs on again
    /// when an app quits.
    private var lastRaw: NowPlayingTrack?
    /// Whether the filter holds music, observable for the Settings line.
    private let presence = MusicPresence()

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
        IslandSourceStatus(status: client.status, hasTrack: presence.hasMusic)
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
            send: { [weak self] command in self?.send(command) },
            openApp: { [weak self] in self?.openPlayer() },
            openClaudeSession: { [weak self] session in self?.openClaudeSession(session) },
            selectPage: { [weak self] page in self?.selectPage(page) }
        ))
        geometry = NotchGeometry.current()
        observeScreens()
        observeFullScreen()
        observeAppQuits()
        observeSettings(mine)
        client.start()
        observeTrack(mine)
        claudeMonitor.onNotices = { [weak self] notices in self?.claudeChanged(notices: notices) }
        updateClaudeMonitor()
        observeClaude(mine)
    }

    /// Idempotent: safe to call when stopped or twice in a row.
    func stop() {
        isRunning = false
        generation += 1
        client.stop()
        claudeMonitor.stop()
        claudeMonitor.onNotices = nil
        timer?.invalidate()
        timer = nil
        hoverCheck?.invalidate()
        hoverCheck = nil
        stopCoverPoll()
        settleCheck?.invalidate()
        settleCheck = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        panel?.close()
        panel = nil
        geometry = nil
        filter = IslandMusicFilter()
        lastRaw = nil
        presence.hasMusic = false
        covered = false
        hovering = false
        artworkKey = nil
        appKey = nil
    }

    // MARK: Inputs

    private func observeTrack(_ mine: Int) {
        guard isRunning, mine == generation else { return }
        let raw = withObservationTracking { client.track } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observeTrack(mine) } }
        }
        var track = raw
        // The adapter may know the pid but not the app.
        if let pid = track?.pid, track?.bundleID == nil {
            track?.bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        lastRaw = track
        filterChanged()
    }

    /// Runs the filter on the last raw now-playing. Only a change of what it shows
    /// reaches the state: a video that takes over now-playing never does.
    private func filterChanged() {
        let changed = filter.update(raw: lastRaw) { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
        }
        guard changed else { return }
        presence.hasMusic = filter.shown != nil
        trackChanged(filter.shown)
    }

    private func observeSettings(_ mine: Int) {
        guard isRunning, mine == generation else { return }
        let (openOnHover, peek, _) = withObservationTracking {
            (settings.openOnHover, settings.peekOnTrackChange, settings.showClaudeSessions)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observeSettings(mine) } }
        }
        // Off, the monitor stops and its snapshot goes to nil, which `observeClaude` hears.
        updateClaudeMonitor()
        // The flags are plain fields of the state: changing them keeps the track.
        guard openOnHover != state.openOnHover || peek != state.peekOnTrackChange else { return }
        state.openOnHover = openOnHover
        state.peekOnTrackChange = peek
        apply()
    }

    /// The monitor runs while the island does and the setting is on. Both calls are
    /// idempotent.
    private func updateClaudeMonitor() {
        if isRunning && settings.showClaudeSessions {
            claudeMonitor.start()
        } else {
            claudeMonitor.stop()
        }
    }

    private func observeClaude(_ mine: Int) {
        guard isRunning, mine == generation else { return }
        withObservationTracking { _ = claudeMonitor.snapshot } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observeClaude(mine) } }
        }
        claudeChanged(notices: [])
    }

    /// A new snapshot, with what it had to say. The monitor hands the notices over
    /// with `snapshot` already new, before the observation comes back: the summary
    /// goes to the state first, so a notice never shows on the old one, and the
    /// observation then finds nothing new.
    private func claudeChanged(notices: [ClaudeNotice]) {
        guard isRunning else { return }
        let snapshot = claudeMonitor.snapshot
        if let model = panel?.model, model.claude != snapshot { model.claude = snapshot }
        let summary = IslandClaude(snapshot)
        guard summary != state.claude || !notices.isEmpty else { return }
        let now = Date()
        if summary != state.claude {
            let hadContent = state.hasContent
            state.handle(.claude(summary), at: now)
            contentChanged(hadContent: hadContent, at: now)
        }
        if !notices.isEmpty { state.handle(.claudeNotices(notices), at: now) }
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

    /// A held track goes when its music app quits: the raw now-playing has no word
    /// about it while something else holds it.
    private func observeAppQuits() {
        let workspace = NSWorkspace.shared.notificationCenter
        let token = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.filter.shown != nil else { return }
                self.filterChanged()
            }
        }
        observers.append((workspace, token))
    }

    private func screensChanged() {
        guard isRunning else { return }
        geometry = NotchGeometry.current()
        updateCover()
        apply()
        confirmPointer()
    }

    private func frontChanged(spaceChanged: Bool) {
        // With nothing to show the panel is off the screen anyway: nothing to hide or show.
        guard isRunning, state.hasContent else { return }
        refreshCover()
        // Back from a full-screen Space the window server hid the panel without telling
        // us, so what the state holds about the pointer may be stale.
        if spaceChanged { confirmPointer() }
        lookAgainOnceSettled()
    }

    /// The notification comes while the Space is still sliding: look again once it settles.
    private func lookAgainOnceSettled() {
        let settled = Date().addingTimeInterval(0.7)
        if let coverTimer {
            coverTimer.fireDate = settled
            return
        }
        // No poll (only idle sessions listed): a single look, then the timer is gone.
        settleCheck?.invalidate()
        let check = Timer(fire: settled, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settleCheck = nil
                if self.isRunning, self.state.hasContent { self.refreshCover() }
            }
        }
        RunLoop.main.add(check, forMode: .common)
        settleCheck = check
    }

    /// Looks at the screen again and, if the answer changed, shows or hides the panel.
    private func refreshCover() {
        guard isRunning else { return }
        guard updateCover() else {
            // The window server can hide the panel on its own (native full screen) and
            // then sends no "exited": a hover held that long is checked against the pointer.
            if hovering { confirmPointer() }
            return
        }
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
        // Covered keeps the poll alive, and ends it when it lifts.
        updateCoverPoll(lookedJustNow: true)
        return true
    }

    /// Starts or stops the poll to match `IslandCoverPoll.isNeeded`. Called when the
    /// content changes and when `covered` does. Covered with nothing to show needs
    /// no poll: the panel is away anyway.
    private func updateCoverPoll(lookedJustNow: Bool = false) {
        if IslandCoverPoll.isNeeded(canShowOnItsOwn: state.canShowOnItsOwn, covered: covered && state.hasContent) {
            startCoverPoll()
            return
        }
        guard coverTimer != nil else { return }
        stopCoverPoll()
        // The poll goes quiet with sessions still listed: one last look, so `covered`
        // isn't left as it was up to 2 s ago. If the screen is covered, it starts again.
        if state.hasContent, !lookedJustNow { updateCover() }
    }

    /// A borderless window can go full screen with no Space change and no change of
    /// the app in front (a game when it finishes loading, a player's own full screen,
    /// Keynote), so nothing announces it: the screen is looked at every few seconds.
    /// Only while something can show on its own (a track, a session at work) or the
    /// island is covered; with only idle sessions listed it is hidden, and the hover
    /// looks for itself.
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
        let frame = geometry.islandFrame(for: state.layout(at: now))
        switch IslandHover.correction(hovering: hovering, hasContent: state.hasContent,
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
        let hadContent = state.hasContent
        if let track {
            state.handle(.track(id: track.id, isPlaying: track.isPlaying), at: now)
            show(track)
        } else {
            state.handle(.trackCleared, at: now)
        }
        contentChanged(hadContent: hadContent, at: now)
        apply()
    }

    /// After the track or the Claude sessions changed, keeps the rest in step with
    /// what the island has to show: the full-screen poll, and the pointer.
    private func contentChanged(hadContent: Bool, at now: Date) {
        let hasContent = state.hasContent
        if hasContent != hadContent {
            if hasContent {
                // Look before the first `apply()`: something that shows up while an app is
                // in full screen must not flash the island over it.
                updateCover()
            } else {
                // The state forgot the pointer with the last thing to show.
                hoverCheck?.invalidate()
                hoverCheck = nil
                hovering = false
            }
        }
        // Not only when `hasContent` flips: a session going from idle to working, or a
        // track going away with sessions listed, changes what the poll is for.
        updateCoverPoll()
        // A pointer already resting on the notch gets no new "entered" from AppKit.
        if let geometry, !covered, IslandHover.shouldReenter(
            hadContent: hadContent, hasContent: hasContent,
            pointerInside: IslandHover.pointerInside(
                NSEvent.mouseLocation, frame: geometry.islandFrame(for: state.layout(at: now)))
        ) {
            hovering = true
            state.handle(.hoverEntered, at: now)
        }
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
            // With nothing to show the state ignores it; marking it here would
            // swallow the real "entered" once something arrives.
            guard state.hasContent, !hovering else { return }
            // Without the poll (only idle sessions) nobody has looked at the screen:
            // look before the island opens over a full-screen app.
            if coverTimer == nil, updateCover() {
                apply()
                if covered { return }
            }
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
        guard IslandHover.correction(hovering: hovering, hasContent: state.hasContent, pointerInside: false) == .exit
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

    /// MediaRemote sends commands to whoever holds now-playing: with a video on top,
    /// they would pause the video, not the music.
    private func send(_ command: NowPlayingCommand) {
        guard filter.ownsNowPlaying else { return }
        client.send(command)
    }

    private func openPlayer() {
        guard let track = filter.shown else { return }
        IslandPlayerApp.activate(bundleID: track.bundleID, pid: track.pid)
    }

    private func selectPage(_ page: IslandPage) {
        guard isRunning else { return }
        state.handle(.pageSelected(page), at: Date())
        apply()
    }

    /// Opens the session in the Claude app, then folds the island: the user is off
    /// to the app. Without the app, it stays.
    private func openClaudeSession(_ session: ClaudeSession) {
        guard isRunning, IslandClaudeApp.open(session) else { return }
        state.handle(.dismissed, at: Date())
        apply()
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
        panel.show(state.layout(at: now), on: geometry, keepsWindow: state.hasContent)
        guard let next = state.nextChange(after: now) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        // Common modes: it must fire while a menu is open too.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// Whether the island holds music, as something the Settings line can observe.
@MainActor
@Observable
private final class MusicPresence {
    var hasMusic = false
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
