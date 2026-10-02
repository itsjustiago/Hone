import SwiftUI
import AppKit
import Carbon.HIToolbox
import HoneDesign

/// The capture modes plus the colour picker, in the order they appear in Settings.
let shortcutSlots: [ShortcutSlot] = CaptureMode.allCases.map { $0 as ShortcutSlot } + [PickerAction.eyedropper]

final class SettingsModel: ObservableObject {
    @Published var shortcuts: [String: String]   // slot.shortcutKey → display
    @Published var recordingKey: String?          // shortcutKey being recorded
    @Published var annotate = CaptureSettings.annotate
    @Published var saveFolderPath = CaptureSettings.saveFolder.path
    @Published var saveToFolder = CaptureSettings.saveToFolder
    @Published var format = CaptureSettings.format
    @Published var copyToClipboard = CaptureSettings.copyToClipboard
    @Published var playSound = CaptureSettings.playSound
    @Published var showPreview = CaptureSettings.showPreview
    @Published var delay = CaptureSettings.delaySeconds

    init() {
        shortcuts = Dictionary(
            uniqueKeysWithValues: shortcutSlots.map { ($0.shortcutKey, Shortcut.display($0)) })
    }
}

/// Drives the Screenly settings content: per-mode shortcuts and capture options.
/// Windowless — the host (Hone) embeds `makeView()` in its own Settings window.
final class SettingsController {
    private let model = SettingsModel()
    private var recordMonitor: Any?

    /// Re-register the global hotkeys after a shortcut changes.
    var onShortcutsChanged: (() -> Void)?
    /// Suspend the global hotkeys while recording so pressing one doesn't capture.
    var onRecordingChange: ((Bool) -> Void)?

    func makeView() -> SettingsView {
        SettingsView(
            model: model,
            startRecording: { [weak self] slot in self?.startRecording(slot) },
            resetShortcut: { [weak self] slot in self?.resetShortcut(slot) },
            chooseFolder: { [weak self] in self?.chooseFolder() },
            revealFolder: { NSWorkspace.shared.activateFileViewerSelecting([CaptureSettings.saveFolder]) },
            onAppear: { [weak self] in self?.refreshFromSystem() },
            onDisappear: { [weak self] in self?.stopRecording() })
    }

    private func refreshFromSystem() {
        model.shortcuts = Dictionary(
            uniqueKeysWithValues: shortcutSlots.map { ($0.shortcutKey, Shortcut.display($0)) })
        model.annotate = CaptureSettings.annotate
        model.saveFolderPath = CaptureSettings.saveFolder.path
    }

    // MARK: - Shortcut recording

    private func startRecording(_ slot: ShortcutSlot) {
        stopRecording()
        model.recordingKey = slot.shortcutKey
        onRecordingChange?(true)
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
            Shortcut.save(slot, keyCode: Int(event.keyCode), modifiers: mods, display: display)
            self.model.shortcuts[slot.shortcutKey] = display
            self.stopRecording()
            self.onShortcutsChanged?()
            return nil
        }
    }

    /// Ends a shortcut recording in progress (if any) and restores the hotkeys.
    func stopRecording() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        if model.recordingKey != nil {
            model.recordingKey = nil
            onRecordingChange?(false)
        }
    }

    private func resetShortcut(_ slot: ShortcutSlot) {
        Shortcut.resetToDefault(slot)
        model.shortcuts[slot.shortcutKey] = Shortcut.display(slot)
        onShortcutsChanged?()
    }

    // MARK: - Folder

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Escolher"
        panel.directoryURL = CaptureSettings.saveFolder
        if panel.runModal() == .OK, let url = panel.url {
            CaptureSettings.saveFolder = url
            model.saveFolderPath = url.path
        }
    }
}

