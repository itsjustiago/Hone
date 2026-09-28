import AppKit
import SwiftUI

/// Screenly as a tool hosted by Hone: capture modes + shortcuts, selection and
/// annotation, gallery, floating preview and the screen colour picker. The host
/// owns the app lifecycle, the status item/popover and the Settings window; this
/// facade only builds content and runs the background work (global hotkeys).
@MainActor
public final class ScreenlyTool {
    private let store = CaptureStore()
    private lazy var engine = SystemCapture(store: store)
    private lazy var selectionOverlay = SelectionOverlayController(
        store: store, fallback: { [weak self] mode in self?.engine.capture(mode) })
    private lazy var editor = AnnotationEditorController(store: store)
    private let menuModel = ScreenlyMenuModel()
    private let settings = SettingsController()
    private lazy var gallery = GalleryController(store: store)
    private let colorPicker = ColorPickerController()

    private var hotKeys: [HotKey] = []
    /// Closes the panel the host showed most recently (captures dismiss it first).
    private var dismissPanel: (() -> Void)?

    private static let showIconKey = "showMenuBarIcon"

    public private(set) var isRunning = false

    public init() {
        store.load()
        menuModel.showsOwnIcon = showsOwnMenuBarIcon
        settings.onShortcutsChanged = { [weak self] in
            guard let self, self.isRunning else { return }
            self.registerHotKeys()
        }
        settings.onRecordingChange = { [weak self] recording in
            // While the user records a new shortcut, drop the global hotkeys so
            // pressing an existing one doesn't fire a capture underneath.
            guard let self, self.isRunning else { return }
            if recording { self.suspendHotKeys() } else { self.registerHotKeys() }
        }
        engine.onCaptured = { [weak self] in self?.refreshMenuModel() }
    }

    /// Starts the background work (global hotkeys). Idempotent. Never asks for permissions.
    public func start() {
        guard !isRunning else { return }
        // Re-read from disk: the old app may have run meanwhile (it shares
        // shots.json), and saving a stale copy would erase its captures.
        store.load()
        refreshMenuModel()
        isRunning = true
        registerHotKeys()
    }

