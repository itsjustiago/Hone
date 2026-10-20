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
    /// 0…2, what the ramp heads for. Main thread writes, IOProc reads.
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
    /// Set to 1 by the IOProc on every cycle, read by the main thread: the tap is
    /// being read, so the app's own stream is muted (`mutedWhenTapped`). Same
    /// single-store argument as `targetGain`. Lets a rebuild retire the old tap
    /// only once the new one has taken over.
    var hasRendered: Int32 = 0
    /// Keeps a boost from clipping. Set up before `AudioDeviceStart`, then the
    /// IOProc's alone.
    var limiter = PeakLimiter()
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

/// Keeps a boost (gain above 1) from clipping, without touching anything at or
/// below 100 %. A stereo-linked peak limiter: it follows the loudest *input*
/// sample of each frame (before gain) with an instant attack, a short hold and a
/// smooth release, and gives back as much of the boost as the curve allows. It
/// only ever takes back the boost — never below what the app plays at 100 % — so
/// a level just over 100 % sounds exactly like 100 % and crossing it doesn't click.
///
/// The envelope is pre-gain, so lowering the gain mid-limiting lowers the level
/// at once instead of leaving a peak boosted at the old gain holding it down.
///
/// Soft knee, no look-ahead (that would delay the output at ≤ 100 % too): the
/// boosted envelope goes through `shaped`, linear up to `knee` (−6 dBFS) and
/// then easing exponentially towards `ceiling` with a continuous slope. With an
/// instant attack the envelope is never below the current sample, so the output
/// stays under `ceiling` with no clipper; the knee turns the first rising edge of
/// a transient into a gentle saturation rather than a flat top at the ceiling.
/// A timed attack was ruled out: it lets peaks through, and the clipper needed
/// to catch them would flatten them again.
///
/// Plain values only, owned by the IOProc: no allocation, lock or ARC.
/// `envelope` is either 0 or high enough to reach the knee once boosted, so
/// silence never decays it into subnormal floats.
struct PeakLimiter {
    /// -1 dBFS: what boosted peaks approach and never pass.
    static let defaultCeiling: Float = 0.891
    /// -6 dBFS: where the boost starts to be eased.
    static let defaultKnee: Float = 0.5
    /// A peak holds the gain down this long before it recovers: longer than the
    /// gap between peaks of a 25 Hz bass, so steady low notes aren't rippled.
    static let holdDuration: Double = 0.02
    /// Time constant of the recovery once the hold is over.
    static let releaseDuration: Double = 0.15

    /// Read in the IOProc, so stored rather than static (no lazy global there).
    var ceiling: Float
    var knee: Float
    var holdFrames: Int32
    /// Per-frame multiplier of the envelope while it recovers.
    var release: Float
    /// The input peak (before gain) being held or released; 0 while boosting it
    /// stays under the knee.
    var envelope: Float = 0
    var holdLeft: Int32 = 0

    init(sampleRate: Double = 48_000) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        ceiling = Self.defaultCeiling
        knee = Self.defaultKnee
        holdFrames = Int32((rate * Self.holdDuration).rounded())
        release = Float(exp(-1 / (rate * Self.releaseDuration)))
    }

    /// The gain to apply to a frame whose loudest tap sample is `peak` (before
    /// gain), when `gain` > 1. Between 1 and `gain`.
    @inline(__always)
    mutating func limitedGain(peak: Float, gain: Float) -> Float {
        var peak = peak
        if !(peak < .infinity) { peak = 0 }  // NaN or ∞ must not stick in the state
        if peak >= envelope {
            envelope = peak
            holdLeft = holdFrames
        } else if holdLeft > 0 {
            holdLeft -= 1
        } else {
            envelope *= release
            if envelope < peak { envelope = peak }
        }
        let level = envelope * gain
        guard level > knee else {
            envelope = 0
            return gain
        }
        let limited = shaped(level) / envelope
        if limited < 1 { return 1 }
        return limited < gain ? limited : gain
    }

    /// The level a boosted peak `level` comes out at: itself up to `knee`, then
    /// `knee + w·(1 − e^(−(level − knee)/w))` with `w = ceiling − knee`, which
    /// leaves the knee at slope 1 and tends to `ceiling` without passing it.
    @inline(__always)
    func shaped(_ level: Float) -> Float {
        guard level > knee else { return level }
        let width = ceiling - knee
        return knee + width * (1 - exp((knee - level) / width))
    }

    /// Back at or below 100 %: the next boost starts from scratch.
    @inline(__always)
    mutating func reset() {
        envelope = 0
        holdLeft = 0
    }
}

/// The IOProc's work: copy the tap (Float32, stereo or mono mixdown) into the
/// output buffers with the ramped gain, limited above 1 (`PeakLimiter`). Pure
/// pointer maths, so tests can feed it synthetic buffer lists. Whatever doesn't
/// line up (a missing buffer, fewer tap frames than output frames) is written as
/// silence, never left as garbage.
enum TapRenderer {
    /// `SoundlyLevel.maximumVolume` as a gain. Computed, so the IOProc reads a
    /// constant rather than a lazily initialised global.
    @inline(__always)
    static var maxGain: Float { 2 }

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
        if target > maxGain { target = maxGain }
        let step = state.pointee.maxStepPerFrame
        let start = state.pointee.currentGain
        var end = start
        let limiterStart = state.pointee.limiter
        var limiterEnd = limiterStart
        // Both sides land on one channel: the limiter must see their sum.
        let summed = outputChannels > 1 && leftOut == rightOut

        var offset = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            defer { offset += channels }
            guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            // Every buffer replays the same ramp and limiter from the start of
            // the cycle: they are the same frames, so both sides get the same gain.
            var gain = start
            var limiter = limiterStart
            for frame in 0..<frames {
                gain = GainRamp.advance(gain, toward: target, maxStep: step)
                let l = left.sample(frame)
                let r = right.sample(frame)
                // At or below 100 % the gain is applied as is: bit for bit what it was before boosting existed.
                var applied = gain
                if gain > 1 {
                    let peak = summed ? l.magnitude + r.magnitude
                        : (l.magnitude > r.magnitude ? l.magnitude : r.magnitude)
                    applied = limiter.limitedGain(peak: peak, gain: gain)
                } else {
                    limiter.reset()
                }
                let base = frame * channels
                if outputChannels == 1 {
                    data[base] = (l + r) * 0.5 * applied
                    continue
                }
                for c in 0..<channels {
                    let index = offset + c
                    var value: Float = 0
                    if index == leftOut { value += l }
                    if index == rightOut { value += r }
                    data[base + c] = value * applied
                }
            }
            end = gain
            limiterEnd = limiter
        }
        state.pointee.currentGain = end
        state.pointee.limiter = limiterEnd
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
    let state = clientData.assumingMemoryBound(to: TapRenderState.self)
    TapRenderer.render(input: input, output: output, state: state)
    state.pointee.hasRendered = 1
    return noErr
}
