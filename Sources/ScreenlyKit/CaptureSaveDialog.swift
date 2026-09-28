import AppKit
import UniformTypeIdentifiers

/// The "Guardar" of the overlay and the editor: a native NSSavePanel so each
/// capture gets its own name and destination. The automatic save of the direct
/// flow (`CaptureOutput.deliver`) doesn't come through here.
@MainActor
enum CaptureSaveDialog {
    /// True while a save dialog is up. The key monitors let keystrokes through
    /// (they're typing the file name) and the capture hotkeys are ignored, so a
    /// shield-level overlay never lands on top of the dialog.
    static private(set) var isOpen = false

    static let lastDirectoryKey = "lastSaveDirectory"

    /// Folder the dialog opens in: the last one chosen, if it still exists,
    /// otherwise the configured save folder (created if missing).
    static func initialDirectory() -> URL {
        if let path = ScreenlyDefaults.store.string(forKey: lastDirectoryKey), !path.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        let folder = CaptureSettings.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func rememberDirectory(of url: URL) {
        ScreenlyDefaults.store.set(url.deletingLastPathComponent().path, forKey: lastDirectoryKey)
    }

    static func contentType(for ext: String) -> UTType {
        ext == "jpg" ? .jpeg : .png
    }

    static func makePanel(ext: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Captura \(CaptureOutput.stamp()).\(ext)"
        panel.allowedContentTypes = [contentType(for: ext)]
        panel.canCreateDirectories = true
        panel.prompt = "Guardar"
        panel.directoryURL = initialDirectory()
        return panel
    }

    /// App-modal run, for the shield-level overlay (which must be hidden first).
    static func runModal(ext: String) -> URL? {
        let panel = makePanel(ext: ext)
        isOpen = true
        defer { isOpen = false }
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Sheet on a normal titled window (the editor). `completion(nil)` = cancelled.
    static func beginSheet(for window: NSWindow, ext: String, completion: @escaping (URL?) -> Void) {
        let panel = makePanel(ext: ext)
        isOpen = true
        panel.beginSheetModal(for: window) { response in
            isOpen = false
            completion(response == .OK ? panel.url : nil)
        }
    }

    /// Writes atomically; on success remembers the folder for next time.
    static func write(_ data: Data, to url: URL) -> Error? {
        do {
            try data.write(to: url, options: .atomic)
            rememberDirectory(of: url)
            return nil
        } catch {
            NSLog("Screenly: could not save capture: \(error.localizedDescription)")
            return error
        }
    }

    static func makeErrorAlert(_ error: Error) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Não foi possível guardar a captura"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        return alert
    }
}
