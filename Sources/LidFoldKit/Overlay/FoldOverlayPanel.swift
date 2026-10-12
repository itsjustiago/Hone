// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import AppKit
import MetalKit

/// The window that carries the fold over the built-in display. It must never take
/// focus, clicks or a Space of its own, and it must stay out of screenshots and
/// recordings (the capture excludes the app too; this is the second line).
final class FoldOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Above the menu bar and its extras, so the whole display folds as one.
    static var overlayLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
    }
}

/// A panel with its Metal view and renderer already wired together. The panel is
/// created hidden: nothing here orders it onto the screen.
struct FoldOverlay {
    let panel: FoldOverlayPanel
    let view: MTKView
    let renderer: FoldRenderer

    /// Nil when Metal or the shader is unavailable on this Mac.
    @MainActor
    static func make(frame: NSRect, screen: NSScreen? = nil) -> FoldOverlay? {
        guard let renderer = FoldRenderer.makeDefault() else { return nil }
        let panel = FoldOverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false, screen: screen)
        panel.level = FoldOverlayPanel.overlayLevel
        // Not opaque with a clear background: the Fade draws black with its own
        // alpha, and the MTKView is transparent to let that through.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.sharingType = .none
        panel.setFrame(frame, display: false)

        let view = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: renderer.device)
        renderer.configure(view)
        view.isPaused = true // the controller starts drawing once the panel is shown
        panel.contentView = view
        return FoldOverlay(panel: panel, view: view, renderer: renderer)
    }

    /// Drops every reference between the pieces and closes the window, so nothing
    /// outlives the session (no retained drawables, no callbacks into the owner).
    @MainActor
    func tearDown() {
        view.isPaused = true
        view.delegate = nil
        renderer.frames = nil
        renderer.animatedState = nil
        renderer.onPresented = nil
        renderer.onFailure = nil
        renderer.parameters = { FoldUniforms() }
        renderer.releaseTransientResources()
        view.releaseDrawables()
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }
}
