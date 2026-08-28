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
    /// The hovered icon moved without the hover changing app — reported so the panel
    /// can slide with it. See `check()`.
    var onIconMove: ((CGRect) -> Void)?
    var onExit: (() -> Void)?

    private let systemWide = AXUIElementCreateSystemWide()
    private var timer: DispatchSourceTimer?
    private var lastPid: pid_t?
    private var lastIconFrame: CGRect?

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
        lastIconFrame = nil
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

        // Our own panel under the pointer is not an exit. It sits above the Dock, so
        // for the frame or two before it has caught up with a Dock still sliding up
        // it can cover the very icon being hovered — hit-testing it must not read as
        // "left the Dock" and close the card out from under the pointer.
        var elementPid: pid_t = 0
        if AXUIElementGetPid(element, &elementPid) == .success,
           elementPid == ProcessInfo.processInfo.processIdentifier { return }

        guard AX.string(element, "AXSubrole") == "AXApplicationDockItem",
              let app = resolveApp(for: element)
        else { return leave() }

        let pos = AX.point(element, "AXPosition") ?? .zero
        let size = AX.size(element, "AXSize") ?? .zero
        let iconFrame = CGRect(origin: pos, size: size)

        // Same app, new geometry. The Dock is still animating — sliding up out of
        // auto-hide, or magnifying under the pointer — and the first tick caught the
        // icon mid-flight. Report the move so the panel follows instead of staying
        // anchored to where the icon was, which is under the Dock's final position.
        guard app.processIdentifier != lastPid else {
            guard iconFrame != lastIconFrame else { return }
            lastIconFrame = iconFrame
            onIconMove?(iconFrame)
            return
        }
        lastPid = app.processIdentifier
        lastIconFrame = iconFrame

        onHoverApp?(DockedApp(pid: app.processIdentifier,
                              name: app.localizedName ?? AX.string(element, "AXTitle") ?? "",
                              iconFrame: iconFrame))
    }

    private func leave() {
        guard lastPid != nil else { return }
        lastPid = nil
        lastIconFrame = nil
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
