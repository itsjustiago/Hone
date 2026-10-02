import SwiftUI
import AppKit

// Minimal copy of the shared visual language (see SleepyKit/DesignKit.swift) so
// Stats' Settings read as siblings of Sleepy's. Brand colour is teal.

enum Brand {
    /// Solid tint for controls (toggles, selection, accents).
    static let tint = Color(red: 0.13, green: 0.66, blue: 0.67)
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
