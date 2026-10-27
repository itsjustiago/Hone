import SwiftUI
import HoneDesign

struct IslandSettingsView: View {
    @Bindable var module: IslandModule
    /// The screens connected right now. Re-read when they change (lid closed,
    /// display plugged in, display mode switched).
    @State private var screens = IslandScreens.infos()
    /// Claude Code is used on this Mac: only then the Claude section shows.
    @State private var hasClaude = ClaudeActivityReader().rootExists

    var body: some View {
        @Bindable var settings = module.settings
        let tint = module.tint
        let source = module.sourceStatus
        let shown = IslandScreens.plan(screens, choice: settings.screens).count

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

            SettingsSection(title: "Música") {
                VibeStatusLine(source.text, color: source.tone.color, wraps: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }

            if hasClaude {
                SettingsSection(title: "Claude") {
                    ToggleRow(
                        title: "Sessões do Claude",
                        subtitle: "Mostra no notch as sessões do Claude Code e os teus agentes.",
                        tint: tint,
                        isOn: $settings.showClaudeSessions
                    )
                }
            }

            SettingsSection(title: "Ecrã") {
                SettingsRow(title: "Mostrar em", subtitle: Self.subtitle(for: settings.screens)) {
                    Picker("", selection: $settings.screens) {
                        ForEach(IslandScreenChoice.allCases) { choice in
                            Text(choice.display).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
                RowDivider()
                SettingsRow(title: "Estado") {
                    Label(IslandScreens.statusText(count: shown, choice: settings.screens),
                          systemImage: shown > 0 ? "checkmark.circle.fill" : "minus.circle")
                        .font(.callout)
                        .foregroundStyle(shown > 0 ? VibeColor.success : Color.secondary)
                        .labelStyle(.titleAndIcon)
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
            screens = IslandScreens.infos()
        }
    }

    private static func subtitle(for choice: IslandScreenChoice) -> String {
        switch choice {
        case .notch: return "Só no notch do ecrã interno. Com a tampa fechada fica escondida."
        case .all: return "No notch e no topo de cada ecrã externo, colada à barra de menus. Sem nada para mostrar, desaparece."
        }
    }
}

private extension IslandSourceStatus.Tone {
    var color: Color {
        switch self {
        case .off: return VibeColor.dotOff
        case .ok: return VibeColor.success
        case .idle: return VibeColor.text4
        case .problem: return VibeColor.danger
        }
    }
}
