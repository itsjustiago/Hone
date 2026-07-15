import AppKit
import SwiftUI

/// Manages the borderless curtain panels that cover every screen while the
/// keyboard is locked. One panel per screen, all driven by the same countdown
/// `state`, so multi-monitor setups stay in sync.
@MainActor
final class CleanKeyboardOverlay {
    private var panels: [NSPanel] = []

    func show(state: CleanKeyboardOverlayState, tint: Color, onUnlock: @escaping () -> Void) {
        hide()

        for screen in NSScreen.screens {
            let root = CleanKeyboardOverlayView(state: state, tint: tint, onUnlock: onUnlock)
            let hosting = NSHostingView(rootView: root)

            let panel = NSPanel(contentRect: screen.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false,
                                screen: screen)
            panel.isFloatingPanel = true
            // Above everything, including the menu bar and full-screen apps — this
            // is a lock curtain, so it uses the same level the system shield uses.
            panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.contentView = hosting
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        // Let the unlock button take clicks without the app stealing focus.
        panels.first?.makeKey()
    }

    func hide() {
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll()
    }
}
