import AppKit
import ApplicationServices
import os

/// Quits an app once its last window closes — and only when that is proven.
///
/// Every eligible app gets an `AppWindowWatcher`; when one reports a destroyed
/// window the app's remaining windows are counted through the AX API and, if
/// there really are none, it is asked to quit the polite way.
///
/// **Quit on proof, never on silence.** Zero windows is a conclusion, not the
/// default: it takes a clean AX answer with nothing that counts in it, nothing of
/// the app on screen, an app that isn't hidden or holding a running child, and an
/// app that has been *seen with a window* since the Spaces last changed (see
/// `QuitRules` and `WindowStamps`). Anything else leaves the app alone. That is
/// what this replaced: an empty answer was enough, and Steam — whose windows AX
/// doesn't count — was quit three minutes after every launch, game and all.
///
/// Two more guards keep a false positive from firing:
///
/// - **double confirmation.** Leaving full screen, and a few apps mid-transition,
///   pass through a moment with zero windows. Zero is only acted on when it is
///   still zero one debounce later.
/// - **a fresh verdict at the end.** Confirmed zero doesn't quit on the spot unless
///   the delay is `0`: it starts a countdown, and the whole verdict is rebuilt from
///   scratch when it fires.
///
/// The destroyed-window notification is the fast path, never the only one. A
/// window can go away with nobody listening — in an app that simply never
/// announces it — and the app is then windowless with no one counting. A periodic
/// sweep re-asks instead of assuming a notification arrived, and feeds the answer
/// through the very same guards.
///
/// Every decision that matters is written to the log (subsystem `com.tiagof.hone`,
/// category `quit-on-close`), so "why did X close?" and "why didn't X?" both have
/// an answer.
///
/// Nothing here captures the screen.
@MainActor
final class QuitOnCloseController {
    private let settings: QuitOnCloseSettings

    /// Long enough for an app to finish tearing down or rebuilding its windows,
    /// short enough that the Dock icon doesn't linger.
    private static let debounce: TimeInterval = 0.35

    /// How often the sweep re-counts. Often enough that a missed notification
    /// costs seconds rather than the rest of the session, rare enough that the
    /// AX round-trips stay invisible.
    private static let sweepInterval: TimeInterval = 20

    /// An app this young hasn't failed to draw a window — it just hasn't got
    /// there yet. Keeps the sweep off apps still starting up at login.
    private static let launchGrace: TimeInterval = 60

    /// How long the sweep leaves an app alone after asking it to quit. An app
    /// that refuses — an unsaved document, a modal sheet — must not be nagged
    /// every sweep. The notification path is unaffected.
    private static let quitCooldown: TimeInterval = 300

    /// After the Spaces change (or the Mac wakes) the windows get this long to
    /// settle before every app is looked at again for its "seen with a window" mark.
    private static let settleDelay: TimeInterval = 1.5

    /// `NSLog` would do, but the unified log redacts its message as `<private>`.
    private static let journal = Logger(subsystem: "com.tiagof.hone", category: "quit-on-close")

    private var watchers: [pid_t: AppWindowWatcher] = [:]
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var pendingChecks: [pid_t: DispatchWorkItem] = [:]

    /// Apps confirmed windowless and waiting out `delaySeconds` before quitting.
    private var pendingQuits: [pid_t: DispatchWorkItem] = [:]
    private var lastQuitAttempt: [pid_t: Date] = [:]
    private var sweepTimer: Timer?
    private var isRunning = false

    /// Which apps have been seen with a window since the Spaces last changed.
    private var stamps = WindowStamps()
    private var restampWork: DispatchWorkItem?

    /// The last thing logged about each app, so a sweep that keeps reaching the same
    /// conclusion every 20 s says it once.
    private var lastNote: [pid_t: String] = [:]

