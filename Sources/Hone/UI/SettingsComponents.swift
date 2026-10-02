import SwiftUI
import HoneDesign

// MARK: - Module icon (app-icon style squircle)

/// Only the keyboard-lock overlay still wears it; Settings and the home use the mascot.
struct ModuleIcon: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    // Dark glyph on light tool colours (white, yellow).
                    .foregroundStyle(tint.vibeInk)
            )
            .overlay(
                // A light tile needs an edge to stand off a light background.
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.black.opacity(tint.vibeIsLight ? 0.12 : 0), lineWidth: 0.5)
            )
            .shadow(color: tint.opacity(0.3), radius: size * 0.12, y: size * 0.05)
    }
}

// MARK: - Section, card and rows (forward to HoneDesign)

// Hone's pages and the Kits' pages share one look; these keep the names the
// pages already use and hand the drawing to `HoneDesign`.

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View { VibeSettingsSection(title: title) { content } }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View { VibeSettingsCard { content } }
}

/// A hairline divider inset to align with row text (used between rows in a card).
struct RowDivider: View {
    var body: some View { VibeRowDivider() }
}

/// Generic row: title (+ optional subtitle) on the left, any control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View { VibeSettingsRow(title: title, subtitle: subtitle) { trailing } }
}

/// Toggle row.
struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    let tint: Color
    @Binding var isOn: Bool

    var body: some View { VibeToggleRow(title: title, subtitle: subtitle, tint: tint, isOn: $isOn) }
}

/// Slider row with a live value caption under the title.
struct SliderRow: View {
    let title: String
    let valueLabel: String
    let tint: Color
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VibeSettingsRow(title: title, subtitle: valueLabel) {
            Slider(value: $value, in: range)
                .tint(tint.vibeControlTint)
                .frame(width: 190)
        }
    }
}