    /// Undoes everything `start()` set up (hotkeys, open overlays/panels). Idempotent.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        settings.stopRecording()
        suspendHotKeys()
        selectionOverlay.tearDown()
        editor.tearDown()
        gallery.close()
        colorPicker.dismissResult()
        engine.dismissPreview()
    }

    /// Pause (the old app just opened): drop the global hotkeys so they don't
    /// fire twice, but leave an open annotation editor or selection alone —
    /// tearing it down would throw the user's shapes away without warning.
    public func stopKeepingState() {
        guard isRunning else { return }
        isRunning = false
        settings.stopRecording()
        suspendHotKeys()
    }

    /// Template image for the tool's own menu-bar item (the old app's icon).
    public var menuBarImage: NSImage {
        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screenly")
            ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// Called whenever `menuBarImage` changes (Screenly's never does).
    public var onMenuBarImageChange: (() -> Void)?

    /// Whether the user wants this tool in its own menu-bar item. Persisted in the
    /// suite under the old app's `showMenuBarIcon` key (default true), so the old
    /// choice carries over. The panel's separate/join button reflects it live.
    public var showsOwnMenuBarIcon: Bool {
        get { ScreenlyDefaults.store.object(forKey: Self.showIconKey) as? Bool ?? true }
        set {
            ScreenlyDefaults.store.set(newValue, forKey: Self.showIconKey)
            menuModel.showsOwnIcon = newValue
        }
    }

    /// Call right before the panel appears: refreshes live state (counts, shortcuts,
    /// recent colours, Screen Recording status — preflight only, never prompts).
    public func panelWillShow() {
        refreshMenuModel()
    }

    /// The original dropdown minus the app rows (quit, updates, version, onboarding).
    /// - back: non-nil inside Hone's popover → a "‹" in the header calls it.
    /// - dismiss: closes the host popover; captures and other actions call it first.
    /// - openSettings: opens Hone's Settings on the Screenly page.
    /// - toggleOwnIcon: asks Hone to separate/join the tool's own menu-bar item.
    public func makeMenuPanel(back: (() -> Void)?, dismiss: @escaping () -> Void,
                              openSettings: @escaping () -> Void,
                              toggleOwnIcon: @escaping () -> Void) -> AnyView {
        dismissPanel = dismiss
        let panel = MenuPanel(
            store: store,
            model: menuModel,
            onCapture: { [weak self] mode in self?.capture(mode) },
            onPickColor: { [weak self] in self?.pickColor() },
            onPickRecentColor: { [weak self] hex in self?.copyRecentColor(hex) },
            onPickRecent: { [weak self] shot in self?.pickRecent(shot) },
            onRevealRecent: { [weak self] shot in self?.revealRecent(shot) },
            onShowGallery: { [weak self] in self?.dismissPanel?(); self?.gallery.show() },
            onSettings: { [weak self] in self?.dismissPanel?(); openSettings() },
            onGrantAccess: { [weak self] in
                self?.dismissPanel?()
                Permissions.shared.request()
                Permissions.shared.openSettings()
            },
            onBack: back,
            onToggleOwnIcon: toggleOwnIcon)
        return AnyView(panel)
    }

    /// The old Settings content minus the app sections (login item, menu-bar icon,
    /// updates, version). Windowless and unscrolled — the host page embeds it.
    /// Changing a shortcut re-registers the hotkeys while running.
    public func makeSettingsView() -> AnyView {
        AnyView(settings.makeView())
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        hotKeys.forEach { $0.invalidate() }
        hotKeys = CaptureMode.allCases.compactMap { mode in
            let hk = HotKey(keyCode: UInt32(Shortcut.keyCode(mode)),
                            modifiers: Shortcut.carbonModifiers(mode),
                            id: mode.hotKeyID)
            hk?.onFire = { [weak self] in self?.capture(mode) }
            return hk
        }
        // The screen colour picker rides the same global-hotkey machinery.
        let picker = PickerAction.eyedropper
        if let hk = HotKey(keyCode: UInt32(Shortcut.keyCode(picker)),
                           modifiers: Shortcut.carbonModifiers(picker),
                           id: picker.hotKeyID) {
            hk.onFire = { [weak self] in self?.pickColor() }
            hotKeys.append(hk)
        }
    }

    private func suspendHotKeys() {
        hotKeys.forEach { $0.invalidate() }
        hotKeys = []
    }

    // MARK: - Capture

    private func capture(_ mode: CaptureMode) {
        // A save dialog is up: a new (shield-level) capture would land on top of it.
        guard !CaptureSaveDialog.isOpen else { return }
        dismissPanel?()
        guard CaptureSettings.annotate else { engine.capture(mode); return }
        switch mode {
        case .region:
            // Freeze the screen → interactive selection + annotation overlay.
            selectionOverlay.begin()
        case .window, .screen:
            // Capture, then open the annotation editor window.
            engine.captureImage(mode) { [weak self] image in
                // A capture in flight must not open the editor once the tool stopped.
                guard let self, self.isRunning, let image else { return }
                self.editor.open(image: image, mode: mode)
            }
        }
    }

    // MARK: - Colour picker

    private func pickColor() {
        // The eyedropper is shield-level too: never over an open save dialog.
        guard !CaptureSaveDialog.isOpen else { return }
        dismissPanel?()
        colorPicker.pick()
    }

    private func copyRecentColor(_ hex: String) {
        dismissPanel?()
        colorPicker.copyRecent(hex)
    }

    // MARK: - Panel model

    /// Mirror live state into the panel's model before it shows.
    private func refreshMenuModel() {
        menuModel.count = store.items.count
        menuModel.shortcuts = Dictionary(
            uniqueKeysWithValues: CaptureMode.allCases.map { ($0.rawValue, Shortcut.display($0)) })
        menuModel.pickerShortcut = Shortcut.display(PickerAction.eyedropper)
        menuModel.recentColors = ColorHistory.colors
        menuModel.showsOwnIcon = showsOwnMenuBarIcon
        // Preflight only — never prompts.
        Permissions.shared.refresh()
        menuModel.hasScreenRecording = Permissions.shared.isTrusted
    }

    // MARK: - Recent actions

    private func pickRecent(_ shot: Shot) {
        dismissPanel?()
        if let img = NSImage(contentsOf: store.imageURL(for: shot)) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([img])
        }
    }

    private func revealRecent(_ shot: Shot) {
        dismissPanel?()
        let saved = shot.savedPath.flatMap {
            FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil
        }
        NSWorkspace.shared.activateFileViewerSelecting([saved ?? store.imageURL(for: shot)])
    }
}
