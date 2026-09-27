import AppKit
import SwiftUI

/// The screen colour picker (conta-gotas). Wraps the system `NSColorSampler` — a
/// magnifier loupe that lets the user pick any pixel on any display — copies the
/// sampled colour to the clipboard as `#RRGGBB` and shows a floating result toast.
///
/// Using `NSColorSampler` (rather than reimplementing the freeze/loupe machinery
/// the region overlay uses) keeps this robust across monitors and Spaces, and
/// mirrors how the annotation toolbar already leans on the system colour panel.
@MainActor
final class ColorPickerController {
    private let result = ColorResultPanel()

    /// Launch the system loupe. On selection, copy `#RRGGBB` and show the toast.
    /// The menu's recent-colours strip refreshes from `ColorHistory` when it next
    /// opens, so there's nothing to notify here.
    func pick() {
        // Get any lingering toast out of the way so it can't sit over the loupe.
        result.dismiss(animated: false)
        ScreenColorSampler.sample { [weak self] hex in
            guard let self, let hex else { return }   // nil = user cancelled (Esc)
            Self.copyToClipboard(hex)
            ColorHistory.add(hex)
            self.result.show(hex: hex)
        }
    }

    /// Re-copy a previously picked colour (from the menu's recent strip).
    func copyRecent(_ hex: String) {
        Self.copyToClipboard(hex)
        ColorHistory.add(hex)          // bump it back to the front
        result.show(hex: hex)
    }

    func dismissResult() { result.dismiss(animated: false) }

    static func copyToClipboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

// MARK: - Screen sampler

/// Thin wrapper over the system loupe (`NSColorSampler`): pick any pixel on any
/// display and get it back as `#RRGGBB`, on the main actor. Shared by the
/// stand-alone picker and the annotation toolbar's eyedropper.
enum ScreenColorSampler {
    /// Shows the loupe. `completion` gets nil when the user cancels (Esc).
    @MainActor
    static func sample(_ completion: @escaping (String?) -> Void) {
        NSColorSampler().show { picked in
            let hex = picked?.hexStringSRGB
            // The sampler delivers its handler on the main queue; assert it so the
            // main-actor completion stays synchronous and warning-free.
            MainActor.assumeIsolated { completion(hex) }
        }
    }
}

// MARK: - History

/// The last handful of picked colours, persisted in UserDefaults so they survive
/// relaunches. Most-recent first, de-duplicated, capped.
enum ColorHistory {
    private static var d: UserDefaults { ScreenlyDefaults.store }
    private static let key = "recentColors"
    private static let maxCount = 8

    static var colors: [String] { d.stringArray(forKey: key) ?? [] }

    static func add(_ hex: String) {
        var list = colors.filter { $0.caseInsensitiveCompare(hex) != .orderedSame }
        list.insert(hex.uppercased(), at: 0)
        d.set(Array(list.prefix(maxCount)), forKey: key)
    }
}

// MARK: - Colour formats

/// Turns a `#RRGGBB` string into the other representations offered by the toast.
enum ColorFormats {
    static func rgbComponents(_ hex: String) -> (r: Int, g: Int, b: Int) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        return (Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF), Int(v & 0xFF))
    }

    static func rgb(_ hex: String) -> String {
        let c = rgbComponents(hex)
        return "\(c.r), \(c.g), \(c.b)"
    }

    static func css(_ hex: String) -> String {
        let c = rgbComponents(hex)
        return "rgb(\(c.r), \(c.g), \(c.b))"
    }
}

// MARK: - Result toast

/// A small floating card shown bottom-right after a colour is picked: swatch, the
/// hex (already on the clipboard) and one-tap copy for RGB/CSS. Mirrors
/// `CapturePreview`'s panel handling so it behaves the same for a menu-bar app.
@MainActor
final class ColorResultPanel {
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

    private let size = NSSize(width: 272, height: 128)

    func show(hex: String) {
        cancelDismiss()

        // Reuse the existing panel's position if it's already up (a quick second
        // pick shouldn't make the toast jump around).
        let origin = panel?.frame.origin ?? defaultOrigin()
        panel?.orderOut(nil)

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let root = ColorResultView(
            hex: hex,
            onInteract: { [weak self] in self?.scheduleDismiss() },
            onHover: { [weak self] hovering in
                if hovering { self?.cancelDismiss() } else { self?.scheduleDismiss() }
            },
            onClose: { [weak self] in self?.dismiss(animated: true) })
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        scheduleDismiss()
    }

    private func defaultOrigin() -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return .zero }
        return NSPoint(x: vf.maxX - size.width - 20, y: vf.minY + 20)
    }

    private func scheduleDismiss() {
        cancelDismiss()
        let work = DispatchWorkItem { [weak self] in self?.dismiss(animated: true) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    private func cancelDismiss() {
        dismissWork?.cancel()
        dismissWork = nil
    }

    func dismiss(animated: Bool) {
        cancelDismiss()
        guard let panel else { return }
        self.panel = nil
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

private struct ColorResultView: View {
    let hex: String
    var onInteract: () -> Void
    var onHover: (Bool) -> Void
    var onClose: () -> Void

    private enum Format: String { case hex = "HEX", rgb = "RGB", css = "CSS" }
    /// HEX is already on the clipboard when the toast appears.
    @State private var copied: Format = .hex
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                swatch
                VStack(alignment: .leading, spacing: 2) {
                    Text(hex)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text("rgb \(ColorFormats.rgb(hex))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                copyChip(.hex, value: hex)
                copyChip(.rgb, value: ColorFormats.rgb(hex))
                copyChip(.css, value: ColorFormats.css(hex))
                Spacer(minLength: 0)
                Label("Copiado", systemImage: "checkmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(14)
        .frame(width: 272, height: 128)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .overlay(alignment: .topTrailing) { closeButton }
        .shadow(color: .black.opacity(0.30), radius: 18, y: 7)
        .contentShape(Rectangle())
        .onHover { hovering = $0; onHover($0) }
    }

    private var swatch: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color(hex: hex))
            .frame(width: 54, height: 54)
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.primary.opacity(0.15))
            )
    }

    private func copyChip(_ format: Format, value: String) -> some View {
        let active = copied == format
        return Button {
            ColorPickerController.copyToClipboard(value)
            copied = format
            onInteract()
        } label: {
            Text(format.rawValue)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Color.white : .primary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(active ? AnyShapeStyle(Brand.tint) : AnyShapeStyle(.primary.opacity(0.08)),
                            in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Copiar \(format.rawValue)")
    }

    @ViewBuilder private var closeButton: some View {
        if hovering {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .buttonStyle(.plain)
            .padding(7)
            .transition(.opacity)
        }
    }
}
