import SwiftUI
import AppKit

/// Observable settings state, mirrored from the system each time the pane appears.
final class SettingsModel: ObservableObject {
    @Published var passwordless = PrivilegedAccess.isInstalled
    @Published var autoOffMinutes = SleepController.autoOffMinutes

    func refresh() {
        passwordless = PrivilegedAccess.isInstalled
        autoOffMinutes = SleepController.autoOffMinutes
    }
}

/// Sleepy's settings, without the app-level sections (launch at login, menu-bar
/// icon, updates, version) — Hone owns those and embeds this in its own window.
struct SleepySettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Impedir sleep") {
                ToggleRow(
                    title: "Não pedir password",
                    subtitle: "Instala uma regra restrita (só pmset disablesleep). Pede admin uma vez.",
                    isOn: Binding(
                        get: { model.passwordless },
                        set: { on in
                            _ = on ? PrivilegedAccess.install() : PrivilegedAccess.uninstall()
                            model.passwordless = PrivilegedAccess.isInstalled
                        }))
                RowDivider()
                SettingsRow(
                    title: "Desligar sozinho",
                    subtitle: "O ecrã e o Mac voltam ao normal ao fim deste tempo. De tampa fechada, adormece logo."
                ) {
                    Picker("", selection: Binding(
                        get: { model.autoOffMinutes },
                        set: { model.autoOffMinutes = $0; SleepController.autoOffMinutes = $0 })) {
                        ForEach(SleepController.autoOffOptions) { Text($0.title).tag($0.minutes) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
        }
        .onAppear { model.refresh() }
    }
}
