import XCTest
import CoreAudio
@testable import SoundlyKit

final class GainRampTests: XCTestCase {
    func testStepCoversAFullSwingInTheRampDuration() {
        let step = GainRamp.maxStep(sampleRate: 48_000)
        XCTAssertEqual(step, 1 / 960, accuracy: 1e-9, "20 ms at 48 kHz = 960 frames")
        var gain: Float = 1
        var frames = 0
        while gain > 0 {
            gain = GainRamp.advance(gain, toward: 0, maxStep: step)
            frames += 1
        }
        XCTAssertEqual(frames, 960, accuracy: 1)
    }

    func testAdvanceLandsExactlyOnTarget() {
        XCTAssertEqual(GainRamp.advance(0.5, toward: 0.5004, maxStep: 0.001), 0.5004)
        XCTAssertEqual(GainRamp.advance(0.5, toward: 0.6, maxStep: 0.01), 0.51, accuracy: 1e-6)
        XCTAssertEqual(GainRamp.advance(0.5, toward: 0.4, maxStep: 0.01), 0.49, accuracy: 1e-6)
    }

    func testBadSampleRateDoesNotRamp() {
        XCTAssertEqual(GainRamp.maxStep(sampleRate: 0), 1)
    }
}

/// The IOProc's maths on synthetic buffer lists, the way the aggregate hands them over.
final class TapRendererTests: XCTestCase {
    /// Owns sample storage and a buffer list pointing into it.
    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>] = []

        /// One buffer per entry: (channels, interleaved samples or nil for a NULL buffer).
        init(_ buffers: [(channels: Int, samples: [Float]?)]) {
            // `allocate(maximumBuffers: 0)` traps: an empty list is room for one, counted as zero.
            list = AudioBufferList.allocate(maximumBuffers: max(buffers.count, 1))
            list.count = buffers.count
            for (i, buffer) in buffers.enumerated() {
                var data: UnsafeMutableRawPointer?
                var bytes = 0
                if let samples = buffer.samples {
                    let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(samples.count, 1))
                    pointer.initialize(from: samples, count: samples.count)
                    storage.append(pointer)
                    data = UnsafeMutableRawPointer(pointer)
                    bytes = samples.count * MemoryLayout<Float>.size
                }
                list[i] = AudioBuffer(mNumberChannels: UInt32(buffer.channels), mDataByteSize: UInt32(bytes), mData: data)
            }
        }

        func samples(_ index: Int) -> [Float] {
            let buffer = list[index]
            guard let data = buffer.mData else { return [] }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }

        deinit {
            storage.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    private func render(_ input: Buffers, _ output: Buffers, gain: Float, start: Float? = nil,
                        step: Float = 1, tapBuffers: Int32 = 1, stereo: (Int32, Int32) = (0, 1)) -> Float {
        var state = TapRenderState(targetGain: gain, currentGain: start ?? gain, maxStepPerFrame: step,
                                   tapBufferCount: tapBuffers, stereoLeft: stereo.0, stereoRight: stereo.1)
        TapRenderer.render(input: UnsafePointer(input.list.unsafeMutablePointer),
                           output: output.list.unsafeMutablePointer, state: &state)
        return state.currentGain
    }

    private func zeros(_ count: Int) -> [Float] { Array(repeating: 9, count: count) }  // 9 = stale garbage

    func testStereoInterleavedGetsTheGain() {
        let input = Buffers([(2, [1, -1, 0.5, -0.5])])
        let output = Buffers([(2, zeros(4))])
        _ = render(input, output, gain: 0.5)
        XCTAssertEqual(output.samples(0), [0.5, -0.5, 0.25, -0.25])
    }

    func testRampMovesPerFrameAndIsRemembered() {
        let input = Buffers([(2, [1, 1, 1, 1, 1, 1])])
        let output = Buffers([(2, zeros(6))])
        let end = render(input, output, gain: 0.7, start: 1, step: 0.1)
        let out = output.samples(0)
        XCTAssertEqual(out[0], 0.9, accuracy: 1e-6)
        XCTAssertEqual(out[2], 0.8, accuracy: 1e-6)
        XCTAssertEqual(out[4], 0.7, accuracy: 1e-6)
        XCTAssertEqual(end, 0.7, accuracy: 1e-6, "the next cycle continues from here")
    }

    func testOnlyTheTrailingTapBuffersAreRead() {
        // The output device's own (unused) input comes first, then the tap.
        let input = Buffers([(1, [7, 7]), (2, [0.25, 0.5, 0.75, 1])])
        let output = Buffers([(2, zeros(4))])
        _ = render(input, output, gain: 1)
        XCTAssertEqual(output.samples(0), [0.25, 0.5, 0.75, 1])
    }

    func testNonInterleavedOutputGetsLeftAndRight() {
        let input = Buffers([(2, [1, 2, 3, 4])])
        let output = Buffers([(1, zeros(2)), (1, zeros(2))])
        _ = render(input, output, gain: 1)
        XCTAssertEqual(output.samples(0), [1, 3])
        XCTAssertEqual(output.samples(1), [2, 4])
    }

    func testMultichannelOutputUsesPreferredPairAndSilencesTheRest() {
        let input = Buffers([(2, [1, 2])])
        let output = Buffers([(4, zeros(4))])
        _ = render(input, output, gain: 1, stereo: (2, 3))
        XCTAssertEqual(output.samples(0), [0, 0, 1, 2])
    }

    func testMonoOutputDownmixes() {
        let input = Buffers([(2, [1, 0, 0.5, 0.5])])
        let output = Buffers([(1, zeros(2))])
        _ = render(input, output, gain: 1)
        XCTAssertEqual(output.samples(0), [0.5, 0.5])
    }

    func testMonoTapFeedsBothSides() {
        let input = Buffers([(1, [0.5, 1])])
        let output = Buffers([(2, zeros(4))])
        _ = render(input, output, gain: 1)
        XCTAssertEqual(output.samples(0), [0.5, 0.5, 1, 1])
    }

    func testShortOrMissingTapIsSilenceNotGarbage() {
        let short = Buffers([(2, [1, 1])])
        let output = Buffers([(2, zeros(6))])
        _ = render(short, output, gain: 1)
        XCTAssertEqual(output.samples(0), [1, 1, 0, 0, 0, 0])

        let missing = Buffers([(2, nil)])
        let output2 = Buffers([(2, zeros(4))])
        _ = render(missing, output2, gain: 1)
        XCTAssertEqual(output2.samples(0), [0, 0, 0, 0])

        let noTap = Buffers([])
        let output3 = Buffers([(2, zeros(2))])
        _ = render(noTap, output3, gain: 1, tapBuffers: 0)
        XCTAssertEqual(output3.samples(0), [0, 0])
    }

    func testOutOfRangeTargetIsClamped() {
        let input = Buffers([(2, [1, 1])])
        let output = Buffers([(2, zeros(2))])
        _ = render(input, output, gain: .nan, start: 0)
        XCTAssertEqual(output.samples(0), [0, 0])
        let output2 = Buffers([(2, zeros(2))])
        _ = render(input, output2, gain: 3, start: 1)
        XCTAssertEqual(output2.samples(0), [1, 1], "capped at 200 %, and a full-scale peak isn't boosted further")
    }

    // MARK: Boost and limiter

    /// Interleaved stereo sine, the same on both sides.
    private func sine(amplitude: Float, frames: Int, hz: Double = 1_000, rate: Double = 48_000) -> [Float] {
        (0..<frames).flatMap { frame -> [Float] in
            let value = amplitude * Float(sin(2 * .pi * hz * Double(frame) / rate))
            return [value, value]
        }
    }

    /// Renders with a state that outlives the call, the way consecutive IO cycles share it.
    private func render(_ input: Buffers, _ output: Buffers, state: inout TapRenderState) {
        TapRenderer.render(input: UnsafePointer(input.list.unsafeMutablePointer),
                           output: output.list.unsafeMutablePointer, state: &state)
    }

    private func boostState(_ gain: Float, start: Float? = nil) -> TapRenderState {
        TapRenderState(targetGain: gain, currentGain: start ?? gain, maxStepPerFrame: 1,
                       tapBufferCount: 1, stereoLeft: 0, stereoRight: 1)
    }

    func testMaxGainMatchesTheTopOfTheSlider() {
        XCTAssertEqual(TapRenderer.maxGain, Float(SoundlyLevel.maximumVolume))
    }

    func testFullScaleSineAtDoubleGainNeverClips() {
        let samples = sine(amplitude: 1, frames: 4_800)
        let input = Buffers([(2, samples)])
        let output = Buffers([(2, zeros(samples.count))])
        var state = boostState(2)
        render(input, output, state: &state)
        let out = output.samples(0)
        XCTAssertLessThanOrEqual(out.map(\.magnitude).max() ?? 9, 1)
        // Never quieter than at 100 % either: the limiter only takes back the boost.
        for (o, i) in zip(out, samples) {
            XCTAssertGreaterThanOrEqual(o.magnitude, i.magnitude - 1e-6)
        }
    }

    func testBoostedPeaksStayUnderTheCeiling() {
        let samples = sine(amplitude: 0.6, frames: 4_800)
        let input = Buffers([(2, samples)])
        let output = Buffers([(2, zeros(samples.count))])
        var state = boostState(2)
        render(input, output, state: &state)
        let peak = output.samples(0).map(\.magnitude).max() ?? 9
        XCTAssertLessThan(peak, PeakLimiter.defaultCeiling)
        XCTAssertGreaterThan(peak, 0.8, "still louder than the 0.6 the app plays")
        // After the first peak the gain holds: later cycles are a clean, scaled
        // sine, its peak where the knee puts 2 × 0.6.
        let steady = Array(output.samples(0)[1_920...])  // from the 20th cycle
        XCTAssertEqual(steady.map(\.magnitude).max() ?? 0, PeakLimiter().shaped(1.2), accuracy: 1e-4)
    }

    func testKneeIsLinearBelowAndNeverReachesTheCeiling() {
        let limiter = PeakLimiter()
        XCTAssertEqual(limiter.shaped(0.3), 0.3)
        XCTAssertEqual(limiter.shaped(PeakLimiter.defaultKnee), PeakLimiter.defaultKnee)
        // Slope 1 on both sides of the knee: no kink where it starts.
        let h: Float = 1e-3
        XCTAssertEqual((limiter.shaped(0.5 + h) - limiter.shaped(0.5)) / h, 1, accuracy: 2e-3)
        var last: Float = 0
        for level in stride(from: Float(0), through: 8, by: 0.01) {
            let out = limiter.shaped(level)
            // Under it as far as a full-scale pair summed at 200 % (4); at the
            // ceiling, not over, once Float rounds the curve's last bit away.
            if level <= 4 {
                XCTAssertLessThan(out, PeakLimiter.defaultCeiling, "\(level)")
            } else {
                XCTAssertLessThanOrEqual(out, PeakLimiter.defaultCeiling, "\(level)")
            }
            XCTAssertGreaterThanOrEqual(out, last, "rises with the level")
            last = out
        }
    }

    func testQuietSignalIsBoostedUntouched() {
        let input = Buffers([(2, [0.2, -0.2, 0.1, 0.25])])
        let output = Buffers([(2, zeros(4))])
        _ = render(input, output, gain: 2)
        XCTAssertEqual(output.samples(0), [0.4, -0.4, 0.2, 0.5], "up to the knee: plain gain, no limiting")
    }

    func testAtOrBelowFullVolumeTheOutputIsBitIdentical() {
        // Hot enough that the limiter would act if it ran.
        let samples = sine(amplitude: 1, frames: 480) + [1, -1, 0.95, 0.999]
        for gain: Float in [1, 0.8, 0.35, 0] {
            let input = Buffers([(2, samples)])
            let output = Buffers([(2, zeros(samples.count))])
            var state = boostState(gain)
            state.limiter.envelope = 1.5  // leftovers from an earlier boost change nothing
            render(input, output, state: &state)
            XCTAssertEqual(output.samples(0), samples.map { $0 * gain }, "gain \(gain)")
            XCTAssertEqual(state.limiter.envelope, 0)
        }
    }

    func testRampingDownThroughFullVolumeIsContinuous() {
        // 2 → 0.5 over the cycle on a hot signal: no jump where the limiter lets go.
        let samples = [Float](repeating: 0.9, count: 400)
        let input = Buffers([(2, samples)])
        let output = Buffers([(2, zeros(samples.count))])
        var state = boostState(0.5, start: 2)
        state.maxStepPerFrame = 0.01
        render(input, output, state: &state)
        let out = output.samples(0)
        for i in stride(from: 2, to: out.count, by: 2) {
            XCTAssertLessThanOrEqual(abs(out[i] - out[i - 2]), 0.01, "frame \(i / 2)")
        }
    }

    func testNonInterleavedSidesGetTheSameLimiting() {
        let samples = sine(amplitude: 0.8, frames: 960)
        let interleaved = Buffers([(2, samples)])
        let outA = Buffers([(2, zeros(samples.count))])
        var stateA = boostState(2)
        render(interleaved, outA, state: &stateA)

        let outB = Buffers([(1, zeros(960)), (1, zeros(960))])
        var stateB = boostState(2)
        render(interleaved, outB, state: &stateB)
        let a = outA.samples(0)
        XCTAssertEqual(outB.samples(0), stride(from: 0, to: a.count, by: 2).map { a[$0] })
        XCTAssertEqual(outB.samples(1), stride(from: 1, to: a.count, by: 2).map { a[$0] })
        XCTAssertEqual(stateA.limiter.envelope, stateB.limiter.envelope)
    }

    func testSilenceAfterABoostedPeakLeavesNoSubnormals() {
        var state = boostState(2)
        render(Buffers([(2, [1, 1])]), Buffers([(2, zeros(2))]), state: &state)
        XCTAssertGreaterThan(state.limiter.envelope, PeakLimiter.defaultCeiling)

        // Five seconds of silence, one 10 ms cycle at a time.
        for _ in 0..<500 {
            let output = Buffers([(2, zeros(960))])
            render(Buffers([(2, [Float](repeating: 0, count: 960))]), output, state: &state)
            XCTAssertTrue(output.samples(0).allSatisfy { $0 == 0 })
        }
        XCTAssertEqual(state.limiter.envelope, 0, "released all the way, not decayed into subnormals")
        XCTAssertFalse(state.currentGain.isNaN)
    }

    func testNaNInTheTapDoesNotStickInTheLimiter() {
        var state = boostState(2)
        render(Buffers([(2, [.nan, .nan, .infinity, 0.5])]), Buffers([(2, zeros(4))]), state: &state)
        XCTAssertTrue(state.limiter.envelope.isFinite)
        let output = Buffers([(2, zeros(4))])
        render(Buffers([(2, [0.25, 0.25, 0.3, -0.3])]), output, state: &state)
        XCTAssertTrue(output.samples(0).allSatisfy(\.isFinite))
    }

    // MARK: Limiter, every path through the IOProc

    /// One channel's samples of an interleaved buffer.
    private func side(_ samples: [Float], _ channel: Int, of channels: Int = 2) -> [Float] {
        stride(from: channel, to: samples.count, by: channels).map { samples[$0] }
    }

    private func peak(_ samples: [Float]) -> Float { samples.map(\.magnitude).max() ?? 9 }

    func testBothSidesOnOneChannelAreLimitedOnTheirSum() {
        // A device whose preferred pair is one channel twice: L + R land together.
        let samples = sine(amplitude: 0.4, frames: 960)
        let output = Buffers([(2, zeros(samples.count))])
        var state = boostState(2)
        state.stereoRight = 0
        render(Buffers([(2, samples)]), output, state: &state)
        let out = output.samples(0)
        XCTAssertLessThan(peak(side(out, 0)), PeakLimiter.defaultCeiling, "the limiter saw |L| + |R|, not the louder side")
        XCTAssertGreaterThan(peak(side(out, 0)), 0.8, "0.8 summed, still boosted")
        XCTAssertTrue(side(out, 1).allSatisfy { $0 == 0 })
    }

    func testMonoOutputIsLimitedLikeEitherSide() {
        let samples = sine(amplitude: 0.8, frames: 960)
        let mono = Buffers([(1, zeros(960))])
        var monoState = boostState(2)
        render(Buffers([(2, samples)]), mono, state: &monoState)
        let stereo = Buffers([(2, zeros(samples.count))])
        var stereoState = boostState(2)
        render(Buffers([(2, samples)]), stereo, state: &stereoState)

        XCTAssertLessThan(peak(mono.samples(0)), PeakLimiter.defaultCeiling)
        XCTAssertGreaterThan(peak(mono.samples(0)), 0.8, "boosted")
        XCTAssertEqual(mono.samples(0), side(stereo.samples(0), 0), "the downmix of two equal sides is either side")
    }

    func testBoostedMonoTapIsLimitedTheSameOnBothSides() {
        let tone = side(sine(amplitude: 0.6, frames: 960), 0)
        let output = Buffers([(2, zeros(1_920))])
        var state = boostState(2)
        render(Buffers([(1, tone)]), output, state: &state)
        let reference = Buffers([(2, zeros(1_920))])
        var referenceState = boostState(2)
        render(Buffers([(2, sine(amplitude: 0.6, frames: 960))]), reference, state: &referenceState)

        XCTAssertEqual(output.samples(0), reference.samples(0), "a mono tap is a stereo one with equal sides")
        XCTAssertLessThan(peak(output.samples(0)), PeakLimiter.defaultCeiling)
        XCTAssertGreaterThan(peak(output.samples(0)), 0.8)
    }

    func testRampingUpThroughFullVolumeStaysUnderTheCeilingAndIsContinuous() {
        // 0.5 → 2 over 300 of 400 frames, crossing 100 % at frame 100.
        let level = Buffers([(2, [Float](repeating: 0.6, count: 800))])
        let output = Buffers([(2, zeros(800))])
        var state = boostState(2, start: 0.5)
        state.maxStepPerFrame = 0.005
        render(level, output, state: &state)
        let out = side(output.samples(0), 0)
        XCTAssertLessThan(peak(out), PeakLimiter.defaultCeiling)
        for i in 1..<out.count {
            XCTAssertLessThanOrEqual(abs(out[i] - out[i - 1]), 0.6 * 0.005 + 1e-6, "frame \(i)")
        }
        XCTAssertEqual(state.currentGain, 2)

        let hot = sine(amplitude: 0.8, frames: 400)
        let output2 = Buffers([(2, zeros(hot.count))])
        var state2 = boostState(2, start: 0.5)
        state2.maxStepPerFrame = 0.005
        render(Buffers([(2, hot)]), output2, state: &state2)
        XCTAssertLessThan(peak(output2.samples(0)), PeakLimiter.defaultCeiling)
    }

    func testOneLongCycleMatchesTenShortOnes() {
        // Two tones, uneven sides, a ramp up to 200 % under way: ramp and limiter
        // must carry over from one cycle to the next exactly.
        let samples = (0..<4_800).flatMap { frame -> [Float] in
            let t = Double(frame) / 48_000
            let value = Float(0.5 * sin(2 * .pi * 220 * t) + 0.35 * sin(2 * .pi * 1_330 * t))
            return [value, value * 0.7]
        }
        var longState = boostState(2, start: 1)
        longState.maxStepPerFrame = GainRamp.maxStep(sampleRate: 48_000)
        var shortState = longState

        let long = Buffers([(2, zeros(samples.count))])
        render(Buffers([(2, samples)]), long, state: &longState)

        var short: [Float] = []
        for cycle in 0..<10 {
            let slice = Array(samples[(cycle * 960)..<((cycle + 1) * 960)])
            let output = Buffers([(2, zeros(slice.count))])
            render(Buffers([(2, slice)]), output, state: &shortState)
            short += output.samples(0)
        }
        XCTAssertEqual(short, long.samples(0))
        XCTAssertEqual(shortState.currentGain, longState.currentGain)
        XCTAssertEqual(shortState.limiter.envelope, longState.limiter.envelope)
        XCTAssertEqual(shortState.limiter.holdLeft, longState.limiter.holdLeft)
    }

    func testLoweringTheGainNeverDipsBelowTheNewLevel() {
        // Limited at 200 %, then down to 150 %: from then on, never quieter than
        // 150 % limited from scratch.
        let samples = sine(amplitude: 0.6, frames: 3_360)
        let before = Array(samples[..<1_920]), after = Array(samples[1_920...])
        var state = boostState(2)
        render(Buffers([(2, before)]), Buffers([(2, zeros(before.count))]), state: &state)
        state.targetGain = 1.5
        state.maxStepPerFrame = GainRamp.maxStep(sampleRate: 48_000)
        let output = Buffers([(2, zeros(after.count))])
        render(Buffers([(2, after)]), output, state: &state)

        let reference = Buffers([(2, zeros(samples.count))])
        var referenceState = boostState(1.5)
        render(Buffers([(2, samples)]), reference, state: &referenceState)
        let expected = Array(reference.samples(0)[1_920...])
        let out = output.samples(0)
        for i in 0..<out.count {
            XCTAssertGreaterThanOrEqual(out[i].magnitude, expected[i].magnitude - 1e-6, "sample \(i)")
        }
    }

    func testTransientAfterSilenceIsNotFlattened() {
        // A 100 Hz note out of silence at 200 %: its first rising edge must keep
        // rising (soft knee), not sit on the ceiling for a run of samples.
        let samples = [Float](repeating: 0, count: 960) + sine(amplitude: 0.6, frames: 480, hz: 100)
        let output = Buffers([(2, zeros(samples.count))])
        var state = boostState(2)
        render(Buffers([(2, samples)]), output, state: &state)
        let out = side(output.samples(0), 0)
        let note = Array(out[480..<720])  // its first half-cycle
        let top = peak(note)
        XCTAssertLessThan(top, PeakLimiter.defaultCeiling)
        XCTAssertLessThanOrEqual(note.filter { $0 >= top - 1e-4 }.count, 6, "no plateau at the top")
        for i in 481...600 {  // the rising quarter-cycle, up to the peak
            XCTAssertGreaterThan(out[i], out[i - 1], "frame \(i)")
        }
        let input = side(samples, 0)
        for i in 480..<960 {
            XCTAssertGreaterThanOrEqual(out[i].magnitude, input[i].magnitude - 1e-6, "never under 100 %")
        }
    }

    func testLimiterTimesFollowTheSampleRate() {
        let limiter = PeakLimiter(sampleRate: 44_100)
        XCTAssertEqual(limiter.holdFrames, 882)
        XCTAssertEqual(limiter.release, Float(exp(-1 / (44_100 * 0.15))), accuracy: 1e-9)
        XCTAssertEqual(PeakLimiter(sampleRate: 0).holdFrames, 960, "a bad rate falls back to 48 kHz")
    }

    func testFloat32Check() {
        var format = AudioStreamBasicDescription()
        format.mFormatID = kAudioFormatLinearPCM
        format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        format.mBitsPerChannel = 32
        format.mChannelsPerFrame = 2
        XCTAssertTrue(AppTap.isFloat32PCM(format))
        format.mBitsPerChannel = 16
        format.mFormatFlags = kAudioFormatFlagIsSignedInteger
        XCTAssertFalse(AppTap.isFloat32PCM(format))
    }
}
