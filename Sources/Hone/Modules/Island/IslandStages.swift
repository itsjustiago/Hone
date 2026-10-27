import AppKit

/// The islands on the screens of the plan, one `IslandStage` each, and what they
/// share: what there is to show (`content`, which a new screen starts from), what
/// the views draw besides the layout (the track, the cover, the app's name, the
/// sessions), and one full-screen poll for all of them. `IslandController` feeds it
/// from the music and Claude Code's sessions, and takes the commands back.
@MainActor
final class IslandStages {
    /// The system around the islands: real panels, windows and pointer in the app,
    /// stand-ins in the tests.
    struct Environment {
        var makePanel: @MainActor (IslandActions) -> IslandStagePanel = { IslandPanel(actions: $0) }
        /// Whether an app in full screen covers the screen of each geometry, in order.
        var covers: @MainActor ([NotchGeometry]) -> [Bool] = { IslandFullScreen.current(on: $0) }
        var pointer: @MainActor () -> CGPoint = { NSEvent.mouseLocation }
    }

    /// What the views send back: to the one music source and the Claude app.
    struct Commands {
        var send: @MainActor (NowPlayingCommand) -> Void = { _ in }
        var openPlayer: @MainActor () -> Void = {}
        /// `false` without the app: the island then stays open.
        var openClaudeSession: @MainActor (ClaudeSession) -> Bool = { _ in false }
    }

    private let environment: Environment
    private let commands: Commands
    /// In the plan's order.
    private(set) var stages: [IslandStage] = []
    /// What there is to show, as every island has it: fed the track, the sessions and
    /// the settings, never the pointer. A new island starts from it.
    private(set) var content: IslandState

    private var track: NowPlayingTrack?
    private var artwork: IslandArtwork?
    private var appName: String?
    private var claude: ClaudeSnapshot?

    /// Polls for an app in full screen while something can show on its own, or some
    /// island is covered. One for every screen: each tick reads the window list once.
    /// See `startCoverPoll`.
    private var coverTimer: Timer?
    /// One look at the screens once a Space has settled, when there is no poll to bring forward.
    private var settleCheck: Timer?

    init(openOnHover: Bool, peekOnTrackChange: Bool,
         environment: Environment = Environment(), commands: Commands = Commands()) {
        content = IslandState(openOnHover: openOnHover, peekOnTrackChange: peekOnTrackChange)
        self.environment = environment
        self.commands = commands
    }

    var screens: [IslandScreen] { stages.map(\.screen) }

    func stage(on id: CGDirectDisplayID) -> IslandStage? {
        stages.first { $0.id == id }
    }

    /// Every island closed and every timer gone. Idempotent.
    func closeAll() {
        stopCoverPoll()
        settleCheck?.invalidate()
        settleCheck = nil
        stages.forEach { $0.close() }
        stages.removeAll()
    }

    // MARK: Screens

    /// Matches the islands to `plan` (see `IslandScreens.changes`): closes those whose
    /// screen left, moves those whose geometry changed, and brings up the new ones
    /// with what there is to show now, compact (showing up is no new track: no peek).
    /// Then, as after a wake, every island looks at its screen and the pointer again.
    func reconcile(to plan: [IslandScreen]) {
        let changes = IslandScreens.changes(from: screens, to: plan)
        for id in changes.removed { stage(on: id)?.close() }
        stages.removeAll { changes.removed.contains($0.id) }
        for screen in changes.moved { stage(on: screen.id)?.move(to: screen.geometry) }
        stages += changes.added.map(makeStage)
        let order = plan.map(\.id)
        stages.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }

