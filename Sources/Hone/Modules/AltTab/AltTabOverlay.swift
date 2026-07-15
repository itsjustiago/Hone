import AppKit
import SwiftUI

/// Hosts `AltTabView` in a borderless, non-activating, full-screen panel. It sits
/// above normal and full-screen apps and takes the mouse so a window can be
/// hovered and clicked — while staying non-activating, so focus never leaves the
/// app we're about to raise via the Accessibility API.
@MainActor
final class AltTabOverlay {
    private var panel: NSPanel?

    /// Hover only moves the highlight once the mouse has actually moved, so a
    /// cursor left resting over the grid can't hijack the keyboard's starting
    /// selection (which is the whole point of a quick ⌥-Tab-and-release).
    private var mouseMoved = false
    private var moveMonitorLocal: Any?
    private var moveMonitorGlobal: Any?

    func show(selection: AltTabSelection,
              tint: Color,
              onHover: @escaping (Int) -> Void,
              onPick: @escaping (AltTabEntry) -> Void,
              onCancel: @escaping () -> Void) {
        hide()

        let screen = screenUnderMouse()
        let frame = screen?.frame ?? NSScreen.main?.frame ?? .zero

        // Gate hover behind real mouse movement.
        mouseMoved = false
        let gatedHover: (Int) -> Void = { [weak self] index in
            guard self?.mouseMoved == true else { return }
            onHover(index)
        }
        let markMoved: () -> Void = { [weak self] in self?.mouseMoved = true }
        moveMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            markMoved()
            return event
        }
        moveMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
            markMoved()
        }

        let root = AltTabView(selection: selection, tint: tint,
                              onPick: onPick, onHover: gatedHover, onCancel: onCancel)
        let hosting = NSHostingView(rootView: root)

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
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panel.makeKey() // take tile clicks without activating Hone

        self.panel = panel
    }

    func hide() {
        if let m = moveMonitorLocal { NSEvent.removeMonitor(m); moveMonitorLocal = nil }
        if let m = moveMonitorGlobal { NSEvent.removeMonitor(m); moveMonitorGlobal = nil }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}
