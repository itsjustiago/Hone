import SwiftUI
import HoneDesign

// Sleepy's Settings components, drawn by `HoneDesign` so its page reads as part of
// Hone's Settings. The names stay as the settings view uses them.

enum Brand {
    /// Sleepy's colour in Hone: the mascot and the switches on its page.
    static let tint = VibeToolColor.sleepy
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View { VibeSettingsSection(title: title) { content } }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View { VibeSettingsCard { content } }
}

/// Hairline divider inset to align with row text (used between rows in a card).
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
    var tint: Color = Brand.tint
    @Binding var isOn: Bool

    var body: some View { VibeToggleRow(title: title, subtitle: subtitle, tint: tint, isOn: $isOn) }
}
