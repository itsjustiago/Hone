import AppKit

/// Tracks whether the old standalone apps (the "twins" of Hone's embedded
/// tools) are running, and quits them on request.
///
/// A tool and its twin share the same defaults and files, and would register
/// the same hotkeys and menu-bar icons — so they must never run together.
/// `ModuleManager` owns the policy; this type only watches and reports.
@MainActor
@Observable
final class LegacyApps {
    static let shared = LegacyApps()

    /// Bundle ids of watched twins that are running right now.
    private(set) var running: Set<String> = []

    /// Called with the bundle id when a watched twin launches / quits.
    @ObservationIgnored var onLaunch: ((String) -> Void)?
    @ObservationIgnored var onTerminate: ((String) -> Void)?

    @ObservationIgnored private var watched: Set<String> = []
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private static let autoQuitKey = "legacyApps.autoQuit"

    /// The user agreed to have twins quit automatically whenever they appear
    /// (e.g. still in their login items).
    static var autoQuit: Bool {
        get { UserDefaults.standard.bool(forKey: autoQuitKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoQuitKey) }
    }

    private init() {}

    /// Start watching `bundleIDs`. Seeds `running` from the current process list.
    func watch(_ bundleIDs: Set<String>) {
        watched = bundleIDs
        running = runningTwins()
        guard observation == nil else { return }
        // The twins are agent apps (LSUIElement), and NSWorkspace posts no
        // didLaunch/didTerminate notifications for those — only the
        // `runningApplications` key path reports them coming and going.
        observation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
    }

    func isRunning(_ bundleID: String) -> Bool { running.contains(bundleID) }

    /// Asks the twin to quit normally (like ⌘Q) so it cleans up after itself.
    /// Never force-terminates.
    func quit(_ bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
    }

    /// Watched twins in the workspace's process list right now. A twin with
    /// several instances counts as running until the last one is gone.
    private func runningTwins() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated }
            .compactMap(\.bundleIdentifier))
            .intersection(watched)
    }

    /// Re-reads the process list and reports the twins that appeared or left.
    private func reconcile() {
        let now = runningTwins()
        let before = running
        guard now != before else { return }
        running = now
        for id in now.subtracting(before).sorted() { onLaunch?(id) }
        for id in before.subtracting(now).sorted() { onTerminate?(id) }
    }
}
