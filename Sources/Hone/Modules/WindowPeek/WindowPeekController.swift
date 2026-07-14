import AppKit

/// Ties together Dock hover detection, window enumeration, the preview panel and
/// window focusing, with hover-intent so the panel survives the trip from the
/// Dock icon to the panel itself.
@MainActor
final class WindowPeekController {
    private let dock = DockObserver()
    private let panel = WindowPeekPanel()

    private var closeTimer: Timer?
    private var mouseOverPanel = false
    private var currentPID: pid_t?

    /// Whether to capture live thumbnails (needs Screen Recording). When false or
    /// unavailable, the panel still lists windows with placeholders.
    var captureThumbnails = true

    func start() {
        dock.onHoverApp = { [weak self] app in self?.present(app) }
        dock.onExit = { [weak self] in self?.scheduleClose() }
        dock.start()
    }

    func stop() {
        dock.stop()
        closeTimer?.invalidate()
        closeTimer = nil
        panel.hide()
        currentPID = nil
        mouseOverPanel = false
    }

    private func present(_ app: DockedApp) {
        closeTimer?.invalidate()

        var windows = WindowEnumerator.windows(forPID: app.pid)
        guard !windows.isEmpty else {
            // App has no normal windows (e.g. just launched) — don't show anything.
            if currentPID != nil { panel.hide(); currentPID = nil }
            return
        }

        if captureThumbnails, Permissions.shared.isScreenRecordingTrusted {
            for i in windows.indices {
                windows[i].thumbnail = WindowEnumerator.thumbnail(for: windows[i].id)
            }
        }

        currentPID = app.pid
        panel.show(appName: app.name,
                   windows: windows,
                   near: app.iconFrame,
                   onSelect: { [weak self] window in self?.select(window) },
                   onHoverChange: { [weak self] over in self?.panelHover(over) })
    }

    private func select(_ window: WindowInfo) {
        WindowFocuser.focus(window)
        closeNow()
    }

    private func panelHover(_ over: Bool) {
        mouseOverPanel = over
        if over {
            closeTimer?.invalidate()
        } else {
            scheduleClose()
        }
    }

    private func scheduleClose() {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.mouseOverPanel else { return }
                self.closeNow()
            }
        }
    }

    private func closeNow() {
        closeTimer?.invalidate()
        closeTimer = nil
        panel.hide()
        currentPID = nil
        mouseOverPanel = false
    }
}
