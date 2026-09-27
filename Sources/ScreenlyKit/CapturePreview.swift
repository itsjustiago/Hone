import AppKit
import SwiftUI

/// A small floating thumbnail shown bottom-right after each capture — instant
/// visual confirmation. Click to reveal the file in Finder; auto-dismisses.
final class CapturePreview {
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

    private let size = NSSize(width: 240, height: 168)

    func show(image: NSImage, reveal: URL?) {
        dismiss(animated: false)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // NSPanel hides itself on app deactivation by default — for a menu-bar app
        // that's "almost immediately", which killed the toast the moment the user
        // clicked back into their work. Keep it up for its full 4 seconds.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let root = CapturePreviewView(
            image: image,
            onReveal: { [weak self] in
                if let reveal { NSWorkspace.shared.activateFileViewerSelecting([reveal]) }
                self?.dismiss(animated: true)
            },
            onClose: { [weak self] in self?.dismiss(animated: true) })
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        // Anchor to the bottom-right of the screen under the cursor (falls back to main).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 20, y: vf.minY + 20))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.dismiss(animated: true) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    func dismiss(animated: Bool) {
        dismissWork?.cancel()
        dismissWork = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

private struct CapturePreviewView: View {
    let image: NSImage
    var onReveal: () -> Void
    var onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onReveal) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 240, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.18))
                    )
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 7)
            }
            .buttonStyle(.plain)
            .help("Mostrar no Finder")

            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(8)
                .transition(.opacity)
            }
        }
        .frame(width: 240, height: 168)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}
