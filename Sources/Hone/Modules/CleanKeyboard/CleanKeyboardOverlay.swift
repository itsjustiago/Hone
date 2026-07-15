import AppKit
import SwiftUI

/// Shows the small "keyboard locked" card near the top of the active screen while
/// the lock is engaged. Just the card — the rest of the screen stays visible and
/// untouched.
@MainActor
final class CleanKeyboardOverlay {
    private var panel: NSPanel?

    func show(tint: Color, onUnlock: @escaping () -> Void) {
        hide()

        let root = CleanKeyboardOverlayView(tint: tint, onUnlock: onUnlock)
        let hosting = NSHostingView(rootView: root)
        hosting.layout()
        let size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        // High enough to stay visible over normal and full-screen apps, without
        // covering anything — it's a small card, not a curtain.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the card draws its own shadow
        panel.ignoresMouseEvents = false
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.setFrameOrigin(centerOrigin(for: size))
        panel.orderFrontRegardless()
        panel.makeKey() // let the unlock button take clicks without activating the app

        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Dead-centre the card on the active screen. (The card's own transparent
    /// margin already reserves room for its shadow, so this centres the visible
    /// card too.)
    private func centerOrigin(for size: CGSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.frame else { return .zero }
        let x = frame.midX - size.width / 2
        let y = frame.midY - size.height / 2
        return NSPoint(x: x, y: y)
    }
}
