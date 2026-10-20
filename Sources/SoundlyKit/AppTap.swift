import CoreAudio
import Foundation

/// The device the system plays to, and what a tap needs to know about it.
struct OutputDevice: Equatable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var sampleRate: Double
    /// `kAudioDevicePropertyTransportType` (built-in, USB, Bluetooth…).
    var transport: UInt32

    /// AirPods and other Bluetooth outputs: the tap and the output already share
    /// the Bluetooth clock, and drift compensation on top of that makes the HAL
    /// add or drop a sample every fraction of a second — a rhythmic crackle
    /// (reported by FineTune, see THIRD_PARTY_NOTICES.md).
    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func currentDefault() -> OutputDevice? {
        guard let id = try? AudioObject.read(AudioObject.system, kAudioHardwarePropertyDefaultOutputDevice,
                                             as: AudioDeviceID.self, initial: 0),
              id != kAudioObjectUnknown,
              let uid = try? AudioObject.readString(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
        let name = (try? AudioObject.readString(id, kAudioObjectPropertyName)) ?? uid
        let rate = (try? AudioObject.read(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self, initial: 0)) ?? 0
        let transport = (try? AudioObject.read(id, kAudioDevicePropertyTransportType, as: UInt32.self, initial: 0)) ?? 0
        return OutputDevice(id: id, uid: uid, name: name, sampleRate: rate, transport: transport)
    }

    /// The device's preferred stereo pair, 0-based (Core Audio counts from 1).
    var stereoChannels: (left: Int32, right: Int32) {
        let pair = (try? AudioObject.readArray(id, kAudioDevicePropertyPreferredChannelsForStereo,
                                               scope: kAudioObjectPropertyScopeOutput, of: UInt32.self, initial: 0)) ?? []
        guard pair.count == 2, pair[0] > 0, pair[1] > 0 else { return (0, 1) }
        return (Int32(pair[0]) - 1, Int32(pair[1]) - 1)
    }
}

/// One app's process tap and the private aggregate device that plays it back.
///
/// The tap mixes the app's processes down to stereo with `mutedWhenTapped`: the
/// app's own stream is silenced only *while someone reads the tap*. The
/// aggregate holds the tap plus the current output device, and its IOProc copies
/// the tap to that output with the gain applied.
///
/// No app can be left muted by a dead Hone. From the SDK headers:
/// - `CATapMutedWhenTapped` (CATapDescription.h): audio "is captured by the tap
///   and also sent to the audio hardware until the tap is read by another audio
///   client. For the duration of the read activity on the tap no audio is sent
///   to the audio hardware." The only reader is this aggregate's IOProc, which
///   runs inside Hone: Hone quits, crashes or is killed → the reading stops →
///   the app is heard directly again.
/// - `privateTap` (CATapDescription.h): "only visible to the client process
///   that created the tap"; `kAudioAggregateDeviceIsPrivateKey` (AudioHardware.h):
///   private to the creating process and "not persistent across launches" of it.
///   Nothing outlives Hone, and no other app can see or reuse these objects.
///
/// Main thread only, except for the IOProc (see `TapRenderState`). Call
/// `invalidate()` before dropping it: that is what stops the audio.
@MainActor
final class AppTap {
    enum Failure: Error, CustomStringConvertible {
        case needsNewerSystem
        case coreAudio(CoreAudioError)
        case unsupportedFormat(String)
        /// The output has no stream the aggregate can play to (an aggregate or multi-output device).
        case unusableOutput(String)

        var description: String {
            switch self {
            case .needsNewerSystem: return "Precisa do macOS 14.2 ou mais recente."
            case .coreAudio(let error): return "Erro de áudio: \(error.description)."
            case .unsupportedFormat(let detail): return "Formato de áudio não suportado (\(detail))."
            case .unusableOutput(let name): return "A saída «\(name)» não pode ser usada (dispositivo agregado ou de várias saídas)."
            }
        }
    }

    private(set) var objectIDs: [AudioObjectID]
    let deviceUID: String
    private let description: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let state: UnsafeMutablePointer<TapRenderState>
    private var isValid = true

    /// `startGain` is where the ramp begins: 1 for a fresh tap (what the user was
    /// hearing), the current level for a rebuild (no audible jump).
    init(objectIDs: [AudioObjectID], appName: String, output: OutputDevice,
         startGain: Float, targetGain: Float) throws {
        self.objectIDs = objectIDs
        deviceUID = output.uid
        description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        description.uuid = UUID()
        description.name = "Hone Soundly — \(appName)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        let stereo = output.stereoChannels
        state = .allocate(capacity: 1)
        state.initialize(to: TapRenderState(targetGain: targetGain, currentGain: startGain,
                                            maxStepPerFrame: GainRamp.maxStep(sampleRate: output.sampleRate),
                                            tapBufferCount: 1, stereoLeft: stereo.left, stereoRight: stereo.right))
        do {
            try build(output: output, appName: appName)
        } catch {
            invalidate()
            throw error
        }
    }

