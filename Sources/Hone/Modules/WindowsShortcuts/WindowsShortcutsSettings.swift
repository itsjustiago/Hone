import Foundation

/// Persisted knobs for Windows Shortcuts: one switch per shortcut, plus the apps
/// where holding ⌘Q is not asked for.
@MainActor
@Observable
final class WindowsShortcutsSettings {
    private let d = UserDefaults.standard

    /// Told after any of the four switches changes, so a running tap rebuilds the
    /// events it listens to (all four off means no tap at all).
    @ObservationIgnored var onChange: (() -> Void)?

    var finderCutPaste: Bool {
        didSet { d.set(finderCutPaste, forKey: "windowsShortcuts.finderCutPaste"); onChange?() }
    }
    var f2Rename: Bool {
        didSet { d.set(f2Rename, forKey: "windowsShortcuts.f2Rename"); onChange?() }
    }
    var mouseButtons: Bool {
        didSet { d.set(mouseButtons, forKey: "windowsShortcuts.mouseButtons"); onChange?() }
    }
    var holdToQuit: Bool {
        didSet { d.set(holdToQuit, forKey: "windowsShortcuts.holdToQuit"); onChange?() }
    }

    /// Bundle ids where ⌘Q quits at once. Starts empty: like Key Swap's, this is
    /// something the user opts into, never a seeded default.
    var quitExceptions: [String] {
        didSet { d.set(quitExceptions, forKey: "windowsShortcuts.quitExceptions") }
    }

    init() {
        let d = UserDefaults.standard
        func flag(_ key: String) -> Bool { d.object(forKey: key) as? Bool ?? true }
        finderCutPaste = flag("windowsShortcuts.finderCutPaste")
        f2Rename = flag("windowsShortcuts.f2Rename")
        mouseButtons = flag("windowsShortcuts.mouseButtons")
        holdToQuit = flag("windowsShortcuts.holdToQuit")
        quitExceptions = d.stringArray(forKey: "windowsShortcuts.quitExceptions") ?? []
    }

    func isExcluded(_ bundleID: String) -> Bool {
        quitExceptions.contains(bundleID)
    }

    func add(_ bundleID: String) {
        guard !bundleID.isEmpty, !quitExceptions.contains(bundleID) else { return }
        quitExceptions.append(bundleID)
    }

    func remove(_ bundleID: String) {
        quitExceptions.removeAll { $0 == bundleID }
    }
}
