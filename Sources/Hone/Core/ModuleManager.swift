import AppKit
import SwiftUI

/// Owns the set of tools, applies their persisted state on launch, and keeps
/// them in sync with the Accessibility permission.
///
/// To add a new tool: build it, then append an instance in `registerModules()`.
@MainActor
@Observable
final class ModuleManager {
    private(set) var modules: [any HoneModule] = []

    /// The embedded former apps (Sleepy, …), in menu order.
    var menuBarTools: [any MenuBarTool] { modules.compactMap { $0 as? any MenuBarTool } }

    private let permissions = Permissions.shared
    private let legacyApps = LegacyApps.shared
    /// The "old apps are still open" alert shows at most once per launch.
    private var didShowLegacyAlert = false

    init() {
        registerModules()
        observePermissionChanges()
    }

    /// Called once the app has finished launching and the run loop is live, so
    /// event taps can be installed safely.
    func activate() {
        watchLegacyApps()
        applyEnabledStates()
        resolveLegacyConflicts()
    }

    /// The single place where tools are wired into the app.
    private func registerModules() {
        modules = [
            ScrollModule(),
            WindowPeekModule(),
            AltTabModule(),
            QuitOnCloseModule(),
            KeySwapModule(),
            // Former standalone apps, embedded as tools.
            ClippyModule.make(),
            ScreenlyModule.make(),
            SleepyModule.make(),
            // Momentary tools go last so the Settings sidebar matches the popover.
            CleanKeyboardModule(),
        ]
    }

    /// Start every module that was left enabled last session (if permission allows).
    /// Momentary tools (e.g. Clean Keyboard) run on demand, never at launch.
    private func applyEnabledStates() {
        for module in modules where module.isEnabled && module.isAvailable && !module.isMomentary {
            if module.requiresAccessibility && !permissions.isAccessibilityTrusted {
                // Keep the persisted "on" state but don't start until trusted.
                continue
            }
            module.start()
        }
    }

    /// When Accessibility is granted later, start any enabled-but-waiting modules.
    private var lastTrusted: Bool = Permissions.shared.isAccessibilityTrusted
    private func observePermissionChanges() {
        // Poll the observable permission state via a lightweight timer bridge.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let trusted = self.permissions.isAccessibilityTrusted
                guard trusted != self.lastTrusted else { return }
                self.lastTrusted = trusted
                for module in self.modules where module.requiresAccessibility && module.isEnabled {
                    trusted ? module.start() : module.stop()
                }
            }
        }
    }

    /// Toggle a module, requesting Accessibility first when the tool needs it.
    func setEnabled(_ enabled: Bool, for module: any HoneModule) {
        if enabled && module.requiresAccessibility && !permissions.isAccessibilityTrusted {
            permissions.requestAccessibility()
        }
        module.isEnabled = enabled
        if enabled { resolveLegacyConflicts() }
    }

    /// Whether a module is enabled but blocked waiting on permission.
    func isWaitingOnPermission(_ module: any HoneModule) -> Bool {
        module.isEnabled && module.requiresAccessibility && !permissions.isAccessibilityTrusted
    }

    // MARK: - Embedded tools

    func setShowsOwnMenuBarIcon(_ shows: Bool, for tool: any MenuBarTool) {
        tool.showsOwnMenuBarIcon = shows
    }

    /// Enabled, but held back because the old standalone app is running.
    func isPaused(_ module: any HoneModule) -> Bool {
        guard let tool = module as? any MenuBarTool else { return false }
        return tool.isEnabled && legacyApps.isRunning(tool.legacyBundleID)
    }

    /// Quits the old app behind a paused tool; the tool starts once it's gone.
    func quitLegacyApp(for tool: any MenuBarTool) {
        // The twin tears its state down on quit; let the tool keep what it needs first.
        tool.legacyTwinWillQuit()
        legacyApps.quit(tool.legacyBundleID)
    }

    private func watchLegacyApps() {
        legacyApps.onLaunch = { [weak self] bundleID in
            guard let self else { return }
            // Pause the tool before the twin brings up its own icon and hotkeys,
            // leaving its state for the twin to pick up.
            for tool in self.menuBarTools where tool.legacyBundleID == bundleID { tool.stopKeepingState() }
            self.resolveLegacyConflicts()
        }
        legacyApps.onTerminate = { [weak self] bundleID in
            guard let self else { return }
            for tool in self.menuBarTools where tool.legacyBundleID == bundleID && tool.isEnabled {
                tool.start()
            }
        }
        legacyApps.watch(Set(menuBarTools.map(\.legacyBundleID)))
    }

    /// Enabled tools whose twin is running are paused. Quit the twins right
    /// away if the user already agreed to; otherwise ask once per launch.
    private func resolveLegacyConflicts() {
        guard !pausedTools.isEmpty else { return }
        if LegacyApps.autoQuit {
            for tool in pausedTools { quitLegacyApp(for: tool) }
            return
        }
        guard !didShowLegacyAlert else { return }
        didShowLegacyAlert = true
        // Deferred: this can run mid-launch or from inside a SwiftUI action.
        DispatchQueue.main.async { [weak self] in self?.askToQuitLegacyApps() }
    }

    private var pausedTools: [any MenuBarTool] { menuBarTools.filter { isPaused($0) } }

    private func askToQuitLegacyApps() {
        let tools = pausedTools.sorted { $0.title < $1.title }
        guard !tools.isEmpty else { return }
        let names = tools.map { "o \($0.title)" }
        let list = names.count == 1
            ? names[0]
            : names.dropLast().joined(separator: ", ") + " e " + names[names.count - 1]

        let alert = NSAlert()
        alert.messageText = list.prefix(1).uppercased() + list.dropFirst()
            + (tools.count == 1 ? " agora vive dentro do Hone" : " agora vivem dentro do Hone")
        alert.informativeText = "As apps antigas ainda estão abertas. Fecho-as agora e sempre que "
            + "voltarem a abrir (por exemplo, no arranque do Mac)? Enquanto estiverem abertas, estas "
            + "ferramentas ficam em pausa no Hone para não haver ícones e atalhos em duplicado."
        alert.addButton(withTitle: "Fechar as apps antigas")
        alert.addButton(withTitle: "Agora não")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        LegacyApps.autoQuit = true
        for tool in pausedTools { quitLegacyApp(for: tool) }
    }

    /// `keepingToolState` is for a relaunch (rebuild/update): embedded tools
    /// leave their state armed for the next launch instead of tearing it down.
    func stopAll(keepingToolState: Bool = false) {
        for module in modules {
            if keepingToolState, let tool = module as? any MenuBarTool {
                tool.stopKeepingState()
            } else {
                module.stop()
            }
        }
    }
}
