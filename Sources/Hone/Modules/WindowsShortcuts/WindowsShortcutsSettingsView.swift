import SwiftUI
import HoneDesign

struct WindowsShortcutsSettingsView: View {
    @Bindable var module: WindowsShortcutsModule
    @State private var permissions = Permissions.shared

    var body: some View {
        @Bindable var settings = module.settings
        let tint = module.tint

        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Atalhos") {
                ToggleRow(
                    title: "Cortar e colar no Finder",
                    subtitle: "⌘X e depois ⌘V move os ficheiros, como no Windows.",
                    tint: tint,
                    isOn: $settings.finderCutPaste
                )
                RowDivider()
                ToggleRow(
                    title: "F2 muda o nome",
                    subtitle: "No Finder, F2 começa a mudar o nome do ficheiro selecionado.",
                    tint: tint,
                    isOn: $settings.f2Rename
                )
                RowDivider()
                ToggleRow(
                    title: "Botões laterais do rato",
                    subtitle: "Os botões 4 e 5 voltam atrás e avançam. O trackpad não muda.",
                    tint: tint,
                    isOn: $settings.mouseButtons
                )
                RowDivider()
                ToggleRow(
                    title: "Segurar ⌘Q para sair",
                    subtitle: "Um toque já não fecha a app. Segura ⌘Q um instante para sair.",
                    tint: tint,
                    isOn: $settings.holdToQuit
                )
            }

            if settings.holdToQuit {
                SettingsSection(title: "Exceções do ⌘Q") {
                    AppExceptionList(
                        bundleIDs: settings.quitExceptions,
                        emptyText: "Sem exceções — segurar vale em todas as apps.",
                        tint: tint,
                        onAdd: { settings.add($0) },
                        onRemove: { settings.remove($0) }
                    )
                }
            }

            SettingsSection(title: "Janelas") {
                ToggleRow(
                    title: "Encaixar janelas",
                    subtitle: "⌥ + ← → encosta a janela a um lado, ↑ maximiza, ↓ repõe ou minimiza. O ⌥ é a tecla na posição do Windows.",
                    tint: tint,
                    isOn: $settings.snapWindows
                )
                RowDivider()
                ToggleRow(
                    title: "Botão verde maximiza",
                    subtitle: "Ocupa o ecrã sem abrir o ecrã inteiro. ⌥ + clique abre o ecrã inteiro.",
                    tint: tint,
                    isOn: $settings.greenButtonMaximizes
                )
            }

            if settings.snapWindows {
                SettingsSection(title: "Exceções do encaixe") {
                    AppExceptionList(
                        bundleIDs: settings.snapExceptions,
                        emptyText: "Sem exceções — ⌥ + setas encaixa em todas as apps.",
                        tint: tint,
                        onAdd: { settings.addSnapException($0) },
                        onRemove: { settings.removeSnapException($0) }
                    )
                }
            }

            SettingsSection(title: "Permissão") {
                SettingsRow(title: "Acessibilidade",
                            subtitle: "Necessária para ler o teclado e o rato.") {
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

            Label("Com o **Comando ⇄ Controlo** ligado, ⌃X, ⌃V e ⌃Q fazem o mesmo. No teclado do Mac, o F2 pede **fn**. Firefox, VS Code, Xcode e máquinas virtuais recebem os botões do rato como estão. Nas apps das exceções e nas máquinas virtuais, ⌥ + setas fica como no Mac.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
        }
    }
}
