import AppKit
import ApplicationServices

/// Brings a specific window to the front: activates its app and raises the
/// matching AX window.
enum WindowFocuser {
    static func focus(_ window: WindowInfo) {
        NSRunningApplication(processIdentifier: window.ownerPID)?.activate()

        guard let match = AX.window(for: window) else { return }
        // Restore if minimized, then raise and make it the main window. Raising a
        // window on another Space switches to that Space automatically.
        AX.setBool(match, "AXMinimized", false)
        AX.perform(match, "AXRaise")
        AX.setBool(match, "AXMain", true)
    }
}
