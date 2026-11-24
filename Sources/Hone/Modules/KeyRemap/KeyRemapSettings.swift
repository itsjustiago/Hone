import Foundation

/// Persisted choices for the Key Remap tool: for each key that can be remapped, the key
/// it becomes. A key with no entry works as it always did.
@MainActor
@Observable
final class KeyRemapSettings {
    static let mapKey = "keyRemap.map"

    private let d: UserDefaults

    /// Told after every change, so a running engine writes the new mapping.
    @ObservationIgnored var onChange: (() -> Void)?

    /// Source id → destination id (see `KeyRemapRules`). Whatever is written here by hand
    /// is kept as it is; ids that mean nothing are ignored when the mapping is built.
    var map: [String: String] {
        didSet {
            d.set(map, forKey: Self.mapKey)
            onChange?()
        }
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        let stored = defaults.dictionary(forKey: Self.mapKey) ?? [:]
        map = stored.compactMapValues { $0 as? String }
    }

    /// The id the key becomes, or `KeyRemapRules.normalID` when it is left alone.
    func destination(of source: String) -> String {
        KeyRemapRules.effective(map)[source] ?? KeyRemapRules.normalID
    }

    func setDestination(_ destination: String, of source: String) {
        var next = map
        if destination == KeyRemapRules.normalID || destination == source {
            next.removeValue(forKey: source)
        } else {
            next[source] = destination
        }
        guard next != map else { return }
        map = next
    }

    /// Whether any key works differently from how it does out of the box.
    var hasChanges: Bool { !KeyRemapRules.effective(map).isEmpty }

    func reset() {
        guard !map.isEmpty else { return }
        map = [:]
    }
}
