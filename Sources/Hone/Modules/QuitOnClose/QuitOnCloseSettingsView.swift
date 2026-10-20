import SwiftUI
import HoneDesign

struct QuitOnCloseSettingsView: View {
    @Bindable var module: QuitOnCloseModule
    @State private var permissions = Permissions.shared

    var body: some View {
        @Bindable var settings = module.settings
        let tint = module.tint

        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Comportamento") {
                SettingsRow(
                    title: "Sair ao fechar",
                    subtitle: "Escolhe se a regra vale para todas as apps (com exceções) ou só para as que indicares."
                ) {
                    Picker("", selection: $settings.mode) {
                        ForEach(QuitOnCloseMode.allCases) { mode in
                            Text(mode.display).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                RowDivider()

                SettingsRow(
                    title: "Esperar antes de sair",
                    subtitle: "A contagem começa quando fechas a última janela. Se abrires outra antes do tempo acabar, a app fica."
                ) {
                    Picker("", selection: $settings.delaySeconds) {
                        ForEach(settings.delayChoices, id: \.self) { seconds in
                            Text(QuitOnCloseSettings.delayLabel(seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 240)
                }
            }

            SettingsSection(title: settings.mode == .allExcept ? "Exceções" : "Apps") {
                AppExceptionList(
                    bundleIDs: settings.listedBundleIDs,
                    emptyText: emptyMessage(for: settings.mode),
                    tint: tint,
                    onAdd: { settings.add($0) },
                    onRemove: { settings.remove($0) }
                )
            }

            SettingsSection(title: "Permissão") {
                SettingsRow(title: "Acessibilidade",
                            subtitle: "Necessária para contar as janelas abertas de cada app.") {
                    if permissions.isAccessibilityTrusted {
                        Label("Concedida", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(VibeColor.success)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Button("Conceder…") { permissions.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }
            }

            Label("**⌘W** conta como fechar — o macOS não distingue o atalho do clique no botão vermelho. O Hone só fecha uma app quando tem a certeza de que ficou sem janelas: minimizada, escondida, noutro Espaço ou em ecrã inteiro conta como aberta, e uma app que nunca viu com janela é deixada em paz. O **Finder** e o **Steam** nunca são fechados.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
        }
    }

    private func emptyMessage(for mode: QuitOnCloseMode) -> String {
        switch mode {
        case .allExcept:
            return "Sem exceções — todas as apps saem ao fechar a última janela."
        case .onlySelected:
            return "Nenhuma app escolhida — por agora não sai nenhuma."
        }
    }
}
