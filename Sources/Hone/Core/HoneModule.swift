import SwiftUI

/// A single, self-contained tool inside Hone (e.g. Scroll, Window Peek).
///
/// Every capability the app ships is a `HoneModule`. Adding a new tool means
/// writing one type that conforms to this protocol and registering it in
/// `ModuleManager` — nothing else in the app needs to change.
@MainActor
protocol HoneModule: AnyObject {
    /// Stable identifier, also used as the UserDefaults key namespace. e.g. "scroll".
    var id: String { get }

    /// Human title shown in the menu and settings sidebar.
    var title: String { get }

    /// One-line description of what the tool does.
    var summary: String { get }

    /// SF Symbol name for the tool's icon.
    var iconSystemName: String { get }

    /// Accent colour used for the tool's icon and controls.
    var tint: Color { get }

    /// `false` for modules that are registered but not yet implemented
    /// (shown as "Coming soon" and not toggleable).
    var isAvailable: Bool { get }

    /// Whether the tool needs the Accessibility permission to work.
    var requiresAccessibility: Bool { get }

    /// A *momentary* tool performs a one-shot action (e.g. "lock the keyboard so I
    /// can wipe it clean") instead of running in the background. When `true`, the
    /// menu and settings show a button that calls `performAction()` rather than an
    /// on/off switch, and the tool is left out of the "N tools active" count.
    var isMomentary: Bool { get }

    /// Button label for a momentary tool (e.g. "Limpar"). Ignored for toggles.
    var actionLabel: String { get }

    /// Persisted on/off state. The setter is expected to `start()`/`stop()` the
    /// module and write the value to `UserDefaults`. Unused by momentary tools.
    var isEnabled: Bool { get set }

    /// Begin intercepting / observing. Called when enabled (and permission granted).
    func start()

    /// Tear down taps, timers and observers. Called when disabled or on quit.
    func stop()

    /// Run a momentary tool's action. No-op for toggle tools.
    func performAction()

    /// The module's settings pane. Return `AnyView(EmptyView())` if there is none.
    func makeSettingsView() -> AnyView
}

extension HoneModule {
    var requiresAccessibility: Bool { false }
    var tint: Color { .accentColor }
    var isMomentary: Bool { false }
    var actionLabel: String { "" }
    func performAction() {}
    func makeSettingsView() -> AnyView { AnyView(EmptyView()) }
}

/// Persistence helpers for a module's on/off flag. Free functions rather than a
/// base class because `@Observable` does not compose with class inheritance.
enum ModuleDefaults {
    static func isEnabled(_ id: String, default def: Bool) -> Bool {
        let key = "\(id).enabled"
        return UserDefaults.standard.object(forKey: key) == nil
            ? def
            : UserDefaults.standard.bool(forKey: key)
    }

    static func setEnabled(_ id: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: "\(id).enabled")
    }
}
