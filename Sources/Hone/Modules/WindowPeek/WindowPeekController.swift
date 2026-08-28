import AppKit

/// Ties together Dock hover detection, window enumeration, the preview panel and
/// window focusing, with hover-intent so the panel survives the trip from the
/// Dock icon to the panel itself.
@MainActor
final class WindowPeekController {
    private let dock = DockObserver()
    private let panel = WindowPeekPanel()

    private var closeTimer: Timer?
    /// What the panel is currently showing, kept so a window closed from a card
    /// can be dropped and the rest re-drawn without enumerating (and re-capturing)
    /// everything again.
    private var current: (app: DockedApp, windows: [WindowInfo])?

    /// Whether to capture live thumbnails (needs Screen Recording). When false or
    /// unavailable, the panel still lists windows with placeholders.
    var captureThumbnails = true

    func start() {
        dock.onHoverApp = { [weak self] app in self?.present(app) }
        dock.onIconMove = { [weak self] iconFrame in self?.follow(iconFrame) }
        dock.onExit = { [weak self] in self?.scheduleClose() }
        dock.start()
    }

    func stop() {
        dock.stop()
        closeTimer?.invalidate()
        closeTimer = nil
        panel.hide()
        current = nil
    }

    private func present(_ app: DockedApp) {
        closeTimer?.invalidate()

        var windows = WindowEnumerator.windows(forPID: app.pid)
        guard !windows.isEmpty else {
            // App has no normal windows (e.g. just launched) — don't show anything.
            if current != nil { panel.hide(); current = nil }
            return
        }

        if captureThumbnails, Permissions.shared.isScreenRecordingTrusted {
            for i in windows.indices {
                windows[i].thumbnail = WindowEnumerator.thumbnail(for: windows[i].id)
            }
        }

        draw(app: app, windows: windows)
    }

    private func draw(app: DockedApp, windows: [WindowInfo]) {
        current = (app, windows)
        panel.show(appName: app.name,
                   windows: windows,
                   near: app.iconFrame,
                   onSelect: { [weak self] window in self?.select(window) },
                   onClose: { [weak self] window in self?.close(window) },
                   onHoverChange: { [weak self] over in self?.panelHover(over) })
    }

    /// The hovered icon moved under the pointer — an auto-hidden Dock still sliding
    /// up, or magnification — so slide the card with it. The card that is already up
    /// only gets a new origin: no re-enumeration, and no re-captured thumbnails
    /// (which would blink the screen-recording indicator for a pure move).
    private func follow(_ iconFrame: CGRect) {
        guard current != nil else { return }
        current?.app.iconFrame = iconFrame
        panel.reposition(near: iconFrame)
    }

    private func select(_ window: WindowInfo) {
        WindowFocuser.focus(window)
        closeNow()
    }

    /// A card's X — close that window and re-draw the row without it, so several
    /// can go in a row. The card is dropped from the list we already have rather
    /// than re-enumerating: a just-closed window lingers in the window list for a
    /// moment, and a fresh pass would also re-capture every thumbnail (blinking
    /// the screen-recording indicator) for a change we already know about.
    private func close(_ window: WindowInfo) {
        guard let (app, windows) = current, WindowCloser.close(window) else { return }

        let remaining = windows.filter { $0.id != window.id }
        // Closed the app's last window — there is nothing left to peek at.
        guard !remaining.isEmpty else {
            closeNow()
            return
        }
        draw(app: app, windows: remaining)
        // The row just got narrower under the pointer, which may now be outside it.
        // Re-check rather than trust the swapped-out view's hover reporting: the
        // timer only closes the panel if the pointer really has left it.
        scheduleClose()
    }

    private func panelHover(_ over: Bool) {
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
                guard let self, !self.panel.containsMouse else { return }
                self.closeNow()
            }
        }
    }

    private func closeNow() {
        closeTimer?.invalidate()
        closeTimer = nil
        panel.hide()
        current = nil
    }
}