        // With nothing to show the panels are away: no need to look.
        if content.hasContent { lookAtScreens() }
        stages.forEach { $0.apply() }
        stages.forEach { $0.confirmPointer() }
        updateCoverPoll(lookedJustNow: true)
    }

    private func makeStage(_ screen: IslandScreen) -> IslandStage {
        let covers = environment.covers
        let host = IslandStage.Host(
            isPolling: { [weak self] in self?.coverTimer != nil },
            covers: { geometry in covers([geometry]).first ?? false },
            coverChanged: { [weak self] in self?.updateCoverPoll(lookedJustNow: true) },
            pointer: environment.pointer,
            send: commands.send,
            openPlayer: commands.openPlayer,
            openClaudeSession: commands.openClaudeSession)
        let stage = IslandStage(screen: screen, state: IslandState(contentOf: content), host: host,
                                makePanel: environment.makePanel)
        let model = stage.panel.model
        model.track = track
        model.artwork = artwork
        model.appName = appName
        model.claude = claude
        return stage
    }

    // MARK: What there is to show

    /// The settings' flags: plain fields of every state, so changing them keeps the track.
    func setOptions(openOnHover: Bool, peekOnTrackChange: Bool) {
        guard openOnHover != content.openOnHover || peekOnTrackChange != content.peekOnTrackChange else { return }
        content.openOnHover = openOnHover
        content.peekOnTrackChange = peekOnTrackChange
        for stage in stages {
            stage.setOptions(openOnHover: openOnHover, peekOnTrackChange: peekOnTrackChange)
            stage.apply()
        }
    }

    /// The cover of the track, decoded once for every island.
    func setArtwork(_ artwork: IslandArtwork?) {
        self.artwork = artwork
        for stage in stages { stage.panel.model.artwork = artwork }
    }

    func setAppName(_ appName: String?) {
        self.appName = appName
        for stage in stages { stage.panel.model.appName = appName }
    }

    /// The music the islands may show, or `nil` once there is none.
    func trackChanged(_ track: NowPlayingTrack?) {
        guard let track else { return handle(.trackCleared) }
        self.track = track
        for stage in stages { stage.panel.model.track = track }
        handle(.track(id: track.id, isPlaying: track.isPlaying))
    }

    /// A new snapshot of the sessions, with what it had to say. The summary goes to
    /// the states first, so a notice never shows on the old one. Every island gets
    /// the notices, each on its own state.
    func claudeChanged(_ snapshot: ClaudeSnapshot?, notices: [ClaudeNotice]) {
        claude = snapshot
        for stage in stages where stage.panel.model.claude != snapshot { stage.panel.model.claude = snapshot }
        let summary = IslandClaude(snapshot)
        guard summary != content.claude || !notices.isEmpty else { return }
        let now = Date()
        if summary != content.claude { handle(.claude(summary), at: now, applying: false) }
        if !notices.isEmpty {
            for stage in stages { stage.handle(.claudeNotices(notices), at: now) }
        }
        stages.forEach { $0.apply() }
    }

    /// One change of what there is to show, on every island, then the rest in step
    /// with it: a look at the screens if something showed up, the poll, the pointer.
    private func handle(_ event: IslandEvent, at now: Date = Date(), applying: Bool = true) {
        let hadContent = content.hasContent
        content.handle(event, at: now)
        for stage in stages { stage.handle(event, at: now) }
        if content.hasContent && !hadContent {
            // Look before the first `apply()`: something that shows up while an app is
            // in full screen must not flash the island over it.
            lookAtScreens()
        }
        // Not only when `hasContent` flips: a session going from idle to working, or a
        // track going away with sessions listed, changes what the poll is for.
        updateCoverPoll()
        for stage in stages { stage.contentChanged(hadContent: hadContent, at: now) }
        if applying { stages.forEach { $0.apply() } }
    }

    // MARK: Full screen

    /// An app can go full screen on its own Space (the Space changes, or the app in
    /// front does) or with no sign at all, which the poll catches.
    func frontChanged(spaceChanged: Bool) {
        // With nothing to show the panels are off the screens anyway: nothing to hide or show.
        guard content.hasContent, !stages.isEmpty else { return }
        refreshCovers()
        // Back from a full-screen Space the window server hid the panels without telling
        // us, so what the states hold about the pointer may be stale.
        if spaceChanged { stages.forEach { $0.confirmPointer() } }
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
                if self.content.hasContent { self.refreshCovers() }
            }
        }
        RunLoop.main.add(check, forMode: .common)
        settleCheck = check
    }

    /// Looks at every island's screen with one read of the window list, and shows or
    /// hides each panel whose answer changed.
    private func refreshCovers() {
        guard !stages.isEmpty else { return }
        var changed = false
        for (stage, covered) in zip(stages, environment.covers(stages.map(\.geometry))) {
            if stage.refresh(covered: covered) { changed = true }
        }
        if changed { updateCoverPoll(lookedJustNow: true) }
    }

    /// Whether an app in full screen covers each island's screen now, with one read of
    /// the window list. Returns whether any answer changed; the caller decides when to
    /// `apply()`.
    @discardableResult
    private func lookAtScreens() -> Bool {
        guard !stages.isEmpty else { return false }
        var changed = false
        for (stage, covered) in zip(stages, environment.covers(stages.map(\.geometry))) {
            if stage.setCovered(covered) { changed = true }
        }
        return changed
    }

    /// Starts or stops the poll to match `IslandCoverPoll.isNeeded` on any screen.
    /// Called when the content changes and when a screen's `covered` does. Covered
    /// with nothing to show needs no poll: the panels are away anyway.
    private func updateCoverPoll(lookedJustNow: Bool = false) {
        let needed = stages.contains {
            IslandCoverPoll.isNeeded(canShowOnItsOwn: $0.state.canShowOnItsOwn,
                                     covered: $0.covered && $0.state.hasContent)
        }
        if needed {
            startCoverPoll()
            return
        }
        guard coverTimer != nil else { return }
        stopCoverPoll()
        // The poll goes quiet with sessions still listed: one last look, so `covered`
        // isn't left as it was up to 2 s ago. If a screen is covered, it starts again.
        if content.hasContent, !lookedJustNow, lookAtScreens() { updateCoverPoll(lookedJustNow: true) }
    }

    /// A borderless window can go full screen with no Space change and no change of
    /// the app in front (a game when it finishes loading, a player's own full screen,
    /// Keynote), so nothing announces it: the screens are looked at every few seconds.
    /// Only while something can show on its own (a track, a session at work) or an
    /// island is covered; with only idle sessions listed they are hidden, and the
    /// hover looks for itself.
    private func startCoverPoll() {
        guard coverTimer == nil else { return }
        let poll = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCovers() }
        }
        poll.tolerance = 0.5
        RunLoop.main.add(poll, forMode: .common)
        coverTimer = poll
    }

    private func stopCoverPoll() {
        coverTimer?.invalidate()
        coverTimer = nil
    }

    /// Whether the full-screen poll runs: for the tests, which never let it fire.
    var isPolling: Bool { coverTimer != nil }
}
