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
              onClose: @escaping (AltTabEntry) -> Void,
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
                              onPick: onPick, onHover: gatedHover,
                              onClose: onClose, onCancel: onCancel)

        // Re-point the panel that already exists rather than building another one.
        // A fresh NSPanel per summon never went away — AppKit holds every window it
        // is given until it is closed — so each ⌥-Tab left behind a hosting view
        // still observing the selection and still re-laying itself out on every
        // Tab. That is what made the switcher slower the longer Hone had been up.
        let panel = self.panel ?? makePanel()
        if let hosting = panel.contentView as? NSHostingView<AltTabView> {
            hosting.rootView = root
        } else {
            panel.contentView = NSHostingView(rootView: root)
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panel.makeKey() // take tile clicks without activating Hone

        self.panel = panel
    }

    func hide() {
        if let m = moveMonitorLocal { NSEvent.removeMonitor(m); moveMonitorLocal = nil }
        if let m = moveMonitorGlobal { NSEvent.removeMonitor(m); moveMonitorGlobal = nil }
        // Kept, not torn down: the panel and its hosting view are what make the
        // next summon instant. The controller empties the selection, so nothing is
        // drawn while it waits off-screen.
        panel?.orderOut(nil)
    }

    /// Build the panel and its hosting view ahead of the first ⌥-Tab. The first
    /// SwiftUI render of the grid costs an order of magnitude more than the ones
    /// after it, and this moves that cost to Hone's launch, where nobody is
    /// waiting on a keystroke.
    func prewarm(selection: AltTabSelection, tint: Color) {
        guard panel == nil else { return }
        let panel = makePanel()
        panel.contentView = NSHostingView(rootView: AltTabView(selection: selection, tint: tint))
        panel.contentView?.layoutSubtreeIfNeeded()
        self.panel = panel
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSScreen.main?.frame ?? .zero,
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
        return panel
    }

    /// The module was switched off — let the panel go for real.
    func teardown() {
        hide()
        panel?.close()
        panel = nil
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}