    /// What the IOProc ramps towards (see `TapRenderState` for why a plain store is enough).
    var targetGain: Float {
        get { isValid ? state.pointee.targetGain : 1 }
        set { if isValid { state.pointee.targetGain = min(max(newValue, 0), 1) } }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw Failure.coreAudio(CoreAudioError(operation: operation, status: status)) }
    }

    private func build(output: OutputDevice, appName: String) throws {
        guard #available(macOS 14.2, *) else { throw Failure.needsNewerSystem }
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Criar o tap")

        // The IOProc reads Float32 PCM; anything else would play as noise.
        let format = try readFormat(tapID, kAudioTapPropertyFormat, "Ler o formato do tap")
        guard Self.isFloat32PCM(format) else {
            throw Failure.unsupportedFormat("tap \(format.mBitsPerChannel) bits, \(format.mChannelsPerFrame) canais")
        }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hone Soundly — \(appName)",
            kAudioAggregateDeviceUIDKey: "com.tiagof.hone.soundly.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // IO starts when the app first sends audio, not before.
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            // Drift compensation resamples the tap onto the output's clock — except
            // on Bluetooth, where both already follow the same clock (see `isBluetooth`).
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: !output.isBluetooth]],
        ]
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID),
                  "Criar o dispositivo agregado")

        // No output stream (the default output is itself an aggregate or a
        // multi-output device, which can't be nested): with `mutedWhenTapped` the
        // app would go silent, so give up and leave it untouched.
        let outputStreams = (try? AudioObject.readArray(aggregateID, kAudioDevicePropertyStreams,
                                                        scope: kAudioObjectPropertyScopeOutput,
                                                        of: AudioObjectID.self, initial: 0)) ?? []
        guard let stream = outputStreams.first else {
            throw Failure.unusableOutput(output.name)
        }
        // Output buffers must be Float32 too (they are on every Mac we know of; check anyway).
        let outFormat = try readFormat(stream, kAudioStreamPropertyVirtualFormat, "Ler o formato de saída")
        guard Self.isFloat32PCM(outFormat) else {
            throw Failure.unsupportedFormat("saída \(outFormat.mBitsPerChannel) bits")
        }

        // The aggregate runs at the output's rate: the ramp is measured in its frames.
        let rate = (try? AudioObject.read(aggregateID, kAudioDevicePropertyNominalSampleRate,
                                          as: Float64.self, initial: 0)) ?? output.sampleRate
        state.pointee.maxStepPerFrame = GainRamp.maxStep(sampleRate: rate > 0 ? rate : 48_000)

        // The aggregate's inputs are the output device's own inputs (a headset
        // mic, say) followed by the tap: only the trailing ones are ours.
        let aggregateInputs = AudioObject.streamCount(aggregateID, scope: kAudioObjectPropertyScopeInput)
        let deviceInputs = AudioObject.streamCount(output.id, scope: kAudioObjectPropertyScopeInput)
        let tapStreams = max(aggregateInputs - deviceInputs, 1)
        state.pointee.tapBufferCount = Int32(tapStreams)

        try check(AudioDeviceCreateIOProcID(aggregateID, soundlyIOProc, UnsafeMutableRawPointer(state), &procID),
                  "Criar o IOProc")
        if aggregateInputs > tapStreams {
            disableDeviceInputs(total: aggregateInputs, tapStreams: tapStreams)
        }
        try check(AudioDeviceStart(aggregateID, procID), "Arrancar o áudio")
    }

    /// Tells Core Audio the IOProc never reads the output device's own input
    /// streams, so they are never switched on: a duplex device (USB headset)
    /// would otherwise count as microphone use. Best effort.
    private func disableDeviceInputs(total: Int, tapStreams: Int) {
        guard let procID else { return }
        let header = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 12
        let size = header + total * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        defer { raw.deallocate() }
        // { void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[n]; } — variable length.
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(total), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for i in 0..<total {
            raw.storeBytes(of: UInt32(i >= total - tapStreams ? 1 : 0),
                           toByteOffset: header + i * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        var address = AudioObject.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        _ = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(size), raw)
    }

    /// Points the existing tap at a new set of processes (a helper appeared or
    /// went away) without rebuilding — no gap, no doubled audio. `false` when Core
    /// Audio refuses; the caller then rebuilds.
    func update(objectIDs newIDs: [AudioObjectID]) -> Bool {
        guard isValid, newIDs != objectIDs else { return isValid }
        description.processes = newIDs
        var address = AudioObject.address(kAudioTapPropertyDescription)
        var reference: CATapDescription = description
        let status = withUnsafeMutablePointer(to: &reference) { pointer in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer)
        }
        guard status == noErr else {
            description.processes = objectIDs
            return false
        }
        objectIDs = newIDs
        return true
    }

    /// Stops the audio and destroys everything, in reverse order. The app's own
    /// stream comes back as soon as the tap is no longer read. Safe to call twice.
    func invalidate() {
        guard isValid else { return }
        isValid = false
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                // Waits for an IOProc call in flight: after this, nothing reads `state`.
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        state.deinitialize(count: 1)
        state.deallocate()
    }

    private func readFormat(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            _ operation: String) throws -> AudioStreamBasicDescription {
        do {
            return try AudioObject.read(object, selector, as: AudioStreamBasicDescription.self,
                                        initial: AudioStreamBasicDescription())
        } catch let error as CoreAudioError {
            throw Failure.coreAudio(CoreAudioError(operation: operation, status: error.status))
        }
    }

    nonisolated static func isFloat32PCM(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
            && format.mChannelsPerFrame > 0
    }
}
