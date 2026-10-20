import AppKit
import SwiftUI
import HoneDesign

/// The small "hold to quit" card shown while ⌘Q is down: the app's icon and a bar
/// that fills over the hold. It must never become the key window — the ⌘Q that
/// follows goes to whatever is key, and if that were this panel it would quit Hone.
@MainActor
final class QuitHoldHUD {
    private var panel: NSPanel?

    func show(icon: NSImage?, duration: TimeInterval, tint: Color) {
        hide()

        // A fresh hosting view each time, so the bar starts from empty.
        let hosting = NSHostingView(rootView: QuitHoldHUDView(icon: icon, duration: duration, tint: tint))
        hosting.layout()
        let size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
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
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))
        panel.orderFrontRegardless() // never makeKey: see the type's note

        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Centred on the screen the pointer is on, a fifth of the way up (about 22% of
    /// the visible height from the bottom).
    private func origin(for size: CGSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return .zero }
        return NSPoint(x: frame.midX - size.width / 2,
                       y: frame.minY + frame.height * 0.22)
    }
}

private struct QuitHoldHUDView: View {
    let icon: NSImage?
    let duration: TimeInterval
    let tint: Color

    @State private var progress: CGFloat = 0

    private let barWidth: CGFloat = 160

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: VibeRadius.settingsCard, style: .continuous)

        HStack(spacing: 12) {
            appIcon
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 7) {
                Text("Segura para sair")
                    .font(VibeFont.action)
                    .foregroundStyle(VibeColor.text1)

                ZStack(alignment: .leading) {
                    Capsule().fill(VibeColor.track)
                    Capsule().fill(tint)
                        .frame(width: barWidth * progress)
                }
                .frame(width: barWidth, height: 6)
            }
        }
        .padding(VibeSpacing.cardPadding)
        .background(VibeColor.card, in: shape)
        .overlay(shape.strokeBorder(VibeColor.cardBorder, lineWidth: 1))
        .onAppear {
            withAnimation(.linear(duration: duration)) { progress = 1 }
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(VibeColor.text3)
        }
    }
}
