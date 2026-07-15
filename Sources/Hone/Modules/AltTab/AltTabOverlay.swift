import AppKit
import SwiftUI

/// Hosts `AltTabView` in a borderless, non-activating, full-screen panel. It sits
/// above normal and full-screen apps and ignores the mouse — the switcher is
/// keyboard-driven, and staying non-activating means focus never leaves the app
/// we're about to raise via the Accessibility API.
@MainActor
final class AltTabOverlay {
    private var panel: NSPanel?

    func show(selection: AltTabSelection, tint: Color) {
        hide()

        let screen = screenUnderMouse()
        let frame = screen?.frame ?? NSScreen.main?.frame ?? .zero

        let hosting = NSHostingView(rootView: AltTabView(selection: selection, tint: tint))
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}