/// The settings sections, without a scroll view, header or fixed size — the host
/// page provides those (matching how Hone embeds its own modules' settings).
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var startRecording: (ShortcutSlot) -> Void
    var resetShortcut: (ShortcutSlot) -> Void
    var chooseFolder: () -> Void
    var revealFolder: () -> Void
    var onAppear: () -> Void
    var onDisappear: () -> Void

    private let delayOptions: [(Int, String)] = [
        (0, "Desligado"), (3, "3 segundos"), (5, "5 segundos"), (10, "10 segundos"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Atalhos globais") {
                ForEach(Array(shortcutSlots.enumerated()), id: \.element.shortcutKey) { index, slot in
                    if index > 0 { RowDivider() }
                    shortcutRow(slot)
                }
            }

            SettingsSection(title: "Guardar") {
                SettingsRow(
                    title: "Guardar numa pasta",
                    subtitle: model.saveToFolder ? shortPath(model.saveFolderPath) : "As capturas só vão para o clipboard/histórico."
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.saveToFolder },
                        set: { model.saveToFolder = $0; CaptureSettings.saveToFolder = $0 }))
                        .labelsHidden().toggleStyle(VibeToggleStyle(tint: Brand.toolColor))
                        .accessibilityLabel("Guardar numa pasta")
                }
                if model.saveToFolder {
                    RowDivider()
                    SettingsRow(title: "Pasta de destino") {
                        HStack(spacing: 8) {
                            Button("Abrir", action: revealFolder).controlSize(.small)
                            Button("Escolher…", action: chooseFolder).controlSize(.small)
                        }
                    }
                }
                RowDivider()
                SettingsRow(title: "Formato") {
                    Picker("", selection: Binding(
                        get: { model.format },
                        set: { model.format = $0; CaptureSettings.format = $0 })) {
                        Text("PNG").tag("png")
                        Text("JPG").tag("jpg")
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 130)
                }
            }

            SettingsSection(title: "Ao capturar") {
                ToggleRow(
                    title: "Editar antes de copiar/guardar",
                    subtitle: "Mostra o editor (seleção ajustável + anotações) em vez de exportar logo.",
                    isOn: Binding(
                        get: { model.annotate },
                        set: { model.annotate = $0; CaptureSettings.annotate = $0 }))
                RowDivider()
                ToggleRow(
                    title: "Copiar para o clipboard",
                    isOn: Binding(
                        get: { model.copyToClipboard },
                        set: { model.copyToClipboard = $0; CaptureSettings.copyToClipboard = $0 }))
                RowDivider()
                ToggleRow(
                    title: "Mostrar pré-visualização flutuante",
                    isOn: Binding(
                        get: { model.showPreview },
                        set: { model.showPreview = $0; CaptureSettings.showPreview = $0 }))
                RowDivider()
                ToggleRow(
                    title: "Som do obturador",
                    isOn: Binding(
                        get: { model.playSound },
                        set: { model.playSound = $0; CaptureSettings.playSound = $0 }))
                RowDivider()
                SettingsRow(
                    title: "Atraso (ecrã inteiro)",
                    subtitle: "Contagem antes de capturar o ecrã todo."
                ) {
                    Picker("", selection: Binding(
                        get: { model.delay },
                        set: { model.delay = $0; CaptureSettings.delaySeconds = $0 })) {
                        ForEach(delayOptions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().frame(width: 130)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
    }

    private func shortcutRow(_ slot: ShortcutSlot) -> some View {
        let recording = model.recordingKey == slot.shortcutKey
        return SettingsRow(
            title: slot.title,
            subtitle: recording ? "Prime a combinação (inclui ⌘, ⌥, ⌃ ou ⇧). Esc cancela." : nil
        ) {
            HStack(spacing: 8) {
                Button(action: { startRecording(slot) }) {
                    Text(recording ? "Prime as teclas…" : (model.shortcuts[slot.shortcutKey] ?? ""))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .frame(minWidth: 84)
                }
                .buttonStyle(VibeButtonStyle())
                .disabled(model.recordingKey != nil && !recording)
                Button("Repor") { resetShortcut(slot) }
                    .buttonStyle(VibeLinkButtonStyle(.secondary))
                    .disabled(model.recordingKey != nil)
            }
        }
    }

    private func shortPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
