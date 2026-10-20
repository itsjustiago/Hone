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
        XCTAssertEqual(output2.samples(0), [1, 1])
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
