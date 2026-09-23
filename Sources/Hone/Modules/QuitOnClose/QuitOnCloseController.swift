import AppKit
import ApplicationServices

/// Quits an app once its last window closes.
///
/// Every eligible app gets an `AppWindowWatcher`; when one reports a destroyed
/// window the app's remaining windows are counted through the AX API and, if
/// there really are none, it is asked to quit the polite way.
///
/// Two guards keep that from firing on a false positive:
///
/// - **stalled ≠ empty.** An app that never answered the AX query is not an app
///   without windows, so it is left alone.
/// - **double confirmation.** Leaving full screen, and a few apps mid-transition,
///   pass through a moment with zero windows. Zero is only acted on when it is
///   still zero one debounce later.
///
/// Confirmed zero doesn't quit on the spot unless the delay is `0`: it starts a
/// countdown, and the whole verdict is rebuilt from scratch when it fires.
///
/// The destroyed-window notification is the fast path, never the only one. A
/// window can go away with nobody listening — while Hone wasn't running, before
/// the tool was switched on, or in an app that simply never announces it — and
/// the app is then windowless with no one counting, which is how apps ended up
/// sitting in the Dock for days. A periodic sweep re-asks instead of assuming a
/// notification arrived, and feeds the answer through the very same guards.
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

    /// Apps that are expected to run without windows and whose death would break
    /// the desktop. Not a user preference — a hard floor under the lists.
    private static let neverQuit: Set<String> = ["com.apple.finder"]

    private var watchers: [pid_t: AppWindowWatcher] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pendingChecks: [pid_t: DispatchWorkItem] = [:]

    /// Apps confirmed windowless and waiting out `delaySeconds` before quitting.
    private var pendingQuits: [pid_t: DispatchWorkItem] = [:]
    private var lastQuitAttempt: [pid_t: Date] = [:]
    private var sweepTimer: Timer?
    private var isRunning = false

    init(settings: QuitOnCloseSettings) {
        self.settings = settings
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let center = NSWorkspace.shared.notificationCenter
        // Activation is in here because an accessory app can flip to `.regular`
        // long after launch (menu-bar apps that open a real window), and that is
        // the first moment it becomes watchable.
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
                    if name == NSWorkspace.didTerminateApplicationNotification {
                        self.detach(pid: app.processIdentifier)
                    } else {
                        self.attach(to: app)
                    }
                }
            }
            workspaceObservers.append(token)
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

        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers { center.removeObserver(token) }
        workspaceObservers.removeAll()

        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()

        for check in pendingChecks.values { check.cancel() }
        pendingChecks.removeAll()

        for quit in pendingQuits.values { quit.cancel() }
        pendingQuits.removeAll()
        lastQuitAttempt.removeAll()

        sweepTimer?.invalidate()
        sweepTimer = nil
    }

    // MARK: - Watchers

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard isRunning, watchers[pid] == nil, isWatchable(app),
              let watcher = AppWindowWatcher(pid: pid)
        else { return }
        watcher.onWindowDestroyed = { [weak self] in self?.scheduleCheck(pid: pid) }
        // A new window means the app is in use again, so any countdown started by
        // an earlier close is void — the user reopened before the time was up.
        watcher.onWindowCreated = { [weak self] in self?.cancelQuit(pid: pid) }
        watchers[pid] = watcher
    }

    private func detach(pid: pid_t) {
        watchers.removeValue(forKey: pid)?.stop()
        pendingChecks.removeValue(forKey: pid)?.cancel()
        pendingQuits.removeValue(forKey: pid)?.cancel()
        // pids are reused, so nothing about the old process may outlive it.
        lastQuitAttempt.removeValue(forKey: pid)
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
              !Self.neverQuit.contains(bundleID)
        else { return false }
        return true
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

        guard let app = quittableApp(pid: pid), isWindowless(pid: pid) else { return }

        guard isConfirmation else { return scheduleCheck(pid: pid, confirming: true) }

        guard settings.delaySeconds > 0 else { return terminate(app) }

        // The app is windowless *now* and stays that way until something opens a
        // window — an event that cancels the countdown outright. So a second
        // destroyed window must not restart it, or an app being emptied one window
        // at a time would keep pushing its own deadline away.
        guard pendingQuits[pid] == nil else { return }

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
        guard let app = quittableApp(pid: pid), isWindowless(pid: pid) else { return }
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

    /// A fresh count. An app that didn't answer (`stalled`) is not windowless.
    private func isWindowless(pid: pid_t) -> Bool {
        let result = AX.windows(ofApplication: pid, timeout: 0.25)
        guard !result.stalled else { return false }

        // Minimized windows still show up in `AXWindows` — and should, an app with
        // a window in the Dock has not been closed. Only floating palettes are
        // dropped, since they don't keep an app alive on their own.
        return result.windows.allSatisfy { isAuxiliarySubrole(AX.string($0, "AXSubrole")) }
    }

    /// The normal quit AppleEvent, never `forceTerminate`: the app still gets to
    /// put up "save changes?" and can refuse.
    private func terminate(_ app: NSRunningApplication) {
        lastQuitAttempt[app.processIdentifier] = Date()
        app.terminate()
    }
}
