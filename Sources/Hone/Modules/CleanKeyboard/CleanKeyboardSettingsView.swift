import SwiftUI

struct CleanKeyboardSettingsView: View {
    @Bindable var module: CleanKeyboardModule
    @State private var permissions = Permissions.shared

    var body: some View {
        @Bindable var settings = module.settings
        let tint = module.tint

        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Desbloqueio automático") {
                SliderRow(title: "Duração do bloqueio",
                          valueLabel: durationLabel,
                          tint: tint,
                          value: $settings.duration, range: 10...120)
            }

            SettingsSection(title: "Teclas") {
                ToggleRow(
                    title: "Bloquear teclas de função e multimédia",
                    subtitle: "Também desativa brilho, volume e play/pause — úteis de bloquear ao limpar a fila de cima.",
                    tint: tint,
                    isOn: $settings.blockFunctionKeys
                )
            }

            SettingsSection(title: "Permissão") {
                SettingsRow(title: "Acessibilidade",
                            subtitle: "Necessária para desativar as teclas.") {
                    if permissions.isAccessibilityTrusted {
                        Label("Concedida", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Button("Conceder…") { permissions.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }
            }

            Label("Enquanto está bloqueado, desbloqueia carregando **Esc** três vezes, clicando em **Desbloquear**, ou esperando pelo fim da contagem.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
        }
    }

    private var durationLabel: String {
        "\(Int(module.settings.duration)) segundos"
    }
}
