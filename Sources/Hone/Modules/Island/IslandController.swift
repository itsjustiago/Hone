import AppKit
import Observation

/// Runs the island while the tool is on: reads the music and Claude Code's
/// sessions once for the app, and feeds `IslandStages`, which shows them on every
/// screen of the plan. Off, nothing runs: no adapter, no monitor, no panel, no timer,
/// no observer.
@MainActor
final class IslandController {
    private let settings: IslandSettings
    /// Starts nothing until `start()` (see `NowPlayingClient`); kept across
    /// restarts so Settings can always read its status.
    let client = NowPlayingClient()
    /// Claude Code's sessions: on while the island runs and the setting is on.
    private let claudeMonitor = ClaudeActivityMonitor()

    /// The islands, one per screen of the plan. There only while running.
    private var stages: IslandStages?
    /// The choice the islands were last laid out for.
    private var choice: IslandScreenChoice?
    private var isRunning = false
    /// Bumped by `start()` and `stop()`: an observation armed by an older run
    /// fires once more after it ends, and must not re-arm.
    private var generation = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// What the island may show of the raw now-playing: music apps only.
    private var filter = IslandMusicFilter()
    /// The last raw now-playing, with its app resolved: what the filter runs on again
    /// when an app quits.
    private var lastRaw: NowPlayingTrack?
    /// Whether the filter holds music, observable for the Settings line.
    private let presence = MusicPresence()

    /// The cover and app name are worked out once per track, not per render nor per screen.
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

        stages = IslandStages(
            openOnHover: settings.openOnHover, peekOnTrackChange: settings.peekOnTrackChange,
            commands: IslandStages.Commands(
                send: { [weak self] command in self?.send(command) },
                openPlayer: { [weak self] in self?.openPlayer() },
                openClaudeSession: { [weak self] session in self?.openClaudeSession(session) ?? false }))
        layOutScreens()
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
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        stages?.closeAll()
        stages = nil
        choice = nil
        filter = IslandMusicFilter()
        lastRaw = nil
        presence.hasMusic = false
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
    /// reaches the islands: a video that takes over now-playing never does.
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
        let (openOnHover, peek, _, screens) = withObservationTracking {
            (settings.openOnHover, settings.peekOnTrackChange, settings.showClaudeSessions, settings.screens)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.observeSettings(mine) } }
        }
        // Off, the monitor stops and its snapshot goes to nil, which `observeClaude` hears.
        updateClaudeMonitor()
        stages?.setOptions(openOnHover: openOnHover, peekOnTrackChange: peek)
        if screens != choice { layOutScreens() }
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
    /// with `snapshot` already new, before the observation comes back: the islands
    /// take the summary first, so a notice never shows on the old one, and the
    /// observation then finds nothing new.
    private func claudeChanged(notices: [ClaudeNotice]) {
        guard isRunning else { return }
        stages?.claudeChanged(claudeMonitor.snapshot, notices: notices)
    }

    /// Screens plugged in or out, the lid, a resolution, a wake: the islands are
    /// matched to the screens again.
    private func observeScreens() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [(NotificationCenter, NSNotification.Name)] = [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
        ]
        for (center, name) in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layOutScreens() }
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
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    self.stages?.frontChanged(spaceChanged: spaceChanged)
                }
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

    /// One island per screen of the plan for the screens connected now and the
    /// choice in Settings (with the lid closed the built-in screen is not there).
    private func layOutScreens() {
        guard isRunning, let stages else { return }
        choice = settings.screens
        stages.reconcile(to: IslandScreens.current(choice: settings.screens))
    }

    private func trackChanged(_ track: NowPlayingTrack?) {
        if let track { describe(track) }
        stages?.trackChanged(track)
    }

    /// Decodes the cover and names the app only when they change, once for every island.
    private func describe(_ track: NowPlayingTrack) {
        if artworkKey?.id != track.id || artworkKey?.data != track.artwork {
            artworkKey = (track.id, track.artwork)
            stages?.setArtwork(IslandArtwork.make(from: track.artwork))
        }
        let app = "\(track.bundleID ?? "")|\(track.pid ?? 0)"
        if app != appKey {
            appKey = app
            stages?.setAppName(IslandPlayerApp.name(bundleID: track.bundleID, pid: track.pid))
        }
    }

    // MARK: Commands

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

    /// Opens the session in the Claude app. The island it came from folds if it opened.
    private func openClaudeSession(_ session: ClaudeSession) -> Bool {
        guard isRunning else { return false }
        return IslandClaudeApp.open(session)
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
