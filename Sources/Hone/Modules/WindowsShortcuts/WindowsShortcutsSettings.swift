import Foundation

/// Persisted knobs for Windows Shortcuts: one switch per shortcut, plus the apps
/// where holding ⌘Q is not asked for and the apps where ⌥ + arrows don't snap.
@MainActor
@Observable
final class WindowsShortcutsSettings {
    private let d = UserDefaults.standard

    /// Told after any of the six switches changes, so a running tap rebuilds the
    /// events it listens to (all six off means no tap at all).
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

    /// The two window switches are off until asked for, unlike the four above: ⌥ +
    /// arrows takes over "jump a word" in every text field, and the green button
    /// stops opening full screen.
    var snapWindows: Bool {
        didSet { d.set(snapWindows, forKey: "windowsShortcuts.snapWindows"); onChange?() }
    }
    var greenButtonMaximizes: Bool {
        didSet { d.set(greenButtonMaximizes, forKey: "windowsShortcuts.greenButtonMaximizes"); onChange?() }
    }

    /// Bundle ids where ⌘Q quits at once. Starts empty: like Key Swap's, this is
    /// something the user opts into, never a seeded default.
    var quitExceptions: [String] {
        didSet { d.set(quitExceptions, forKey: "windowsShortcuts.quitExceptions") }
    }

    /// Bundle ids where ⌥ + arrows pass through instead of snapping. Starts empty,
    /// for the same reason.
    var snapExceptions: [String] {
        didSet { d.set(snapExceptions, forKey: "windowsShortcuts.snapExceptions") }
    }

    init() {
        let d = UserDefaults.standard
        func flag(_ key: String, default value: Bool = true) -> Bool { d.object(forKey: key) as? Bool ?? value }
        finderCutPaste = flag("windowsShortcuts.finderCutPaste")
        f2Rename = flag("windowsShortcuts.f2Rename")
        mouseButtons = flag("windowsShortcuts.mouseButtons")
        holdToQuit = flag("windowsShortcuts.holdToQuit")
        snapWindows = flag("windowsShortcuts.snapWindows", default: false)
        greenButtonMaximizes = flag("windowsShortcuts.greenButtonMaximizes", default: false)
        quitExceptions = d.stringArray(forKey: "windowsShortcuts.quitExceptions") ?? []
        snapExceptions = d.stringArray(forKey: "windowsShortcuts.snapExceptions") ?? []
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

    func isSnapExcluded(_ bundleID: String) -> Bool {
        snapExceptions.contains(bundleID)
    }

    func addSnapException(_ bundleID: String) {
        guard !bundleID.isEmpty, !snapExceptions.contains(bundleID) else { return }
        snapExceptions.append(bundleID)
    }

    func removeSnapException(_ bundleID: String) {
        snapExceptions.removeAll { $0 == bundleID }
    }
}
