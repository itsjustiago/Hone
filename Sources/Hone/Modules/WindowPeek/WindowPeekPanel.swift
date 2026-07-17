import AppKit
import SwiftUI

/// A borderless, non-activating floating panel that hosts `WindowPeekView` above
/// the hovered Dock icon. Non-activating so hovering/clicking it never steals
/// focus from the app the user is switching to.
@MainActor
final class WindowPeekPanel {
    private var panel: NSPanel?

    func show(appName: String,
              windows: [WindowInfo],
              near iconFrame: CGRect,
              onSelect: @escaping (WindowInfo) -> Void,
              onHoverChange: @escaping (Bool) -> Void) {
        let root = WindowPeekView(appName: appName, windows: windows,
                                  onSelect: onSelect, onHoverChange: onHoverChange)
        let hosting = NSHostingView(rootView: root)
        hosting.layout()
        let size = hosting.fittingSize

        let panel = self.panel ?? makePanel()
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, iconFrame: iconFrame))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the SwiftUI view draws its own shadow
        // Pin to a dark HUD appearance so the frosted card and its label text stay
        // legible over ANY background. With no fixed appearance the panel follows
        // the system: over a light desktop the translucent `.regularMaterial` turns
        // light and the `.secondary` title text washes out. Forcing dark keeps the
        // glass dark and the text light — same choice as Mission Control / the macOS
        // window switcher, which are always dark regardless of wallpaper or mode.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    /// Centre the panel horizontally over the icon and sit it just above the Dock,
    /// clamped to the icon's screen. `iconFrame` is CG (top-left origin); NSPanel
    /// wants AppKit (bottom-left origin).
    private func origin(for size: CGSize, iconFrame: CGRect) -> NSPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let iconTopAppKit = primaryHeight - iconFrame.minY

        // The hosting view carries a transparent shadow inset on every side;
        // position and clamp against the visible card, not the panel frame.
        let inset = WindowPeekView.shadowInset

        var x = iconFrame.midX - size.width / 2
        let y = iconTopAppKit + 16 - inset // visible card sits 16pt above the icon

        let appKitIconCenter = NSPoint(x: iconFrame.midX, y: iconTopAppKit)
        let screen = NSScreen.screens.first { $0.frame.contains(appKitIconCenter) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8 - inset), visible.maxX - size.width - 8 + inset)
        }
        return NSPoint(x: x, y: y)
    }
}
