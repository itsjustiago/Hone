import Foundation

/// Persisted knobs for the Key Swap tool.
@MainActor
@Observable
final class KeySwapSettings {
    private let d = UserDefaults.standard

    /// Bundle ids where the swap is *not* applied — those apps keep the stock
    /// macOS layout. Starts empty on purpose: a modifier that behaves differently
    /// depending on the app is worse than one that behaves the same everywhere,
    /// so exceptions are something the user opts into, never a seeded default.
    var exceptions: [String] { didSet { d.set(exceptions, forKey: "keySwap.exceptions") } }

    init() {
        exceptions = d.stringArray(forKey: "keySwap.exceptions") ?? []
    }

    func isExcluded(_ bundleID: String) -> Bool {
        exceptions.contains(bundleID)
    }

    func add(_ bundleID: String) {
        guard !bundleID.isEmpty, !exceptions.contains(bundleID) else { return }
        exceptions.append(bundleID)
    }

    func remove(_ bundleID: String) {
        exceptions.removeAll { $0 == bundleID }
    }
}
