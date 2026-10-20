import CoreAudio

/// Everything the IOProc reads, in memory allocated once per tap. The IOProc
/// runs on the real-time audio thread: it must not allocate, lock or touch ARC,
/// so it only ever sees this plain struct through an unsafe pointer.
///
/// `targetGain` is the one field the main thread writes while audio runs. An
/// aligned 32-bit store/load is a single instruction on arm64 and x86-64, so the
/// IOProc reads the old or the new value, never a torn one; at worst it picks a
/// new gain up one cycle (a few ms) late. The rest is set before
/// `AudioDeviceStart` and then belongs to the IOProc.
struct TapRenderState {
    /// 0…1, what the ramp heads for. Main thread writes, IOProc reads.
    var targetGain: Float
    /// Where the ramp is. IOProc only once started.
    var currentGain: Float
    /// Largest gain change per frame (see `GainRamp`).
    var maxStepPerFrame: Float
    /// How many of the aggregate's input buffers, counted from the end, are the
    /// tap. The ones before belong to the output device's own inputs (unused).
    var tapBufferCount: Int32
    /// Output channels (0-based, across all output buffers) that get the tap's
    /// left and right: the device's preferred stereo pair.
    var stereoLeft: Int32
    var stereoRight: Int32
}

/// A linear gain ramp: the gain moves towards its target by at most
/// `maxStep` per frame, so a full 0↔1 swing takes `duration` and smaller moves
/// take proportionally less. Enough to avoid the click of a sudden step.
enum GainRamp {
    static let duration: Double = 0.02

    static func maxStep(sampleRate: Double, duration: Double = duration) -> Float {
        guard sampleRate > 0, duration > 0 else { return 1 }
        return Float(1 / (sampleRate * duration))
    }

    @inline(__always)
    static func advance(_ current: Float, toward target: Float, maxStep: Float) -> Float {
        let delta = target - current
        if delta > maxStep { return current + maxStep }
        if delta < -maxStep { return current - maxStep }
        return target
    }
}

/// The IOProc's work: copy the tap (Float32, stereo or mono mixdown) into the
/// output buffers with the ramped gain. Pure pointer maths, so tests can feed it
/// synthetic buffer lists. Whatever doesn't line up (a missing buffer, fewer tap
/// frames than output frames) is written as silence, never left as garbage.
enum TapRenderer {
    /// One tap channel as a strided view into an input buffer.
    private struct Channel {
        var samples: UnsafePointer<Float>?
        var stride: Int
        var frames: Int

        static let silent = Channel(samples: nil, stride: 1, frames: 0)

        @inline(__always)
        func sample(_ frame: Int) -> Float {
            guard let samples, frame < frames else { return 0 }
            return samples[frame * stride]
        }
    }

    static func render(input: UnsafePointer<AudioBufferList>,
                       output: UnsafeMutablePointer<AudioBufferList>,
                       state: UnsafeMutablePointer<TapRenderState>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        let tapCount = min(max(Int(state.pointee.tapBufferCount), 0), inputs.count)
        let firstTap = inputs.count - tapCount
        let left = channel(0, in: inputs, from: firstTap) ?? .silent
        // A mono tap feeds both sides.
        let right = channel(1, in: inputs, from: firstTap) ?? left

        var outputChannels = 0
        for buffer in outputs { outputChannels += Int(buffer.mNumberChannels) }
        let lastChannel = max(outputChannels - 1, 0)
        let leftOut = min(max(Int(state.pointee.stereoLeft), 0), lastChannel)
        let rightOut = min(max(Int(state.pointee.stereoRight), 0), lastChannel)

        var target = state.pointee.targetGain
        if !(target >= 0) { target = 0 }  // NaN too
        if target > 1 { target = 1 }
        let step = state.pointee.maxStepPerFrame
        let start = state.pointee.currentGain
        var end = start

        var offset = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            defer { offset += channels }
            guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            // Every buffer replays the same ramp from `start`: they are the same frames.
            var gain = start
            for frame in 0..<frames {
                gain = GainRamp.advance(gain, toward: target, maxStep: step)
                let base = frame * channels
                if outputChannels == 1 {
                    data[base] = (left.sample(frame) + right.sample(frame)) * 0.5 * gain
                    continue
                }
                for c in 0..<channels {
                    let index = offset + c
                    var value: Float = 0
                    if index == leftOut { value += left.sample(frame) }
                    if index == rightOut { value += right.sample(frame) }
                    data[base + c] = value * gain
                }
            }
            end = gain
        }
        state.pointee.currentGain = end
    }

    /// Channel `index` of the tap, counting channels across the tap's buffers
    /// (interleaved or not). `nil` when the tap has fewer channels.
    private static func channel(_ index: Int, in inputs: UnsafeMutableAudioBufferListPointer, from first: Int) -> Channel? {
        var base = 0
        for i in first..<inputs.count {
            let buffer = inputs[i]
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            if index < base + channels {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return .silent }
                return Channel(samples: UnsafePointer(data + (index - base)), stride: channels,
                               frames: Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            }
            base += channels
        }
        return nil
    }
}

/// The C IOProc. Captures nothing: its only context is the `TapRenderState`
/// pointer handed over as client data, so no Swift closure context, no retain.
let soundlyIOProc: AudioDeviceIOProc = { _, _, input, _, output, _, clientData in
    guard let clientData else { return noErr }
    TapRenderer.render(input: input, output: output,
                       state: clientData.assumingMemoryBound(to: TapRenderState.self))
    return noErr
}
