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
/// Nothing here captures the screen.
@MainActor
final class QuitOnCloseController {
    private let settings: QuitOnCloseSettings

    /// Long enough for an app to finish tearing down or rebuilding its windows,
    /// short enough that the Dock icon doesn't linger.
    private static let debounce: TimeInterval = 0.35

    /// Apps that are expected to run without windows and whose death would break
    /// the desktop. Not a user preference — a hard floor under the lists.
    private static let neverQuit: Set<String> = ["com.apple.finder"]

    private var watchers: [pid_t: AppWindowWatcher] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pendingChecks: [pid_t: DispatchWorkItem] = [:]
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
    }

    // MARK: - Watchers

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard isRunning, watchers[pid] == nil, isWatchable(app),
              let watcher = AppWindowWatcher(pid: pid)
        else { return }
        watcher.onWindowDestroyed = { [weak self] in self?.scheduleCheck(pid: pid) }
        watchers[pid] = watcher
    }

    private func detach(pid: pid_t) {
        watchers.removeValue(forKey: pid)?.stop()
        pendingChecks.removeValue(forKey: pid)?.cancel()
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

        guard isRunning,
              let app = NSRunningApplication(processIdentifier: pid),
              isWatchable(app),
              let bundleID = app.bundleIdentifier,
              settings.allowsQuitting(bundleID)
        else { return }

        let result = AX.windows(ofApplication: pid, timeout: 0.25)
        guard !result.stalled else { return }

        // Minimized windows still show up in `AXWindows` — and should, an app with
        // a window in the Dock has not been closed. Only floating palettes are
        // dropped, since they don't keep an app alive on their own.
        let real = result.windows.filter { !isAuxiliarySubrole(AX.string($0, "AXSubrole")) }
        guard real.isEmpty else { return }

        guard isConfirmation else { return scheduleCheck(pid: pid, confirming: true) }

        // The normal quit AppleEvent, never `forceTerminate`: the app still gets to
        // put up "save changes?" and can refuse.
        app.terminate()
    }
}
