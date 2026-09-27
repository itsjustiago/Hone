import AppKit
import SwiftUI

/// Clippy as a tool hosted by Hone: the clipboard monitor, the global shortcut
/// and the floating history panel, plus the views Hone shows for it.
///
/// Owns no status item, windows or app lifecycle — Hone does. History and
/// tables stay in Application Support/Clippy, preferences in the old app's domain.
@MainActor
public final class ClippyTool {
    private let store = HistoryStore()
    private let collections = CollectionStore()
    private lazy var clipboard = ClipboardManager(store: store)
    private lazy var panelController = PanelController(store: store, collections: collections, clipboard: clipboard)
    private let settings = SettingsController()
    private let menuModel = ClipMenuModel()
    private var hotKey: HotKey?
    private var loaded = false

    public private(set) var isRunning = false

    /// Called whenever `menuBarImage` changes (Clippy's icon never does today).
    public var onMenuBarImageChange: (() -> Void)?

    public init() {
        settings.onShortcutChanged = { [weak self] in
            guard let self, self.isRunning else { return }
            self.registerHotKey()
        }
    }

    // MARK: - Lifecycle

    /// Starts the background work: clipboard monitor and global shortcut. Idempotent.
    public func start() {
        guard !isRunning else { return }
        loadIfNeeded()
        clipboard.start()
        registerHotKey()
        isRunning = true
    }

    /// Undoes everything `start()` set up — timer, hotkey, an open panel and its
    /// key tap. Idempotent. The history stays on disk.
    public func stop() {
        guard isRunning else { return }
        clipboard.stop()
        hotKey?.invalidate()
        hotKey = nil
        panelController.hide()
        settings.stopRecording()
        isRunning = false
    }

    /// The stores are read lazily so building the tool costs nothing.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        store.load()
        collections.load()
    }

    private func registerHotKey() {
        hotKey?.invalidate()
        hotKey = HotKey(keyCode: UInt32(Shortcut.keyCode), modifiers: Shortcut.carbonModifiers)
        hotKey?.onFire = { [weak self] in self?.panelController.toggle() }
    }

    // MARK: - Menu bar

    /// Template image for Clippy's own status item — the standalone app's icon.
    public var menuBarImage: NSImage {
        let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clippy")
            ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// Whether the user wants Clippy with its own menu-bar icon. Kept under the
    /// standalone app's `showMenuBarIcon` key, so its old choice carries over.
    public var showsOwnMenuBarIcon: Bool {
        get { ClippyDefaults.showsOwnMenuBarIcon }
        set {
            ClippyDefaults.showsOwnMenuBarIcon = newValue
            menuModel.showsOwnIcon = newValue
        }
    }

    /// Call right before the menu panel appears, to refresh its live state.
    public func panelWillShow() {
        loadIfNeeded()
        menuModel.shortcut = Shortcut.display
        menuModel.hasAccessibility = PasteHelper.hasAccessibility(prompt: false)
        menuModel.showsOwnIcon = ClippyDefaults.showsOwnMenuBarIcon
    }

    /// The standalone app's dropdown, minus the app-level rows.
    /// - Parameters:
    ///   - back: non-nil inside Hone's popover; the header shows a chevron that calls it.
    ///   - dismiss: closes the popover.
    ///   - openSettings: opens Hone's settings on Clippy's page.
    ///   - toggleOwnIcon: asks Hone to split Clippy out to its own icon, or merge it back.
    public func makeMenuPanel(back: (() -> Void)?, dismiss: @escaping () -> Void,
                              openSettings: @escaping () -> Void,
                              toggleOwnIcon: @escaping () -> Void) -> AnyView {
        loadIfNeeded()
        let panel = MenuPanel(
            store: store,
            model: menuModel,
            onBack: back,
            onShowHistory: { [weak self] in dismiss(); self?.panelController.show() },
            onPickRecent: { [weak self] item in dismiss(); self?.panelController.pasteDirect(item) },
            onClear: { [weak self] in dismiss(); self?.store.clearUnpinned() },
            onSettings: { dismiss(); openSettings() },
            onGrantAccess: { dismiss(); ClippyTool.grantAccessibility() },
            onToggleOwnIcon: toggleOwnIcon)
        return AnyView(panel)
    }

    // MARK: - Settings

    /// Clippy's settings without the app-level sections (login item, menu-bar
    /// icon, updates, version). No window — Hone embeds it. Changing the shortcut
    /// re-registers the hotkey while the tool runs.
    public func makeSettingsView() -> AnyView {
        AnyView(settings.makeView())
    }

    // MARK: - Permissions

    private static func grantAccessibility() {
        _ = PasteHelper.hasAccessibility(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
