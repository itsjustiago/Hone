import SwiftUI
import AppKit
import Carbon.HIToolbox
import HoneDesign

/// Click, then press the new shortcut. It needs at least one modifier; Esc cancels.
///
/// While it listens, `onRecordingChange(true)` lets the host drop its global
/// hotkey, so pressing the current shortcut records it instead of toggling the
/// tool. `onRecordingChange(false)` brings it back — also when the control leaves
/// the screen mid-recording.
struct HandShortcutRecorder: View {
    @Binding var shortcut: HandShortcutKey
    var onRecordingChange: (Bool) -> Void = { _ in }

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Text(recording ? "Carrega no atalho…" : shortcut.displayString)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 112)
            }
            .buttonStyle(VibeButtonStyle())
            if shortcut != .default && !recording {
                Button("Repor") { shortcut = .default }
                    .buttonStyle(VibeLinkButtonStyle(.secondary))
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        guard monitor == nil else { return }
        recording = true
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if Int(event.keyCode) == kVK_Escape && mods.isEmpty {
                stop()
                return nil
            }
            guard let key = HandShortcutKey(event: event) else {
                NSSound.beep() // a bare key can't be a global shortcut
                return nil
            }
            shortcut = key
            stop()
            return nil
        }
    }

    /// Ends a recording in progress (if any). Safe to call more than once.
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        onRecordingChange(false)
    }
}
