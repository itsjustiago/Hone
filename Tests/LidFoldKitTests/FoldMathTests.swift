// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import Testing
@testable import LidFoldKit

@Test func sensorReportsRejectMalformedAndImpossibleValues() {
    #expect(FoldMath.decodeReport([1,120,0]) == 120)
    #expect(FoldMath.decodeReport([1,0,0]) == 0)
    #expect(FoldMath.decodeReport([1,180,0]) == 180)
    #expect(FoldMath.decodeReport([1,120]) == nil)
    #expect(FoldMath.decodeReport([2,120,0]) == nil)
    #expect(FoldMath.decodeReport([1,255,255]) == nil)
}
@Test func desktopIsUnmodifiedAboveClearAngleAndVanishesAtClosed() {
    for clear in stride(from:60.0,through:140.0,by:5) {
        #expect(FoldMath.progress(angle:clear,clearAngle:clear) == 0)
        #expect(FoldMath.progress(angle:180,clearAngle:clear) == 0)
        #expect(FoldMath.progress(angle:5,clearAngle:clear) == 1)
        #expect(FoldMath.progress(angle:0,clearAngle:clear) == 1)
        var previous = 1.0
        for angle in stride(from:0.0,through:180.0,by:0.5) {
            let next = FoldMath.progress(angle:angle,clearAngle:clear)
            #expect((0...1).contains(next));#expect(next <= previous)
            previous = next
        }
    }
}
@Test func smoothingIsFrameRateIndependentAndNeverOvershoots() {
    func simulate(_ fps:Double) -> Double {
        var p = 0.0
        for _ in 0..<Int(fps/10) { p = FoldMath.smooth(current:p,target:1,dt:1/fps) }
        return p
    }
    #expect(abs(simulate(60)-simulate(120)) < 0.00001)
    var p = 0.0
    for _ in 0..<60 { p = FoldMath.smooth(current:p,target:1,dt:1/60);#expect((0...1).contains(p)) }
    for _ in 0..<60 { p = FoldMath.smooth(current:p,target:0,dt:1/60);#expect((0...1).contains(p)) }
    #expect(p == 0)
}
@Test func invalidNumbersFailOpen() {
    #expect(FoldMath.progress(angle:.nan,clearAngle:105) == 0)
    #expect(FoldMath.progress(angle:45,clearAngle:.infinity) == 0)
    #expect(FoldMath.smooth(current:.nan,target:1,dt:0.1) == 0)
}
