import AppKit

/// What a stage needs of its panel: `IslandPanel` in the app, a stand-in with no
/// window in the tests.
@MainActor
protocol IslandStagePanel: AnyObject {
    var model: IslandViewModel { get }
    /// Whether the pointer is over the island as drawn now.
    var containsMouse: Bool { get }
    func show(_ layout: IslandLayout, on geometry: NotchGeometry, keepsWindow: Bool)
    func hide()
    func close()
}

extension IslandPanel: IslandStagePanel {}

/// The island on one screen: its panel, its own `IslandState` (hover, click, the
/// open page), whether an app in full screen covers that screen, and the one
/// wake-up its state asks for. What it shows comes from `IslandStages`, the same on
/// every screen; the commands go back there too.
@MainActor
final class IslandStage {
    /// What a stage asks of the islands around it.
    struct Host {
        /// Whether the shared full-screen poll runs: `covered` is then never old.
        var isPolling: @MainActor () -> Bool = { false }
        /// Whether an app in full screen covers the screen of `geometry` now.
        var covers: @MainActor (NotchGeometry) -> Bool = { _ in false }
        /// `covered` changed on a look of the stage's own: the poll may have to start.
        var coverChanged: @MainActor () -> Void = {}
        /// The pointer, in global AppKit coordinates.
        var pointer: @MainActor () -> CGPoint = { NSEvent.mouseLocation }
        var send: @MainActor (NowPlayingCommand) -> Void = { _ in }
        var openPlayer: @MainActor () -> Void = {}
        /// Opens the session in the Claude app; `false` without the app.
        var openClaudeSession: @MainActor (ClaudeSession) -> Bool = { _ in false }
    }

    let id: CGDirectDisplayID
    private(set) var geometry: NotchGeometry
    /// Set once, in `init`: its actions call back into the stage.
    private(set) var panel: IslandStagePanel!
    private(set) var state: IslandState
    /// An app in full screen covers this screen: the panel stays away until it ends.
    private(set) var covered = false
    /// What the state was last told about the pointer.
    private(set) var hovering = false
    private let host: Host
    private var isClosed = false

    /// The one pending wake-up, at `state.nextChange(after:)`. None while idle.
    private var timer: Timer?
    /// Re-checks the pointer after a hover exit that the pointer never made.
    private var hoverCheck: Timer?

    var screen: IslandScreen { IslandScreen(id: id, geometry: geometry) }

    init(screen: IslandScreen, state: IslandState, host: Host,
         makePanel: @MainActor (IslandActions) -> IslandStagePanel) {
        id = screen.id
        geometry = screen.geometry
        self.state = state
        self.host = host
        panel = makePanel(IslandActions(
            hover: { [weak self] inside in self?.hoverChanged(inside) },
            click: { [weak self] in self?.clicked() },
            send: { [weak self] command in self?.host.send(command) },
            openApp: { [weak self] in self?.host.openPlayer() },
            openClaudeSession: { [weak self] session in self?.openClaudeSession(session) },
            selectPage: { [weak self] page in self?.selectPage(page) }
        ))
    }

    /// Dropped without `close()`: no wake-up outlives it.
    deinit {
        timer?.invalidate()
        hoverCheck?.invalidate()
    }

    /// The panel off the screen and every timer gone. Nothing runs for it after this.
    func close() {
        isClosed = true
        timer?.invalidate()
        timer = nil
        cancelHoverCheck()
        hovering = false
        panel.close()
    }

    // MARK: From the islands around it

    /// What there is to show, or the settings, changed: the same on every screen.
    func handle(_ event: IslandEvent, at now: Date) {
        state.handle(event, at: now)
    }

    func setOptions(openOnHover: Bool, peekOnTrackChange: Bool) {
        state.openOnHover = openOnHover
        state.peekOnTrackChange = peekOnTrackChange
    }

    /// The screen's geometry changed (resolution, arrangement, menu bar): the next
    /// `apply()` puts the panel there.
    func move(to geometry: NotchGeometry) {
        self.geometry = geometry
    }

    /// The answer of a look at this screen. Returns whether it changed; the caller
    /// decides when to `apply()`.
    @discardableResult
    func setCovered(_ covered: Bool) -> Bool {
        guard covered != self.covered else { return false }
        self.covered = covered
        return true
    }

