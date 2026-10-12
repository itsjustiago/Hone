// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import Testing
@testable import LidFoldKit

@Test func duoIsTheDefaultAndUnknownSelectionsFallBackToIt() {
    #expect(FoldEffect.fallback == .duo)
    #expect(FoldEffect.resolve(persisted:nil) == .duo)
    #expect(FoldEffect.resolve(persisted:"") == .duo)
    #expect(FoldEffect.resolve(persisted:"Duo") == .duo)          // Identifiers are lower case.
    #expect(FoldEffect.resolve(persisted:"fold") == .duo)
    #expect(FoldEffect.resolve(persisted:"kaleidoscope") == .duo)
    #expect(FoldEffect.resolve(shaderIndex:6) == .duo)
    #expect(FoldEffect.resolve(shaderIndex:.max) == .duo)
}

@Test func persistedIdentifiersAndShaderIndicesAreStable() {
    #expect(FoldEffect.allCases.map(\.persistedIdentifier) == ["duo","ghost","roll","shutter","flex","iris"])
    #expect(FoldEffect.allCases.map(\.shaderIndex) == [0,5,1,2,3,4])
    for effect in FoldEffect.allCases {
        #expect(FoldEffect.resolve(persisted:effect.persistedIdentifier) == effect)
        #expect(FoldEffect.resolve(shaderIndex:effect.shaderIndex) == effect)
        #expect(effect.persistedIdentifier == effect.rawValue)
        #expect(effect.id == effect.rawValue)
    }
    #expect(Set(FoldEffect.allCases.map(\.shaderIndex)).count == FoldEffect.allCases.count)
    #expect(Set(FoldEffect.allCases.map(\.title)).count == FoldEffect.allCases.count)
}

@Test func everyEffectIsPresentableAndFlatEffectsKeepTheSharpPath() {
    #expect(FoldEffect.allCases.count == 6)
    for effect in FoldEffect.allCases {
        #expect(!effect.title.isEmpty)
        #expect(!effect.symbol.isEmpty)
        #expect(effect.summary.hasSuffix("."))
        #expect(effect.needsPrefilteredSource == (effect != .duo))
    }
}

/// The angle drives every effect through the same mapping, so a selection can
/// never change when the desktop is untouched or fully closed.
@Test func effectSelectionDoesNotChangeTheAngleContract() {
    for effect in FoldEffect.allCases {
        #expect(effect.shaderIndex <= 5)
        #expect(FoldMath.progress(angle:105,clearAngle:105) == 0)
        #expect(FoldMath.progress(angle:5,clearAngle:105) == 1)
    }
}
