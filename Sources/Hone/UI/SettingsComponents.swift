import SwiftUI

// MARK: - Module icon (app-icon style squircle)

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
                    .foregroundStyle(.white)
            )
            .shadow(color: tint.opacity(0.3), radius: size * 0.12, y: size * 0.05)
    }
}

// MARK: - Section (label + card)

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

/// A hairline divider inset to align with row text (used between rows in a card).
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
    let tint: Color
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

/// Slider row with a live value caption under the title.
struct SliderRow: View {
    let title: String
    let valueLabel: String
    let tint: Color
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(valueLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Slider(value: $value, in: range)
                .tint(tint)
                .frame(width: 190)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