    /// After a look at the screen: shows or hides the panel if the answer changed.
    /// Returns whether it did.
    @discardableResult
    func refresh(covered: Bool) -> Bool {
        guard !isClosed else { return false }
        guard setCovered(covered) else {
            // The window server can hide the panel on its own (native full screen) and
            // then sends no "exited": a hover held that long is checked against the pointer.
            if hovering { confirmPointer() }
            return false
        }
        apply()
        // The panel comes back under a pointer that may be resting on the notch.
        if !self.covered { confirmPointer() }
        return true
    }

    /// After what there is to show changed (and, if something showed up, a look at
    /// the screen): the pointer, kept in step with it.
    func contentChanged(hadContent: Bool, at now: Date) {
        let hasContent = state.hasContent
        if hadContent && !hasContent {
            // The state forgot the pointer with the last thing to show.
            cancelHoverCheck()
            hovering = false
        }
        // A pointer already resting on the notch gets no new "entered" from AppKit.
        if !covered, IslandHover.shouldReenter(hadContent: hadContent, hasContent: hasContent,
                                               pointerInside: pointerInside(at: now)) {
            hovering = true
            state.handle(.hoverEntered, at: now)
        }
    }

    /// Tells the state where the pointer really is, after the panel moved or came
    /// back: what it was told earlier may no longer be true.
    func confirmPointer() {
        // No hover for an island that isn't there.
        guard !isClosed, !covered else { return }
        let now = Date()
        switch IslandHover.correction(hovering: hovering, hasContent: state.hasContent,
                                      pointerInside: pointerInside(at: now)) {
        case .none:
            return
        case .enter:
            hovering = true
            state.handle(.hoverEntered, at: now)
        case .exit:
            cancelHoverCheck()
            hovering = false
            state.handle(.hoverExited, at: now)
        }
        apply()
    }

    // MARK: Output

    /// Shows what the state says now and sleeps until it may say something else.
    func apply() {
        timer?.invalidate()
        timer = nil
        guard !isClosed else { return }
        guard !covered else {
            // An app in full screen covers this screen. The panel leaves, and the pointer
            // can no longer be over it: let go of the hover too, or the island would come
            // back open and stuck.
            releaseHover()
            panel.hide()
            return
        }
        let now = Date()
        // Hidden with something to show, the island keeps its hover zone: inside a
        // real notch, or the strip along the top of a screen with a virtual one.
        panel.show(state.layout(at: now), on: geometry, keepsWindow: state.hasContent)
        guard let next = state.nextChange(after: now) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        // Common modes: it must fire while a menu is open too.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: The pointer

    /// Whether the pointer is over the island as the state has it at `now`.
    private func pointerInside(at now: Date) -> Bool {
        IslandHover.pointerInside(host.pointer(), frame: geometry.islandFrame(for: state.layout(at: now)))
    }

    private func hoverChanged(_ inside: Bool) {
        guard !isClosed else { return }
        if inside {
            cancelHoverCheck()
            // With nothing to show the state ignores it; marking it here would swallow
            // the real "entered" once something arrives.
            guard state.hasContent, !hovering else { return }
            // Without the poll (only idle sessions) nobody has looked at the screen:
            // look before the island opens over a full-screen app.
            if !host.isPolling(), setCovered(host.covers(geometry)) {
                host.coverChanged()
                apply()
                if covered { return }
            }
            hovering = true
            state.handle(.hoverEntered, at: Date())
            apply()
        } else {
            guard hovering else { return }
            if panel.containsMouse {
                // The content swapped under a pointer that never left: look again shortly.
                scheduleHoverCheck()
                return
            }
            cancelHoverCheck()
            hovering = false
            state.handle(.hoverExited, at: Date())
            apply()
        }
    }

    private func releaseHover() {
        cancelHoverCheck()
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

    private func cancelHoverCheck() {
        hoverCheck?.invalidate()
        hoverCheck = nil
    }

    private func clicked() {
        guard !isClosed else { return }
        // A click proves the pointer is over the island, even if it never moved.
        if !hovering { hoverChanged(true) }
        state.handle(.clicked, at: Date())
        apply()
    }

    private func selectPage(_ page: IslandPage) {
        guard !isClosed else { return }
        state.handle(.pageSelected(page), at: Date())
        apply()
    }

    /// Opens the session in the Claude app, then folds this island: the user is off
    /// to the app. Without the app, it stays.
    private func openClaudeSession(_ session: ClaudeSession) {
        guard !isClosed, host.openClaudeSession(session) else { return }
        state.handle(.dismissed, at: Date())
        apply()
    }
}
