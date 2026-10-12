// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import Foundation

/// The catalog of lid effects. `rawValue` is the stable persisted identifier and
/// `shaderIndex` is the explicit numeric contract with the Metal fragment shader.
/// Neither may be renumbered: saved selections and the shader switch depend on both.
public enum FoldEffect: String, CaseIterable, Sendable, Identifiable {
    case duo, ghost, roll, shutter, flex, iris

    public static let fallback = FoldEffect.duo

    public var id: String { rawValue }
    public var persistedIdentifier: String { rawValue }

    /// Mirrored by `Uniforms.effect` in `FoldShader.source`.
    public var shaderIndex: UInt32 {
        switch self {
        case .duo: return 0
        case .ghost: return 5
        case .roll: return 1
        case .shutter: return 2
        case .flex: return 3
        case .iris: return 4
        }
    }

    /// An unreadable or unknown saved selection returns to the default effect.
    public static func resolve(persisted: String?) -> FoldEffect {
        guard let persisted, let effect = FoldEffect(rawValue: persisted) else { return fallback }
        return effect
    }

    /// The shader applies the same rule for an index it does not recognize.
    public static func resolve(shaderIndex: UInt32) -> FoldEffect {
        allCases.first { $0.shaderIndex == shaderIndex } ?? fallback
    }

    /// PT-PT: shown to the user (Hone's `displayName` carries the same names).
    public var title: String {
        switch self {
        case .duo: return "Duo"
        case .ghost: return "Fantasma"
        case .roll: return "Rolo"
        case .shutter: return "Persiana"
        case .flex: return "Flexão"
        case .iris: return "Íris"
        }
    }

    public var symbol: String {
        switch self {
        case .duo: return "macbook"
        case .ghost: return "aqi.medium"
        case .roll: return "scroll"
        case .shutter: return "square.stack.3d.down.right"
        case .flex: return "rectangle.compress.vertical"
        case .iris: return "camera.aperture"
        }
    }

    public var summary: String {
        switch self {
        case .duo: return "O ecrã expande-se junto à dobradiça enquanto a tampa fecha."
        case .ghost: return "O ecrã mantém o plano de repouso enquanto a tampa inclina e desfoca-se suavemente."
        case .roll: return "O ecrã enrola-se num rolo que desce até à dobradiça."
        case .shutter: return "Quatro painéis rígidos encaixam-se uns atrás dos outros até à dobradiça."
        case .flex: return "Um ecrã flexível e curvo colapsa em direção à dobradiça."
        case .iris: return "Oito lâminas sobrepostas fecham uma abertura acima da dobradiça."
        }
    }

    /// Duo can skip the pyramid with Softness off. Effects that minify
    /// the source still need it for prefiltering at zero Softness.
    public var needsPrefilteredSource: Bool { self != .duo }
}
