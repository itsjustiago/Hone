import SwiftUI

/// Owns the set of tools, applies their persisted state on launch, and keeps
/// them in sync with the Accessibility permission.
///
/// To add a new tool: build it, then append an instance in `registerModules()`.
@MainActor
@Observable
final class ModuleManager {
    private(set) var modules: [any HoneModule] = []

    private let permissions = Permissions.shared

    init() {
        registerModules()
        observePermissionChanges()
    }

    /// Called once the app has finished launching and the run loop is live, so
    /// event taps can be installed safely.
    func activate() {
        applyEnabledStates()
    }

    /// The single place where tools are wired into the app.
    private func registerModules() {
        modules = [
            ScrollModule(),
            WindowPeekModule(),
            AltTabModule(),
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
    }

    /// Whether a module is enabled but blocked waiting on permission.
    func isWaitingOnPermission(_ module: any HoneModule) -> Bool {
        module.isEnabled && module.requiresAccessibility && !permissions.isAccessibilityTrusted
    }

    func stopAll() {
        for module in modules { module.stop() }
    }
}
