import SwiftUI

struct WindowPeekSettingsView: View {
    @Bindable var module: WindowPeekModule
    @State private var permissions = Permissions.shared

    var body: some View {
        let tint = module.tint

        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Pré-visualizações") {
                ToggleRow(
                    title: "Miniaturas das janelas ao vivo",
                    subtitle: "Captura uma imagem de cada janela. Precisa de Gravação de Ecrã — sem ela, mostra só os títulos.",
                    tint: tint,
                    isOn: $module.showThumbnails
                )
            }

            SettingsSection(title: "Permissões") {
                PermissionStatusRow(
                    title: "Acessibilidade",
                    subtitle: "Ler o Dock e focar janelas.",
                    granted: permissions.isAccessibilityTrusted,
                    action: { permissions.openAccessibilitySettings() }
                )
                RowDivider()
                PermissionStatusRow(
                    title: "Gravação de Ecrã",
                    subtitle: "Miniaturas das janelas ao vivo.",
                    granted: permissions.isScreenRecordingTrusted,
                    action: { permissions.requestScreenRecording() }
                )
            }

            Label("Passa o rato sobre um ícone no Dock para ver as janelas dessa app e clica para focar.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
        }
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let subtitle: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            if granted {
                Label("Concedida", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Conceder…", action: action)
                    .controlSize(.small)
            }
        }
    }
}
