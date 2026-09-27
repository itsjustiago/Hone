import SwiftUI
import AppKit

/// The floating annotation toolbar: tools, colours, fill, stroke width, undo and
/// the export actions. Shared by the region overlay and the editor window.
struct AnnotationToolbar: View {
    @ObservedObject var model: AnnotationModel
    var onCopy: () -> Void
    var onSave: () -> Void
    var onCancel: () -> Void
    /// True when hosted in the shield-level capture overlay, so the system colour
    /// panel is raised above it.
    var elevatedColorPanel: Bool = false
    /// How the controls are arranged. `.bar` is the single horizontal row used in
    /// the editor window's bottom bar; `.stacked` is the compact multi-row card
    /// that floats over the region-selection overlay (narrower, so it stays on
    /// screen next to edge selections).
    var layout: Layout = .bar

    enum Layout { case bar, stacked }

    private let widths: [(CGFloat, CGFloat)] = [(3, 6), (6, 9), (11, 13)]  // (lineWidth, dotSize)

    var body: some View {
        switch layout {
        case .bar: barBody
        case .stacked: stackedBody
        }
    }

    /// One horizontal row inside a capsule — the editor window's bottom bar.
    private var barBody: some View {
        HStack(spacing: 12) {
            tools
            divider
            colors
            divider
            styleGroup
            divider
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.30), radius: 18, y: 7)
        .fixedSize()
    }

    /// Compact multi-row card: tools, then colours + style, then the actions.
    /// Much narrower than the bar, so the overlay can keep it fully on-screen.
    private var stackedBody: some View {
        VStack(spacing: 10) {
            tools
            HStack(spacing: 11) {
                colors
                divider
                styleGroup
            }
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.30), radius: 18, y: 7)
        .fixedSize()
    }

    // MARK: Tools

    private var tools: some View {
        HStack(spacing: 3) {
            ForEach(AnnotationTool.allCases) { tool in
                iconToggle(tool.systemImage, active: model.tool == tool, help: tool.label) {
                    model.tool = tool
                }
            }
        }
    }

    // MARK: Colours

    private var colors: some View {
        HStack(spacing: 7) {
            ForEach(AnnotationPalette.colors, id: \.self) { hex in
                Button { pick(hex) } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.white.opacity(hex == "#FFFFFF" ? 0.5 : 0.22)))
                        .overlay(
                            Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-3)
                                .opacity(isSelected(hex) ? 1 : 0)
                        )
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            eyedropper
            customColorWell
        }
    }

    /// One-click screen eyedropper: opens the system loupe straight away and the
    /// picked pixel becomes the annotation colour — no colour panel in between.
    /// Keeps the preset palette short: anything else is picked off the screen.
    private var eyedropper: some View {
        Button {
            model.isSampling = true
            ScreenColorSampler.sample { hex in
                model.isSampling = false
                guard let hex else { return }   // cancelled
                pick(hex)
            }
        } label: {
            Image(systemName: "eyedropper")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Conta-gotas — escolher cor do ecrã")
    }

    /// Opens the system colour panel (with eyedropper) for a custom colour.
    private var customColorWell: some View {
        let isCustom = !AnnotationPalette.colors.contains { isSelected($0) }
        return Button {
            ColorPanelController.shared.present(current: model.colorHex, elevated: elevatedColorPanel) { hex in
                model.colorHex = hex
                if model.selectedID != nil { model.recolorSelected(hex) }
            }
        } label: {
            ZStack {
                Circle().fill(Color(hex: model.colorHex)).frame(width: 16, height: 16)
                Circle()
                    .strokeBorder(
                        AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center),
                        lineWidth: 2.5)
                    .frame(width: 19, height: 19)
                Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-4)
                    .frame(width: 19, height: 19)
                    .opacity(isCustom ? 1 : 0)
            }
            .padding(3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Cor personalizada… (com conta-gotas)")
    }

    // MARK: Fill + width

    private var styleGroup: some View {
        HStack(spacing: 8) {
            iconToggle(model.filled ? "square.fill" : "square", active: model.filled,
                       help: "Preencher formas (tapar conteúdo)") {
                model.filled.toggle()
            }
            HStack(spacing: 3) {
                ForEach(widths, id: \.0) { w, dot in
                    Button { model.lineWidth = w } label: {
                        Circle()
                            .fill(model.lineWidth == w ? Color.primary : Color.secondary)
                            .frame(width: dot, height: dot)
                            .frame(width: 24, height: 26)
                            .background(model.lineWidth == w ? AnyShapeStyle(.primary.opacity(0.10)) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Espessura")
                }
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            iconButton("arrow.uturn.backward", help: "Anular (⌘Z)", enabled: model.canUndo) { model.undo() }
            iconButton("xmark", help: "Cancelar (Esc)", enabled: true, action: onCancel)
            Button(action: onCopy) {
                Label("Copiar", systemImage: "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 11).frame(height: 28)
                    .background(.primary.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Copiar para o clipboard (⌘C)")

            Button(action: onSave) {
                Label("Guardar", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13).frame(height: 28)
                    .background(Brand.tint, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Guardar em ficheiro (⌘S)")
        }
    }

    // MARK: Building blocks

    private func iconToggle(_ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 28)
                .foregroundStyle(active ? Color.white : .primary)
                .background(active ? AnyShapeStyle(Brand.tint) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 28)
                .opacity(enabled ? 1 : 0.35)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func pick(_ hex: String) {
        model.colorHex = hex
        if model.selectedID != nil { model.recolorSelected(hex) }
    }

    private func isSelected(_ hex: String) -> Bool {
        model.colorHex.caseInsensitiveCompare(hex) == .orderedSame
    }

    private var divider: some View {
        Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 22)
    }
}

/// Bridges the shared `NSColorPanel` to the annotation model. Raises the panel
/// above the shield-level capture overlay so it's actually usable there, and
/// gives us the system eyedropper for picking colours off the screenshot.
final class ColorPanelController: NSObject {
    static let shared = ColorPanelController()
    private var onChange: ((String) -> Void)?

    func present(current hex: String, elevated: Bool, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(Color(hex: hex))
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.level = elevated
            ? NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            : .floating
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.level = .normal
        panel.orderOut(nil)
        onChange = nil
    }

    @objc private func changed(_ sender: NSColorPanel) {
        onChange?(sender.color.hexStringSRGB)
    }
}

extension NSColor {
    /// #RRGGBB from an sRGB conversion of this colour.
    var hexStringSRGB: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
