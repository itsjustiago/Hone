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
}

/// Builds the cross-app window list for the switcher in global front-to-back
/// (most-recently-used) order, so selecting the second entry and releasing flips
/// straight to the previously used window — exactly like the system switcher.
///
/// On-screen windows come from a single global `CGWindowList` pass to preserve
/// that stacking order (a per-app pass would lose it). Minimized windows aren't
/// on-screen, so they're gathered per app via the Accessibility API and appended.
enum AltTabWindowLister {
    @MainActor
    static func allWindows(captureThumbnails: Bool, includeMinimized: Bool) -> [AltTabEntry] {
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Only apps that show up in the Dock / Cmd-Tab — skips menu-bar agents,
        // pop-overs and the like, matching what a user thinks of as "a window".
        let regularPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .map { $0.processIdentifier })

        let canCapture = captureThumbnails && Permissions.shared.isScreenRecordingTrusted
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

        // 2. Minimized windows, per app, appended after the live ones.
        if includeMinimized {
            for pid in regularPIDs {
                windows.append(contentsOf: minimizedWindows(pid: pid))
            }
        }

        // 3. Enrich with app name/icon and (optionally) a thumbnail.
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

    /// Minimized standard windows for one app, read straight from AX.
    private static func minimizedWindows(pid: pid_t) -> [WindowInfo] {
        let axApp = AXUIElementCreateApplication(pid)
        var out: [WindowInfo] = []
        for axWindow in AX.elements(axApp, "AXWindows") {
            guard AX.bool(axWindow, "AXMinimized") == true else { continue }
            let subrole = AX.string(axWindow, "AXSubrole")
            guard subrole == nil || subrole == "AXStandardWindow" else { continue }

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
