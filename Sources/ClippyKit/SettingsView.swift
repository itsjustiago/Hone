import SwiftUI
import AppKit
import Carbon.HIToolbox

final class SettingsModel: ObservableObject {
    @Published var shortcutDisplay = Shortcut.display
    @Published var recording = false
    @Published var preserveFocus = PanelController.preserveFocus
}

/// Drives Clippy's settings: recording the global shortcut and the panel's
/// behaviour. There's no window — Hone embeds `SettingsView` in its own.
final class SettingsController {
    let model = SettingsModel()
    private var recordMonitor: Any?

    /// Called when the shortcut changes so the tool can re-register the hotkey.
    var onShortcutChanged: (() -> Void)?

    /// Refreshes the model from the stored values.
    func refresh() {
        model.shortcutDisplay = Shortcut.display
        model.preserveFocus = PanelController.preserveFocus
    }

    func makeView() -> SettingsView {
        refresh()
        return SettingsView(
            model: model,
            startRecording: { [weak self] in self?.startRecording() },
            resetShortcut: { [weak self] in self?.resetShortcut() },
            setPreserveFocus: { PanelController.preserveFocus = $0 },
            onDisappear: { [weak self] in self?.stopRecording() })
    }

    private func startRecording() {
        guard recordMonitor == nil else { return }
        model.recording = true
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if Int(event.keyCode) == kVK_Escape && mods.isEmpty {
                self.stopRecording()
                return nil
            }
            guard !mods.isEmpty else {
                NSSound.beep()
                return nil
            }
            let display = Shortcut.displayString(keyCode: Int(event.keyCode),
                                                 modifiers: mods,
                                                 chars: event.charactersIgnoringModifiers)
            Shortcut.save(keyCode: Int(event.keyCode), modifiers: mods, display: display)
            self.model.shortcutDisplay = display
            self.stopRecording()
            self.onShortcutChanged?()
            return nil
        }
    }

    /// Stops a recording in progress. Safe to call more than once.
    func stopRecording() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        model.recording = false
    }

    private func resetShortcut() {
        Shortcut.resetToDefault()
        model.shortcutDisplay = Shortcut.display
        onShortcutChanged?()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var startRecording: () -> Void
    var resetShortcut: () -> Void
    var setPreserveFocus: (Bool) -> Void
    /// Leaving the page must not leave a recording monitor behind.
    var onDisappear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            SettingsSection(title: "Atalho global") {
                SettingsRow(
                    title: "Abrir o histórico",
                    subtitle: model.recording
                        ? "Prime a combinação (inclui ⌘, ⌥, ⌃ ou ⇧). Esc cancela."
                        : "Precisa de pelo menos um modificador."
                ) {
                    HStack(spacing: 8) {
                        Button(action: startRecording) {
                            Text(model.recording ? "Prime as teclas…" : model.shortcutDisplay)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .frame(minWidth: 92)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.recording)
                        Button("Repor", action: resetShortcut)
                            .buttonStyle(.borderless)
                            .disabled(model.recording)
                    }
                }
            }

            SettingsSection(title: "Comportamento") {
                ToggleRow(
                    title: "Não roubar o foco",
                    subtitle: "Abre o painel sem tirar o foco à app — o que estava selecionado continua selecionado. Precisa de Acessibilidade.",
                    isOn: Binding(
                        get: { model.preserveFocus },
                        set: { model.preserveFocus = $0; setPreserveFocus($0) }))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear(perform: onDisappear)
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIcon(systemName: "doc.on.clipboard.fill", size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("Clippy").font(.title2.weight(.bold))
                Text("O teu histórico de clipboard, sempre à mão.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
