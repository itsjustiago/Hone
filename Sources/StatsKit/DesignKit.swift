import SwiftUI
import AppKit

// Minimal copy of the shared visual language (see SleepyKit/DesignKit.swift) so
// Stats' panel and Settings read as siblings of Sleepy's. Brand colour is teal.

enum Brand {
    static let top = Color(red: 0.20, green: 0.74, blue: 0.73)
    static let bottom = Color(red: 0.08, green: 0.46, blue: 0.52)
    /// Solid tint for controls (toggles, selection, accents).
    static let tint = Color(red: 0.13, green: 0.66, blue: 0.67)

    /// Teal for small text: the plain tint is too light on a light background.
    static let tintText = Color(light: NSColor(srgbRed: 0.02, green: 0.43, blue: 0.45, alpha: 1),
                                dark: NSColor(srgbRed: 0.40, green: 0.82, blue: 0.82, alpha: 1))

    static let gradient = LinearGradient(
        colors: [top, bottom], startPoint: .top, endPoint: .bottom)
}

extension Color {
    /// Resolves to `light` or `dark` according to the appearance it is drawn in.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct AppIcon: View {
    var systemName: String
    var gradient: LinearGradient = Brand.gradient
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: Brand.tint.opacity(0.35), radius: size * 0.12, y: size * 0.05)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            SettingsCard { content }
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07))
            )
    }
}

struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    var tint: Color = Brand.tint
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(tint)
        }
    }
}

/// Small circular glyph button for the panel header (back, separate/join).
struct HeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .background(hovering ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.clear),
                            in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct MenuActionLabel: View {
    let title: String
    let shortcut: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 27)
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            if !shortcut.isEmpty {
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Row button with native-menu hover highlight.
struct MenuButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering && isEnabled ? AnyShapeStyle(Brand.tint.opacity(0.16)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The system menu material (translucent vibrancy).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
