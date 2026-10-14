import Foundation
import LidFoldKit

extension FoldEffect {
    /// PT-PT name for the picker. Exhaustive on purpose: an effect added to the
    /// Kit stops compiling here until it gets a name.
    var displayName: String {
        switch self {
        case .duo: return "Duo"
        case .ghost: return "Fantasma"
        case .roll: return "Rolo"
        case .shutter: return "Persiana"
        case .flex: return "Flexão"
        case .iris: return "Íris"
        }
    }
}

/// Persisted knobs for the Lid Fold tool.
@MainActor
@Observable
final class LidFoldSettings {
    static let effectKey = "lidFold.effect"
    static let captureKey = "lidFold.captureEnabled"

    /// Duo: the iPhone Duo's frosted-glass fold (Fantasma is the sharp variant).
    /// Unknown or missing saved values come back to this.
    static let defaultEffect = FoldEffect.duo

    /// Same default as the Kit's controller. Capture still needs Screen Recording
    /// to be allowed: without it the controller falls back to the black fade.
    static let defaultCaptureEnabled = true

    private let d: UserDefaults

    /// Told after every change, so the module can push the value into the running
    /// controller. Not state: the pane must not redraw because of it.
    @ObservationIgnored var onChange: (() -> Void)?

    /// Unknown or missing saved values come back as `defaultEffect`.
    var effect: FoldEffect {
        didSet {
            guard oldValue != effect else { return }
            d.set(effect.persistedIdentifier, forKey: Self.effectKey)
            onChange?()
        }
    }

    /// Use the real desktop in the animation (needs Screen Recording) instead of a plain fade.
    var captureEnabled: Bool {
        didSet {
            guard oldValue != captureEnabled else { return }
            d.set(captureEnabled, forKey: Self.captureKey)
            onChange?()
        }
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        effect = defaults.string(forKey: Self.effectKey).flatMap(FoldEffect.init(rawValue:)) ?? Self.defaultEffect
        captureEnabled = defaults.object(forKey: Self.captureKey) as? Bool ?? Self.defaultCaptureEnabled
    }
}
