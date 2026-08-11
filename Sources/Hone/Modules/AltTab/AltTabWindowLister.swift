import AppKit
import CoreGraphics
import ApplicationServices

/// One tile in the switcher: a window plus the owning app's name and icon (used
/// for the badge and as the placeholder when there is no thumbnail).
struct AltTabEntry: Identifiable, Equatable {
    /// Stable only within a single switcher session — it's the array position, so
    /// SwiftUI keeps identity while the highlight moves (the list itself is fixed).
    let id: Int
    var window: WindowInfo
    let appName: String
    let appIcon: NSImage?

    static func == (lhs: AltTabEntry, rhs: AltTabEntry) -> Bool {
        lhs.id == rhs.id && lhs.window == rhs.window
    }

    /// The same window at a new list position. Closing a window from the switcher
    /// shortens the list, and `id` *is* the position, so the rest renumber.
    func renumbered(to id: Int) -> AltTabEntry {
        AltTabEntry(id: id, window: window, appName: appName, appIcon: appIcon)
    }
}

/// Builds the cross-app window list for the switcher in most-recently-used order,
/// so selecting the second entry and releasing flips straight to the window the
/// user just came from — exactly like the system switcher.
///
/// On-screen windows come from a single global `CGWindowList` pass, which gives
/// them front-to-back. Minimized windows aren't on screen, so they're gathered per
/// app via the Accessibility API and appended. Stacking order is only the starting
/// point: `AltTabWindowOrder` then sorts the list by what the user actually used,
/// which stacking merely resembles (see its notes for how the two come apart).
enum AltTabWindowLister {
    @MainActor
    static func allWindows(captureContent: Bool,
                           includeMinimized: Bool,
                           usage: AltTabWindowOrder? = nil) -> [AltTabEntry] {
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Only apps that show up in the Dock / Cmd-Tab — skips menu-bar agents,
        // pop-overs and the like, matching what a user thinks of as "a window".
        let regularPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .map { $0.processIdentifier })

        // A single snapshot per window, taken now (before the overlay covers the
        // screen) — only when a content mode asked for it. Live refreshing, when
        // enabled, is layered on by the controller.
        let canCapture = captureContent && Permissions.shared.isScreenRecordingTrusted
        var windows: [WindowInfo] = []

        // 1. On-screen windows across every app, in z-order.
        if let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] {
            for dict in raw {
                guard let pid = dict[kCGWindowOwnerPID as String] as? pid_t, regularPIDs.contains(pid),
                      let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
                      let number = dict[kCGWindowNumber as String] as? CGWindowID,
                      let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                      let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                      bounds.width >= 90, bounds.height >= 60
                else { continue }
                let title = (dict[kCGWindowName as String] as? String) ?? ""
                windows.append(WindowInfo(id: number, title: title, ownerPID: pid,
                                          bounds: bounds, thumbnail: nil, isMinimized: false))
            }
        }

        // 2. Minimized windows, per app, appended after the live ones. The pids are
        //    walked in a fixed order so the list doesn't reshuffle between summons
        //    (a Set has no order of its own).
        if includeMinimized {
            for pid in regularPIDs.sorted() where !isStalled(pid) {
                windows.append(contentsOf: minimizedWindows(pid: pid))
            }
        }

        // 3. Re-order by use rather than by stacking — see `AltTabWindowOrder`.
        if let usage { windows = sortedByUse(windows, usage: usage) }

        // 4. Enrich with app name/icon and (optionally) a thumbnail.
        var iconCache: [pid_t: (name: String, icon: NSImage?)] = [:]
        return windows.enumerated().map { index, window in
            var window = window
            if canCapture, !window.isMinimized {
                window.thumbnail = WindowEnumerator.thumbnail(for: window.id)
            }
            let app: (name: String, icon: NSImage?)
            if let cached = iconCache[window.ownerPID] {
                app = cached
            } else {
                let running = NSRunningApplication(processIdentifier: window.ownerPID)
                app = (running?.localizedName ?? "App", running?.icon)
                iconCache[window.ownerPID] = app
            }
            return AltTabEntry(id: index, window: window, appName: app.name, appIcon: app.icon)
        }
    }

    /// Most-recently-used first, with the windows nobody has touched keeping the
    /// order they were stacked in. Minimized windows always come after the ones
    /// still on screen: being minimized is the opposite of being in use, and they
    /// have no window number to be remembered by anyway.
    @MainActor
    static func sortedByUse(_ windows: [WindowInfo], usage: AltTabWindowOrder) -> [WindowInfo] {
        windows.enumerated().sorted { a, b in
            if a.element.isMinimized != b.element.isMinimized { return !a.element.isMinimized }
            let (rankA, rankB) = (usage.rank(of: a.element.id), usage.rank(of: b.element.id))
            if rankA != rankB { return rankA < rankB }
            return a.offset < b.offset
        }
        .map(\.element)
    }

    /// Every on-screen window, front to back. The seed for the use order, and the
    /// answer to "what is in front right now?".
    static func windowIDsInStackingOrder() -> [CGWindowID] {
        onScreenWindows().compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    /// The frontmost window of one app — which, right after that app is activated,
    /// is the window the user just moved to.
    static func frontWindowID(ofApplication pid: pid_t) -> CGWindowID? {
        onScreenWindows()
            .first { $0[kCGWindowOwnerPID as String] as? pid_t == pid }
            .flatMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    /// The raw front-to-back window list, filtered to ordinary app windows.
    private static func onScreenWindows() -> [[String: Any]] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
    }

    /// How long an app gets to answer before the switcher moves on without it.
    /// Apps that are up answer in well under a millisecond; the cap only ever
    /// bites on one that is wedged or busy.
    private static let axDeadline: Float = 0.05

    /// Apps that blew the deadline, and when. Asking a wedged app again on every
    /// summon would pay the timeout every time, so it is skipped — but only for a
    /// while, since an app that was merely busy deserves to come back.
    private static var stalledApps: [pid_t: Date] = [:]
    private static let stalledGracePeriod: TimeInterval = 60

    private static func isStalled(_ pid: pid_t) -> Bool {
        guard let since = stalledApps[pid] else { return false }
        guard Date().timeIntervalSince(since) < stalledGracePeriod else {
            stalledApps[pid] = nil
            return false
        }
        return true
    }

    /// Minimized standard windows for one app, read straight from AX.
    private static func minimizedWindows(pid: pid_t) -> [WindowInfo] {
        let (axWindows, stalled) = AX.windows(ofApplication: pid, timeout: axDeadline)
        if stalled {
            stalledApps[pid] = Date()
            return []
        }
        var out: [WindowInfo] = []
        for axWindow in axWindows {
            guard AX.bool(axWindow, "AXMinimized") == true else { continue }
            // Keep every real minimized window; some apps report them as AXDialog
            // rather than AXStandardWindow. Only palettes/panels are filtered out.
            guard !isAuxiliarySubrole(AX.string(axWindow, "AXSubrole")) else { continue }

            let pos = AX.point(axWindow, "AXPosition") ?? .zero
            let size = AX.size(axWindow, "AXSize") ?? CGSize(width: 1280, height: 800)
            var bounds = CGRect(origin: pos, size: size)
            if bounds.width < 90 || bounds.height < 60 {
                bounds = CGRect(x: bounds.minX, y: bounds.minY, width: 1280, height: 800)
            }
            out.append(WindowInfo(id: 0, title: AX.string(axWindow, "AXTitle") ?? "",
                                  ownerPID: pid, bounds: bounds, thumbnail: nil, isMinimized: true))
        }
        return out
    }
}
