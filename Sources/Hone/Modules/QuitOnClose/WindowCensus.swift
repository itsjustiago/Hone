import AppKit
import ApplicationServices
import Darwin

/// Asks the system what an app's windows look like. The judging is `QuitRules`'
/// job; this only gathers the evidence, and never captures the screen.
@MainActor
enum WindowCensus {
    /// A short deadline: a wedged app must not hold the main thread for long, and
    /// one that doesn't answer in time is *not* an app without windows.
    private static let axTimeout: Float = 0.25

    /// A fresh look at one app.
    static func verdict(for app: NSRunningApplication) -> WindowVerdict {
        let pid = app.processIdentifier
        return QuitRules.verdict(
            listing: listing(of: pid),
            visibleOnScreen: { onScreenOwners()?.contains(pid) },
            isHidden: { app.isHidden },
            hasActiveChild: { hasActiveChild(of: pid) })
    }

    /// Whether the AX list shows the app with a real window — what earns an app
    /// its "seen with a window" mark. Nothing else does: a window on screen that
    /// AX doesn't list says nothing about whether AX would notice it closing.
    static func hasWindow(_ pid: pid_t) -> Bool {
        guard case .answered(let windows) = listing(of: pid) else { return false }
        return windows.contains(where: QuitRules.countsAsWindow)
    }

    /// `AXWindows`, keeping what `AX.windows` throws away: only a `.success` is an
    /// answer. A timeout, a refusal or an unsupported attribute is `.failed` — not
    /// an empty list.
    static func listing(of pid: pid_t) -> WindowListing {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement]
        else { return .failed }
        return .answered(windows.map {
            WindowFact(subrole: AX.string($0, "AXSubrole"), isMinimized: AX.bool($0, "AXMinimized") ?? false)
        })
    }

    // MARK: - On screen

    /// Owners of ordinary windows on screen right now; nil if the system won't say.
    private static func onScreenOwners() -> Set<pid_t>? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return QuitRules.visibleWindowOwners(in: info)
    }

    // MARK: - Children

    /// A launcher whose game is running is in use even with nothing on screen of
    /// its own. Any process below it that is a Dock app, or has a window up, counts.
    private static func hasActiveChild(of pid: pid_t) -> Bool {
        let below = QuitRules.descendants(of: pid, children: childPIDs)
        guard !below.isEmpty else { return false }
        let visible = onScreenOwners() ?? []
        return below.contains { child in
            visible.contains(child)
                || NSRunningApplication(processIdentifier: child)?.activationPolicy == .regular
        }
    }

    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 128)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        // The return value is how many pids were written, not how many bytes.
        guard count > 0 else { return [] }
        return buffer.prefix(min(Int(count), buffer.count)).filter { $0 > 0 }
    }
}
