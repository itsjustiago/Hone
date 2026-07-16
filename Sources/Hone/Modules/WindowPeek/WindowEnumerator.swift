import CoreGraphics
import AppKit
import ApplicationServices

/// Lists an app's windows on the **current** Space plus its **minimized** windows
/// (windows on other Spaces are excluded), and captures thumbnails.
///
/// Current-Space windows come straight from `CGWindowList` (on-screen) — reliable
/// and already carrying the window id needed for capture, with no fragile AX↔CG
/// matching that could drop them. The Accessibility API is used only to enrich
/// titles and to add minimized windows (which aren't in the on-screen list).
enum WindowEnumerator {
    static func windows(forPID pid: pid_t) -> [WindowInfo] {
        let onScreen = cgWindows(forPID: pid, options: [.optionOnScreenOnly, .excludeDesktopElements])
        let axApp = AXUIElementCreateApplication(pid)
        let axWindows = AX.elements(axApp, "AXWindows")

        var result: [WindowInfo] = []
        // CGWindowIDs already claimed, so a minimized window with the same frame as
        // an on-screen one can't be matched to that window's id (and steal its
        // thumbnail — the cause of the "same page shown twice" duplicate).
        var usedIDs = Set<CGWindowID>()

        // 1. Windows on the current Space — from CGWindowList (always shown).
        for window in onScreen {
            let title = window.title.isEmpty ? nearestAXTitle(axWindows, to: window.bounds) : window.title
            result.append(WindowInfo(id: window.id, title: title, ownerPID: pid,
                                     bounds: window.bounds, thumbnail: nil, isMinimized: false))
            usedIDs.insert(window.id)
        }

        // 2. Minimized windows — from AX, appended on top.
        let allWindows = cgWindows(forPID: pid, options: [.optionAll, .excludeDesktopElements])
        for axWindow in axWindows {
            guard AX.bool(axWindow, "AXMinimized") == true else { continue }
            // A minimized window is a real, restorable window whatever its subrole —
            // some apps flip minimized document windows to AXDialog (Finder does), so
            // requiring AXStandardWindow here made them vanish. Only skip palettes.
            guard !isAuxiliarySubrole(AX.string(axWindow, "AXSubrole")) else { continue }

            let pos = AX.point(axWindow, "AXPosition") ?? .zero
            let size = AX.size(axWindow, "AXSize") ?? .zero
            var bounds = CGRect(origin: pos, size: size)
            if bounds.width < 90 || bounds.height < 60 {
                bounds = CGRect(x: bounds.minX, y: bounds.minY, width: 1280, height: 800)
            }

            let matchedID = matchWindowID(allWindows, to: bounds, excluding: usedIDs)
            if matchedID != 0 { usedIDs.insert(matchedID) }
            result.append(WindowInfo(id: matchedID,
                                     title: AX.string(axWindow, "AXTitle") ?? "",
                                     ownerPID: pid, bounds: bounds,
                                     thumbnail: nil, isMinimized: true))
        }

        return result
    }

    /// Captures a thumbnail of a single window. Requires Screen Recording; returns
    /// nil without it, or for windows with no capturable id.
    @available(macOS, deprecated: 14.0)
    static func thumbnail(for id: CGWindowID) -> CGImage? {
        guard id != 0 else { return nil }
        return CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                       [.boundsIgnoreFraming, .nominalResolution])
    }

    // MARK: - CGWindowList

    private struct CGWin { let id: CGWindowID; let bounds: CGRect; let title: String }

    private static func cgWindows(forPID pid: pid_t, options: CGWindowListOption) -> [CGWin] {
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var out: [CGWin] = []
        for dict in raw {
            guard let owner = dict[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = dict[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            guard bounds.width >= 90, bounds.height >= 60 else { continue }
            let title = (dict[kCGWindowName as String] as? String) ?? ""
            out.append(CGWin(id: number, bounds: bounds, title: title))
        }
        return out
    }

    // MARK: - AX matching helpers

    private static func nearestAXTitle(_ windows: [AXUIElement], to bounds: CGRect) -> String {
        var bestTitle = ""
        var bestDistance = 40.0
        for window in windows {
            guard let title = AX.string(window, "AXTitle"), !title.isEmpty,
                  let pos = AX.point(window, "AXPosition") else { continue }
            let distance = hypot(pos.x - bounds.minX, pos.y - bounds.minY)
            if distance < bestDistance {
                bestDistance = distance
                bestTitle = title
            }
        }
        return bestTitle
    }

    private static func matchWindowID(_ windows: [CGWin], to bounds: CGRect,
                                      excluding used: Set<CGWindowID>) -> CGWindowID {
        var bestID: CGWindowID = 0
        var bestDistance: CGFloat = 120
        for window in windows where !used.contains(window.id) {
            let distance = abs(window.bounds.minX - bounds.minX)
                + abs(window.bounds.minY - bounds.minY)
                + abs(window.bounds.width - bounds.width)
                + abs(window.bounds.height - bounds.height)
            if distance < bestDistance {
                bestDistance = distance
                bestID = window.id
            }
        }
        return bestID
    }
}
