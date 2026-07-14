import AppKit
import ApplicationServices

/// Brings a specific window to the front: activates its app and raises the
/// matching AX window.
enum WindowFocuser {
    static func focus(_ window: WindowInfo) {
        NSRunningApplication(processIdentifier: window.ownerPID)?.activate()

        let axApp = AXUIElementCreateApplication(window.ownerPID)
        let axWindows = AX.elements(axApp, "AXWindows")
        guard let match = bestMatch(axWindows, to: window) else { return }
        // Restore if minimized, then raise and make it the main window. Raising a
        // window on another Space switches to that Space automatically.
        AX.setBool(match, "AXMinimized", false)
        AX.perform(match, "AXRaise")
        AX.setBool(match, "AXMain", true)
    }

    /// Match by exact title when available, else by nearest top-left corner.
    private static func bestMatch(_ windows: [AXUIElement], to info: WindowInfo) -> AXUIElement? {
        if !info.title.isEmpty {
            for w in windows where AX.string(w, "AXTitle") == info.title {
                return w
            }
        }
        var best: AXUIElement?
        var bestDistance = Double.greatestFiniteMagnitude
        for w in windows {
            guard let pos = AX.point(w, "AXPosition") else { continue }
            let distance = hypot(pos.x - info.bounds.minX, pos.y - info.bounds.minY)
            if distance < bestDistance {
                bestDistance = distance
                best = w
            }
        }
        return best
    }
}
