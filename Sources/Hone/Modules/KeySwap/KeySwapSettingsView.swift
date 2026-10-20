import SwiftUI
import HoneDesign

struct KeySwapSettingsView: View {
    @Bindable var module: KeySwapModule
    @State private var permissions = Permissions.shared

    var body: some View {
        @Bindable var settings = module.settings
        let tint = module.tint

        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Exceções") {
                AppExceptionList(
                    bundleIDs: settings.exceptions,
                    emptyText: "Sem exceções — a troca vale em todas as apps.",
                    tint: tint,
                    onAdd: { settings.add($0) },
                    onRemove: { settings.remove($0) }
                )
            }

            SettingsSection(title: "Permissão") {
                SettingsRow(title: "Acessibilidade",
                            subtitle: "Necessária para reescrever os eventos de teclado.") {
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

            Label("A troca vale para as teclas **esquerda e direita**, nos dois sentidos. O **Tab nunca é trocado**: ⌘Tab continua a ser o alternador de apps (o Alt-Tab) e ⌃Tab continua a mudar de separador, como no Windows. O rato não é tocado: **⌃+clique continua a ser o clique-direito** do macOS. Em campos de palavra-passe com *secure input* o macOS bloqueia qualquer app de ler o teclado, por isso a troca fica suspensa enquanto lá escreves.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
        }
    }
}
