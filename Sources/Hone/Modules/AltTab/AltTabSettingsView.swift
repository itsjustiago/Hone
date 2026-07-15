import SwiftUI

struct AltTabSettingsView: View {
    @Bindable var module: AltTabModule
    @State private var permissions = Permissions.shared

    var body: some View {
        @Bindable var settings = module.settings
        let tint = module.tint

        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Atalho") {
                SettingsRow(title: "Tecla de ativação",
                            subtitle: "Mantém-na premida e carrega em Tab para percorrer. Shift-Tab volta atrás.") {
                    Picker("", selection: $settings.modifier) {
                        ForEach(AltTabModifier.allCases) { mod in
                            Text(mod.display).tag(mod)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .onChange(of: settings.modifier) { _, _ in module.reloadModifier() }
                }
                if settings.modifier == .command {
                    RowDivider()
                    Label("⌘ Command coexiste com o alternador de apps do sistema — se preferires substituí-lo, mantém o Hone e testa o comportamento.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }

            SettingsSection(title: "Pré-visualizações") {
                ToggleRow(
                    title: "Miniaturas das janelas ao vivo",
                    subtitle: "Captura uma imagem de cada janela. Precisa de Gravação de Ecrã — sem ela, mostra o ícone da app.",
                    tint: tint,
                    isOn: $settings.showThumbnails
                )
                RowDivider()
                ToggleRow(
                    title: "Incluir janelas minimizadas",
                    subtitle: "Também lista as janelas escondidas no Dock.",
                    tint: tint,
                    isOn: $settings.includeMinimized
                )
            }

            SettingsSection(title: "Permissões") {
                SettingsRow(title: "Acessibilidade", subtitle: "Ler as janelas e trazê-las para a frente.") {
                    permissionControl(granted: permissions.isAccessibilityTrusted) {
                        permissions.openAccessibilitySettings()
                    }
                }
                RowDivider()
                SettingsRow(title: "Gravação de Ecrã", subtitle: "Miniaturas das janelas ao vivo.") {
                    permissionControl(granted: permissions.isScreenRecordingTrusted) {
                        permissions.requestScreenRecording()
                    }
                }
            }

            Label("Mantém **\(settings.modifier.symbol)** e carrega em **Tab** para abrir o alternador. Setas ajustam a seleção, **Enter** confirma e **Esc** cancela.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
        }
    }

    @ViewBuilder
    private func permissionControl(granted: Bool, action: @escaping () -> Void) -> some View {
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
