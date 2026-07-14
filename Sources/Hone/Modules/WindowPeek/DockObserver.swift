import AppKit
import ApplicationServices

/// Watches the cursor and reports when it hovers an application icon in the Dock.
///
/// Polls the cursor position on a timer (not just `mouseMoved`, which stops firing
/// once the cursor is *parked* on an icon — a common "nothing appeared" cause).
/// Each tick hit-tests the system-wide AX tree, which stays correct as the Dock
/// magnifies or reorders. Transient AX failures are ignored so the panel doesn't
/// flap, and the app is resolved from the Dock item's URL first (title fallback).
@MainActor
final class DockObserver {
    var onHoverApp: ((DockedApp) -> Void)?
    var onExit: (() -> Void)?

    private let systemWide = AXUIElementCreateSystemWide()
    private var timer: DispatchSourceTimer?
    private var lastPid: pid_t?

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.check() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastPid = nil
    }

    private func check() {
        let location = NSEvent.mouseLocation // AppKit coords (bottom-left origin)

        // Skip the AX probe when idle and far from the Dock — saves CPU. Keep
        // probing while a panel is up (lastPid set) so we still detect leaving.
        let nearBottom = (location.y - (NSScreen.main?.frame.minY ?? 0)) < 150
        guard nearBottom || lastPid != nil else { return }

        let point = flipToCGCoords(location)
        var elementRef: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementRef)
        guard err == .success, let element = elementRef else { return } // transient miss → keep state

        guard AX.string(element, "AXSubrole") == "AXApplicationDockItem",
              let app = resolveApp(for: element)
        else { return leave() }

        guard app.processIdentifier != lastPid else { return }
        lastPid = app.processIdentifier

        let pos = AX.point(element, "AXPosition") ?? .zero
        let size = AX.size(element, "AXSize") ?? .zero
        onHoverApp?(DockedApp(pid: app.processIdentifier,
                              name: app.localizedName ?? AX.string(element, "AXTitle") ?? "",
                              iconFrame: CGRect(origin: pos, size: size)))
    }

    private func leave() {
        guard lastPid != nil else { return }
        lastPid = nil
        onExit?()
    }

    /// Resolve the running app from the Dock item — by bundle URL first (exact),
    /// then by localized title (fallback).
    private func resolveApp(for element: AXUIElement) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if let url = AX.url(element, "AXURL") {
            let standardized = url.standardizedFileURL
            if let match = apps.first(where: { $0.bundleURL?.standardizedFileURL == standardized }) {
                return match
            }
            if let bundleID = Bundle(url: url)?.bundleIdentifier,
               let match = apps.first(where: { $0.bundleIdentifier == bundleID }) {
                return match
            }
        }
        if let name = AX.string(element, "AXTitle") {
            return apps.first { $0.activationPolicy == .regular && $0.localizedName == name }
        }
        return nil
    }
}
