import SwiftUI
import HoneDesign

/// Soundly's settings, without the app-level sections (the switch, the menu-bar
/// icon) — Hone owns those and embeds this in its own window.
struct SoundlySettingsView: View {
    /// Puts every app back at 100 %, unmuted.
    let onResetAll: () -> Void

    @State private var didReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VibeSettingsSection(title: "Volumes") {
                VibeSettingsRow(
                    title: "Repor todas as apps a 100 %",
                    subtitle: "Volta ao som original de todas as apps, também das que não estão abertas, e tira o silêncio.") {
                    Button(didReset ? "Feito" : "Repor") {
                        onResetAll()
                        withAnimation(VibeMotion.standard) { didReset = true }
                    }
                    .buttonStyle(VibeButtonStyle())
                    .disabled(didReset)
                    .accessibilityLabel("Repor todas as apps a 100 %")
                }
            }
            Text("Ao mexer no volume de uma app pela primeira vez, o macOS pede ao Hone acesso ao áudio das apps (Gravação de ecrã e áudio do sistema). Só pede uma vez. O Hone só ajusta o volume: não guarda nem envia o áudio.")
                .font(VibeFont.settingsDetail)
                .foregroundStyle(VibeColor.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
        .task(id: didReset) {
            guard didReset else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(VibeMotion.standard) { didReset = false }
        }
    }
}
