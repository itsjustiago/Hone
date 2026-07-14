import SwiftUI

struct ScrollSettingsView: View {
    @Bindable var module: ScrollModule

    var body: some View {
        @Bindable var settings = module.settings
        let tint = module.tint

        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Direção") {
                ToggleRow(
                    title: "Inverter direção do rato",
                    subtitle: "Devolve a roda do rato ao scroll clássico, sem mexer na direção natural do trackpad.",
                    tint: tint,
                    isOn: $settings.reverseMouse
                )
            }

            SettingsSection(title: "Scroll suave") {
                ToggleRow(
                    title: "Ativar scroll suave",
                    subtitle: "Transforma cada clique da roda num deslize suave.",
                    tint: tint,
                    isOn: $settings.smoothEnabled
                )
                if settings.smoothEnabled {
                    RowDivider()
                    SliderRow(title: "Velocidade",
                              valueLabel: "\(Int(settings.step)) px por clique",
                              tint: tint,
                              value: $settings.step, range: 10...200)
                    RowDivider()
                    SliderRow(title: "Suavidade",
                              valueLabel: smoothnessLabel,
                              tint: tint,
                              value: $settings.smoothness, range: 0...1)
                    RowDivider()
                    ToggleRow(
                        title: "Aceleração",
                        subtitle: "Rodar a roda depressa percorre mais distância.",
                        tint: tint,
                        isOn: $settings.acceleration
                    )
                }
            }

            Label("Só afeta a roda de um rato físico. Trackpad e Magic Mouse ficam intactos.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
        }
    }

    private var smoothnessLabel: String {
        switch module.settings.smoothness {
        case ..<0.25: return "Direto"
        case ..<0.55: return "Equilibrado"
        case ..<0.8: return "Suave"
        default: return "Flutuante"
        }
    }
}
