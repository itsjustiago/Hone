// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import Testing
@testable import LidFoldKit

@Test func highRefreshRequiresDisplayPowerAndMotion() {
    #expect(FoldFramePacing.rate(maximum:120,externalPower:true,lowPower:false,thermalPressure:false,moving:true) == 120)
    #expect(FoldFramePacing.rate(maximum:60,externalPower:true,lowPower:false,thermalPressure:false,moving:true) == 60)
    #expect(FoldFramePacing.rate(maximum:120,externalPower:false,lowPower:false,thermalPressure:false,moving:true) == 60)
    #expect(FoldFramePacing.rate(maximum:120,externalPower:true,lowPower:true,thermalPressure:false,moving:true) == 60)
    #expect(FoldFramePacing.rate(maximum:120,externalPower:true,lowPower:false,thermalPressure:false,moving:false) == 60)
    #expect(FoldFramePacing.rate(maximum:120,externalPower:true,lowPower:false,thermalPressure:true,moving:true) == 30)
    #expect(FoldFramePacing.rate(maximum:48,externalPower:true,lowPower:false,thermalPressure:false,moving:true) == 48)
}

@Test func primingAfterIdlePreservesProgressWithoutJumping() {
    var animation = FoldAnimation()
    _ = animation.sample(target:1,at:0)
    let before = animation.sample(target:1,at:0.03)
    animation.prime(at:5)
    #expect(animation.sample(target:1,at:5) == before)
    let after = animation.sample(target:1,at:5.008)
    #expect(after > before && after < 0.7)
}

@Test func sharedSamplesDoNotSpeedUpTheAnimation() {
    var oneView = FoldAnimation(), twoViews = FoldAnimation()
    _ = oneView.sample(target:1,at:0)
    _ = twoViews.sample(target:1,at:0)
    let single = oneView.sample(target:1,at:1.0/60)
    _ = twoViews.sample(target:1,at:1.0/120)
    let shared = twoViews.sample(target:1,at:1.0/60)
    #expect(abs(single-shared) < 1e-9)
}