    init(settings: QuitOnCloseSettings) {
        self.settings = settings
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let center = NSWorkspace.shared.notificationCenter
        // Activation is in here because an accessory app can flip to `.regular`
        // long after launch (menu-bar apps that open a real window), and that is
        // the first moment it becomes watchable. It is also a moment the app has
        // a window in front of the user, which is what earns the mark.
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self,
                          let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    else { return }
                    switch name {
                    case NSWorkspace.didTerminateApplicationNotification:
                        self.detach(pid: app.processIdentifier)
                    case NSWorkspace.didActivateApplicationNotification:
                        if !self.attach(to: app) { self.stampIfWindowed(app) }
                    default:
                        self.attach(to: app)
                    }
                }
            }
            observers.append((center, token))
        }

        // The AX list only holds the windows of the Spaces on screen, so whenever
        // those may have changed, every earlier "seen with a window" is out of date.
        let spaceNames: [(NotificationCenter, NSNotification.Name)] = [
            (center, NSWorkspace.activeSpaceDidChangeNotification),
            (center, NSWorkspace.didWakeNotification),
            (center, NSWorkspace.screensDidWakeNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
        ]
        for (center, name) in spaceNames {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.spaceMayHaveChanged() }
            }
            observers.append((center, token))
        }

        for app in NSWorkspace.shared.runningApplications { attach(to: app) }

        // First pass one interval from now, so an app that was mid-launch when
        // the tool started gets the same grace as one launched later.
        sweepTimer = Timer.scheduledTimer(withTimeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    /// Leaves nothing behind: no AX observers, no run loop sources, no timers.
    func stop() {
        isRunning = false

        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()

        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()

        for check in pendingChecks.values { check.cancel() }
        pendingChecks.removeAll()

        for quit in pendingQuits.values { quit.cancel() }
        pendingQuits.removeAll()
        lastQuitAttempt.removeAll()

        restampWork?.cancel()
        restampWork = nil
        stamps = WindowStamps()
        lastNote.removeAll()

        sweepTimer?.invalidate()
        sweepTimer = nil
    }

    // MARK: - Watchers

    /// Starts watching `app`; false if it already was, or can't be.
    @discardableResult
    private func attach(to app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        guard isRunning, watchers[pid] == nil, isWatchable(app),
              let watcher = AppWindowWatcher(pid: pid)
        else { return false }
        watcher.onWindowDestroyed = { [weak self] in self?.windowClosed(pid: pid) }
        watcher.onWindowCreated = { [weak self] in self?.windowOpened(pid: pid) }
        watchers[pid] = watcher
        stampIfWindowed(app)
        return true
    }

    private func detach(pid: pid_t) {
        watchers.removeValue(forKey: pid)?.stop()
        pendingChecks.removeValue(forKey: pid)?.cancel()
        pendingQuits.removeValue(forKey: pid)?.cancel()
        // pids are reused, so nothing about the old process may outlive it.
        lastQuitAttempt.removeValue(forKey: pid)
        lastNote.removeValue(forKey: pid)
        stamps.forget(pid)
    }

    /// Apps we may watch *and* may quit, before the user's lists have a say.
    /// Deliberately the same check on both ends: it runs again immediately
    /// before terminating, so nothing can be quit on a stale verdict.
    private func isWatchable(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated,
              app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              !QuitRules.neverQuit.contains(bundleID)
        else { return false }
        return true
    }

    // MARK: - Window events

    private func windowClosed(pid: pid_t) {
        stamps.sawClosure(pid)
        scheduleCheck(pid: pid)
    }

    /// A new window means the app is in use again, so any countdown started by an
    /// earlier close is void — the user reopened before the time was up.
    private func windowOpened(pid: pid_t) {
        cancelQuit(pid: pid)
        if WindowCensus.hasWindow(pid) { stamps.sawWindow(pid) }
    }

    // MARK: - Seen with a window

    /// The app has an ordinary window in the AX list right now: its list can be
    /// believed when it later comes back empty. The one thing that earns the mark.
    private func stampIfWindowed(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard isWatchable(app), WindowCensus.hasWindow(pid) else { return }
        stamps.sawWindow(pid)
    }

    private func spaceMayHaveChanged() {
        stamps.spaceMayHaveChanged()
        // The windows of the Space we landed on need a moment to be listed; one
        // pass after the last change, however many came in a burst.
        restampWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restamp() }
        }
        restampWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func restamp() {
        restampWork = nil
        guard isRunning else { return }
        for app in NSWorkspace.shared.runningApplications { stampIfWindowed(app) }
    }

    // MARK: - Sweep

    /// Re-counts the windows of every app nobody is currently deciding about.
    /// Costs one AX query per app, and any app that answers with a window is
    /// dropped on the spot — the expensive part only runs for the ones that are
    /// genuinely empty.
    private func sweep() {
        guard isRunning else { return }
        let now = Date()

        for app in NSWorkspace.shared.runningApplications where isWatchable(app) {
            let pid = app.processIdentifier

            // Also recovers an app whose watcher never attached, e.g. because its
            // AX server wasn't up yet when it launched.
            attach(to: app)

            guard pendingChecks[pid] == nil, pendingQuits[pid] == nil else { continue }
            if let launch = app.launchDate, now.timeIntervalSince(launch) < Self.launchGrace { continue }
            if let asked = lastQuitAttempt[pid], now.timeIntervalSince(asked) < Self.quitCooldown { continue }

            check(pid: pid, isConfirmation: false)
        }
    }

    // MARK: - Counting and quitting

    private func scheduleCheck(pid: pid_t, confirming: Bool = false) {
        pendingChecks[pid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check(pid: pid, isConfirmation: confirming) }
        }
        pendingChecks[pid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    private func check(pid: pid_t, isConfirmation: Bool) {
        pendingChecks[pid] = nil

        guard let app = quittableApp(pid: pid), provenEmpty(app) else { return }

        guard isConfirmation else { return scheduleCheck(pid: pid, confirming: true) }

        guard settings.delaySeconds > 0 else { return terminate(app) }

        // The app is windowless *now* and stays that way until something opens a
        // window — an event that cancels the countdown outright. So a second
        // destroyed window must not restart it, or an app being emptied one window
        // at a time would keep pushing its own deadline away.
        guard pendingQuits[pid] == nil else { return }

        log(app, "no windows, quitting in \(settings.delaySeconds) s unless one opens")
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.quitIfStillEmpty(pid: pid) }
        }
        pendingQuits[pid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(settings.delaySeconds), execute: work)
    }

    /// End of the countdown. Minutes may have passed, so nothing from the earlier
    /// verdict is reused: eligibility, the user's lists and the window count are
    /// all worked out again right here.
    private func quitIfStillEmpty(pid: pid_t) {
        pendingQuits[pid] = nil
        guard let app = quittableApp(pid: pid), provenEmpty(app) else { return }
        terminate(app)
    }

    private func cancelQuit(pid: pid_t) {
        pendingQuits.removeValue(forKey: pid)?.cancel()
    }

    /// The app behind a pid, if it is still one we may quit at this instant.
    private func quittableApp(pid: pid_t) -> NSRunningApplication? {
        guard isRunning,
              let app = NSRunningApplication(processIdentifier: pid),
              isWatchable(app),
              let bundleID = app.bundleIdentifier,
              settings.allowsQuitting(bundleID)
        else { return nil }
        return app
    }

    /// A fresh look that may end in "quit". The app has to be provably empty (see
    /// `QuitRules.verdict`) *and* one whose AX list can be believed — seen with a
    /// window since the Spaces last changed — or it is left alone.
    private func provenEmpty(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        let verdict = WindowCensus.verdict(for: app)

        if verdict == .windowed(.accessibility) {
            stamps.sawWindow(pid)
            lastNote.removeValue(forKey: pid)
        }

        let vouched = stamps.vouches(for: pid, knownWindows: watchers[pid]?.knownWindowCount ?? 0)
        switch QuitRules.assess(verdict, vouched: vouched) {
        case .provenEmpty:
            return true
        case .keep(let why):
            // An app with a window is the normal case and not worth a line; anything
            // that looked like emptiness and wasn't proof is.
            if verdict != .windowed(.accessibility) { log(app, "left alone — \(why)", once: true) }
            return false
        }
    }

    /// The normal quit AppleEvent, never `forceTerminate`: the app still gets to
    /// put up "save changes?" and can refuse.
    private func terminate(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        lastQuitAttempt[pid] = Date()
        lastNote.removeValue(forKey: pid)
        log(app, "quitting — its last window is gone")
        app.terminate()
    }

    /// One line in the log, for "why did X close?" and "why didn't X?". `once`
    /// skips a line that repeats what was last said about the app, so a sweep that
    /// keeps reaching the same conclusion says it once rather than every 20 s.
    private func log(_ app: NSRunningApplication, _ message: String, once: Bool = false) {
        let pid = app.processIdentifier
        if once {
            guard lastNote[pid] != message else { return }
            lastNote[pid] = message
        }
        let name = app.localizedName ?? "?", bundleID = app.bundleIdentifier ?? "?"
        Self.journal.notice("\(name, privacy: .public) (\(bundleID, privacy: .public)): \(message, privacy: .public)")
    }
}
