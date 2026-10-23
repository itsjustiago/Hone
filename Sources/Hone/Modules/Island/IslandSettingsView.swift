import SwiftUI
import HoneDesign

struct IslandSettingsView: View {
    @Bindable var module: IslandModule
    /// Whether the built-in screen has a notch to draw on right now. Re-read when
    /// the screens change (lid closed, display mode switched).
    @State private var hasNotch = NotchGeometry.current() != nil

    var body: some View {
        @Bindable var settings = module.settings
        let tint = module.tint

        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Comportamento") {
                ToggleRow(
                    title: "Abrir ao passar o rato",
                    subtitle: "Desligado, abre só com um clique no notch.",
                    tint: tint,
                    isOn: $settings.openOnHover
                )
                RowDivider()
                ToggleRow(
                    title: "Mostrar a música nova",
                    subtitle: "Ao mudar de faixa, mostra o título uns segundos.",
                    tint: tint,
                    isOn: $settings.peekOnTrackChange
                )
            }

            SettingsSection(title: "Ecrã") {
                SettingsRow(
                    title: "Notch",
                    subtitle: hasNotch
                        ? "A ilha aparece no notch do ecrã interno."
                        : "Só aparece no ecrã interno de um MacBook com notch. Com a tampa fechada fica escondida."
                ) {
                    if hasNotch {
                        Label("À vista", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(VibeColor.success)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Label("Sem notch", systemImage: "minus.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }

            Label("A música vem do macOS, de qualquer app (Música, Spotify, YouTube no browser). Não pede permissões nem grava o ecrã.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasNotch = NotchGeometry.current() != nil
        }
    }
}
