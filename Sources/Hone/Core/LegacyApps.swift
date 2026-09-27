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
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

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
        running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            .intersection(bundleIDs)
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = Self.bundleID(in: note)
            MainActor.assumeIsolated { self?.handle(id, launched: true) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = Self.bundleID(in: note)
            MainActor.assumeIsolated { self?.handle(id, launched: false) }
        })
    }

    func isRunning(_ bundleID: String) -> Bool { running.contains(bundleID) }

    /// Asks the twin to quit normally (like ⌘Q) so it cleans up after itself.
    /// Never force-terminates.
    func quit(_ bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
    }

    private nonisolated static func bundleID(in note: Notification) -> String? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    private func handle(_ bundleID: String?, launched: Bool) {
        guard let bundleID, watched.contains(bundleID) else { return }
        if launched {
            guard running.insert(bundleID).inserted else { return }
            onLaunch?(bundleID)
        } else {
            // Another instance may still be around; only clear when all are gone.
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { !$0.isTerminated }
            guard others.isEmpty,
                  running.remove(bundleID) != nil else { return }
            onTerminate?(bundleID)
        }
    }
}
