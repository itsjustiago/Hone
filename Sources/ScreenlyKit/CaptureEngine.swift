import AppKit

/// User-facing capture preferences, persisted in UserDefaults. Screenly is not
/// sandboxed (self-signed, like its siblings), so a plain folder path is enough —
/// no security-scoped bookmarks needed.
enum CaptureSettings {
    private static var d: UserDefaults { ScreenlyDefaults.store }

    /// Show the annotation editor after selecting/capturing, instead of exporting
    /// straight away. This is the default flow.
    static var annotate: Bool {
        get { d.object(forKey: "annotateBeforeExport") as? Bool ?? true }
        set { d.set(newValue, forKey: "annotateBeforeExport") }
    }

    /// Folder where a user-facing copy of each capture is written.
    static var saveFolder: URL {
        get {
            if let p = d.string(forKey: "saveFolder"), !p.isEmpty {
                return URL(fileURLWithPath: p)
            }
            let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
            return pics.appendingPathComponent("Screenly", isDirectory: true)
        }
        set { d.set(newValue.path, forKey: "saveFolder") }
    }

    /// "png" or "jpg".
    static var format: String {
        get { d.string(forKey: "captureFormat") ?? "png" }
        set { d.set(newValue, forKey: "captureFormat") }
    }

    static var copyToClipboard: Bool {
        get { d.object(forKey: "copyToClipboard") as? Bool ?? true }
        set { d.set(newValue, forKey: "copyToClipboard") }
    }

    static var saveToFolder: Bool {
        get { d.object(forKey: "saveToFolder") as? Bool ?? true }
        set { d.set(newValue, forKey: "saveToFolder") }
    }

    /// Countdown (seconds) before a full-screen capture. 0 = off.
    static var delaySeconds: Int {
        get { d.integer(forKey: "captureDelay") }
        set { d.set(newValue, forKey: "captureDelay") }
    }

    static var playSound: Bool {
        get { d.object(forKey: "playSound") as? Bool ?? true }
        set { d.set(newValue, forKey: "playSound") }
    }

    static var showPreview: Bool {
        get { d.object(forKey: "showPreview") as? Bool ?? true }
        set { d.set(newValue, forKey: "showPreview") }
    }
}

/// Where a finished capture goes: user folder, recent-history store, clipboard,
/// floating preview. Shared by the direct flow and the annotation editor.
enum CaptureOutput {
    /// Full delivery honouring the user's settings (used by the direct, no-edit flow).
    @discardableResult
    static func deliver(imageData: Data, ext: String, mode: CaptureMode,
                        store: CaptureStore, preview: CapturePreview) -> Bool {
        var savedURL: URL?
        if CaptureSettings.saveToFolder { savedURL = saveToFolder(imageData, ext: ext) }
        let internalURL = store.add(data: imageData, ext: ext, mode: mode, savedPath: savedURL?.path)
        if CaptureSettings.copyToClipboard, let image = NSImage(data: imageData) {
            copyToClipboard(image)
        }
        if CaptureSettings.showPreview, let url = savedURL ?? internalURL, let image = NSImage(contentsOf: url) {
            preview.show(image: image, reveal: savedURL ?? internalURL)
        }
        return internalURL != nil
    }

    static func copyToClipboard(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    @discardableResult
    static func saveToFolder(_ data: Data, ext: String) -> URL? {
        let folder = CaptureSettings.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, base: "Captura \(stamp())", ext: ext)
        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("Screenly: could not write to save folder: \(error.localizedDescription)")
            return nil
        }
    }

    /// Avoid clobbering if two captures land in the same second.
    private static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_PT")
        f.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        return f.string(from: Date())
    }
}

/// A capture backend. `screencapture` is the implementation; the protocol keeps
/// room to swap in ScreenCaptureKit later without touching callers.
protocol CaptureEngine {
    func capture(_ mode: CaptureMode)
}

/// Wraps the system `/usr/sbin/screencapture` binary — native selection UI for
/// free, robust across displays.
final class SystemCapture: CaptureEngine {
    private let store: CaptureStore
    private let preview = CapturePreview()

    /// Fired on the main thread after a capture is stored, so the UI can refresh.
    var onCaptured: (() -> Void)?

    init(store: CaptureStore) { self.store = store }

    func dismissPreview() { preview.dismiss(animated: false) }

    /// Direct flow: capture and deliver straight away (no editor).
    func capture(_ mode: CaptureMode) {
        run(mode, format: CaptureSettings.format) { [weak self] tmp, fmt in
            guard let self, let tmp, let data = try? Data(contentsOf: tmp), !data.isEmpty else { return }
            CaptureOutput.deliver(imageData: data, ext: fmt, mode: mode, store: self.store, preview: self.preview)
            try? FileManager.default.removeItem(at: tmp)
            self.onCaptured?()
        }
    }

    /// Editor flow: capture and hand the raw image back (window / full-screen modes).
    func captureImage(_ mode: CaptureMode, completion: @escaping (NSImage?) -> Void) {
        run(mode, format: "png") { tmp, _ in
            defer { if let tmp { try? FileManager.default.removeItem(at: tmp) } }
            guard let tmp, let img = NSImage(contentsOf: tmp) else { completion(nil); return }
            completion(img)
        }
    }

    // MARK: - Shared runner

    /// Runs `screencapture` for a mode to a temp file, then calls `done(tmpURL?, fmt)`
    /// on the main thread. `tmpURL` is nil when the user cancelled or it failed.
    private func run(_ mode: CaptureMode, format fmt: String, done: @escaping (URL?, String) -> Void) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenly-\(UUID().uuidString).\(fmt)")

        var args: [String] = []
        switch mode {
        case .region: args += ["-i"]        // interactive region (space toggles window mode)
        case .window: args += ["-w", "-o"]  // window picker, no drop shadow
        case .screen: break                 // whole screen
        }
        args += ["-t", fmt]
        if !CaptureSettings.playSound { args += ["-x"] }
        if mode == .screen, CaptureSettings.delaySeconds > 0 {
            args += ["-T", "\(CaptureSettings.delaySeconds)"]
        }
        args.append(tmp.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = args
        proc.terminationHandler = { _ in
            DispatchQueue.main.async {
                let fm = FileManager.default
                // Cancelled (Esc) → no file written.
                if fm.fileExists(atPath: tmp.path) {
                    done(tmp, fmt)
                } else {
                    done(nil, fmt)
                }
            }
        }
        do {
            try proc.run()
        } catch {
            NSLog("Screenly: screencapture failed to launch: \(error.localizedDescription)")
            done(nil, fmt)
        }
    }
}
