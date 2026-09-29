import AppKit
import SwiftUI

/// Sleepy packaged as a tool a host app (Hone) can embed.
///
/// Holds what the standalone app's `AppDelegate` used to do — restoring the
/// sleep block on launch, keeping the menu model and icon in sync, releasing
/// everything on quit — but owns no status item, window or app lifecycle. The
/// host decides where the panel and settings are shown, and never sees
/// `NSApp.terminate` / `setActivationPolicy` from here.
@MainActor
public final class SleepyTool {
    private let menuModel = SleepMenuModel()
    private let settingsModel = SettingsModel()

    /// Legacy key from the standalone app's `MenuBarIcon`, kept so the user's
    /// "show in menu bar" choice carries over.
    private static let showIconKey = "showMenuBarIcon"

    public private(set) var isRunning = false

    /// Called whenever `menuBarImage` changes (sleep block on/off).
    public var onMenuBarImageChange: (() -> Void)?

    public init() {
        menuModel.showsOwnIcon = showsOwnMenuBarIcon
    }

    // MARK: - Lifecycle

    /// What `applicationDidFinishLaunching` used to do. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        SleepController.shared.onStateChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshMenuModel()
                self?.onMenuBarImageChange?()
            }
        }
        SleepController.shared.restoreOnLaunch()
    }

    /// What `applicationWillTerminate` used to do: hand sleep back to the
    /// system so the Mac is never left stuck awake. Idempotent.
    ///
    /// If turning the block off fails (no passwordless access and the admin
    /// prompt was cancelled), the Mac is still kept awake — so the tool stays
    /// running and visible instead of pretending it stopped.
    public func stop() {
        guard isRunning else { return }
        SleepController.shared.disable()
        guard !SleepController.shared.isActive else {
            refreshMenuModel()
            onMenuBarImageChange?()
            return
        }
        SleepController.shared.onStateChange = nil
        isRunning = false
        refreshMenuModel()
        onMenuBarImageChange?()
    }

    /// Like `stop()`, but leaves the sleep block armed and its state persisted
    /// for whoever runs Sleepy next: Hone relaunching (rebuild/update) or the
    /// old app taking over. Idempotent. Never prompts.
    public func stopKeepingState() {
        guard isRunning else { return }
        SleepController.shared.onStateChange = nil
        SleepController.shared.suspend()
        isRunning = false
        refreshMenuModel()
        onMenuBarImageChange?()
    }

    /// The host is about to quit the standalone Sleepy, which turns the block
    /// off on its way out. Remember that it was on so the next `start()`
    /// re-arms it (silently, when passwordless access is installed).
    public func legacyTwinWillQuit() {
        SleepController.shared.stashForHandoff()
    }

    // MARK: - Menu bar

    /// Sun while sleep is blocked, moon otherwise. Template, so it adapts to the
    /// menu bar's appearance.
    public var menuBarImage: NSImage {
        let active = SleepController.shared.isActive
        let symbol = active ? "sun.max.fill" : "moon.zzz"
        let description = active ? "Sleepy — Mac e ecrã acordados" : "Sleepy — sleep normal"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// Whether the user wants Sleepy under its own menu-bar icon. Stored under
    /// the standalone app's key (absent = first run = shown).
    public var showsOwnMenuBarIcon: Bool {
        get { SleepyDefaults.store.object(forKey: Self.showIconKey) as? Bool ?? true }
        set {
            SleepyDefaults.store.set(newValue, forKey: Self.showIconKey)
            menuModel.showsOwnIcon = newValue
        }
    }

    // MARK: - Panel

    /// Mirror the live system state into the panel's model before it shows.
    /// `reassert()` first: if the block dropped behind our back it fires
    /// `onStateChange` (wired in `start()`), which also updates the icon.
    public func panelWillShow() {
        SleepController.shared.reassert()
        refreshMenuModel()
    }

    public func makeMenuPanel(back: (() -> Void)?,
                              dismiss: @escaping () -> Void,
                              openSettings: @escaping () -> Void,
                              toggleOwnIcon: @escaping () -> Void) -> AnyView {
        AnyView(MenuPanel(
            model: menuModel,
            onToggleSleep: { [weak self] in self?.toggleSleep() },
            onEnablePasswordless: { [weak self] in
                _ = PrivilegedAccess.install()
                self?.refreshMenuModel()
            },
            onChangeAutoOff: { [weak self] minutes in
                SleepController.autoOffMinutes = minutes
                self?.refreshMenuModel()
            },
            onSettings: { dismiss(); openSettings() },
            onBack: back,
            onToggleOwnIcon: toggleOwnIcon))
    }

    // MARK: - Settings

    public func makeSettingsView() -> AnyView {
        AnyView(SleepySettingsView(model: settingsModel))
    }

    // MARK: - Private

    private func refreshMenuModel() {
        menuModel.isActive = SleepController.shared.isActive
        menuModel.autoOffText = autoOffText()
        menuModel.autoOffMinutes = SleepController.autoOffMinutes
        menuModel.passwordlessInstalled = PrivilegedAccess.isInstalled
        menuModel.showsOwnIcon = showsOwnMenuBarIcon
        settingsModel.refresh()
    }

    private func autoOffText() -> String? {
        guard let off = SleepController.shared.autoOffDate else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        // Prazo passado com o Sleepy ainda ligado = o auto-desligar falhou.
        if off <= Date() { return "Não desligou às \(fmt.string(from: off)) — desliga à mão" }
        return "Desliga sozinho às \(fmt.string(from: off))"
    }

    private func toggleSleep() {
        if SleepController.shared.isActive {
            SleepController.shared.disable()
        } else {
            SleepController.shared.enable()
        }
        // A cancelled admin prompt changes nothing and fires no callback —
        // resync so the switch snaps back.
        refreshMenuModel()
        onMenuBarImageChange?()
    }
}
