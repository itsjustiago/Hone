import SwiftUI

// Shared visual language, ported from Facet/Clippy/Sleepy so Screenly's menu-bar
// panel and Settings read as part of the same family. Brand colour is Screenly's teal.

// MARK: - Brand

enum Brand {
    /// Blue gradient stops — match the app icon (`make-icon.swift`).
    static let top = Color(red: 0.192, green: 0.608, blue: 1.0)    // #319BFF
    static let bottom = Color(red: 0.039, green: 0.384, blue: 0.878) // #0A62E0
    /// Solid tint for controls (toggles, selection, accents).
    static let tint = Color(red: 0.039, green: 0.518, blue: 1.0)   // #0A84FF

    static let gradient = LinearGradient(
        colors: [top, bottom], startPoint: .top, endPoint: .bottom)
}

// MARK: - App-icon squircle

/// The rounded, gradient-filled tile with a white SF Symbol — the signature
/// element that makes the menu read like a real macOS app surface.
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

// MARK: - Settings section + card

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

/// Hairline divider inset to align with row text (used between rows in a card).
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

// MARK: - Rows

/// Generic row: title (+ optional subtitle) on the left, any control on the right.
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
    }
}

/// Toggle row.
struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    var tint: Color = Brand.tint
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(tint)
        }
    }
}
