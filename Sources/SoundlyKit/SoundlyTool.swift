import AppKit
import SwiftUI

/// Soundly (per-app volume, like SoundSource) packaged as a tool a host app
/// (Hone) can embed. Owns no status item or window: the host decides where the
/// icon, the panel and the settings are shown.
///
/// The levels live in the `com.tiagof.hone.soundly` defaults domain, per bundle
/// id, so an app at 40 % is at 40 % again the next time it plays.
@MainActor
public final class SoundlyTool {
    /// The engine the UI binds to (`apps`, `permission`, `setVolume`, `setMuted`…).
    public let mixer: SoundlyMixer

    public var isRunning: Bool { mixer.isRunning }

    private let defaults: UserDefaults
    private let list: SoundlyListModel

    /// Called whenever `menuBarImage` changes (it never does).
    public var onMenuBarImageChange: (() -> Void)?

    public convenience init() {
        self.init(defaults: UserDefaults(suiteName: SoundlyStore.suiteName) ?? .standard)
    }

    /// `defaults` is injectable so tests never touch the real preferences.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        mixer = SoundlyMixer(store: SoundlyStore(defaults: defaults))
        list = SoundlyListModel(mixer: mixer)
        list.showsOwnIcon = showsOwnMenuBarIcon
    }

    // MARK: - Lifecycle

    /// Starts discovery and applies the saved levels the permission allows.
    /// Never prompts for the permission.
    public func start() {
        mixer.start()
    }

    /// Removes every tap — all apps play untouched again — and stops listening.
    public func stop() {
        mixer.stop()
    }

    // MARK: - Menu bar

    /// The speaker, as a template image so it adapts to the menu bar.
    public var menuBarImage: NSImage {
        let image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Soundly") ?? NSImage()
        image.isTemplate = true
        return image
    }

    static let showIconKey = "showMenuBarIcon"

    /// Whether the user wants Soundly under its own menu-bar icon (absent = shown).
    public var showsOwnMenuBarIcon: Bool {
        get { defaults.object(forKey: Self.showIconKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.showIconKey)
            list.showsOwnIcon = newValue
        }
    }

    // MARK: - Panel

    /// Call right before the panel appears: re-reads the permission (cheap,
    /// never prompts) and lets the list settle into the engine's order.
    public func panelWillShow() {
        list.showsOwnIcon = showsOwnMenuBarIcon
        list.setDragging(false)
        mixer.refreshPermission()
    }

    public func makeMenuPanel(back: (() -> Void)?,
                              dismiss: @escaping () -> Void,
                              openSettings: @escaping () -> Void,
                              toggleOwnIcon: @escaping () -> Void) -> AnyView {
        AnyView(SoundlyPanel(
            mixer: mixer, list: list, onBack: back,
            onSettings: { dismiss(); openSettings() },
            onToggleOwnIcon: toggleOwnIcon))
    }

    // MARK: - Settings

    public func makeSettingsView() -> AnyView {
        AnyView(SoundlySettingsView(onResetAll: { [mixer] in mixer.resetAll() }))
    }
}
