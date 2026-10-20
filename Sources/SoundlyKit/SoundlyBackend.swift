import CoreAudio

/// One live tap, as the mixer drives it. `AppTap` in the app; a fake in tests.
@MainActor
protocol SoundlyTap: AnyObject {
    var objectIDs: [AudioObjectID] { get }
    /// What the IOProc ramps towards, 0…2 (above 1 the limiter keeps it from clipping).
    var targetGain: Float { get set }
    /// The IOProc has run: the tap is being read, so the app's own stream is muted.
    var hasRendered: Bool { get }
    /// Points the tap at another set of processes; `false` when refused (rebuild).
    func update(objectIDs: [AudioObjectID]) -> Bool
    /// Stops the audio and frees everything. Safe to call twice.
    func invalidate()
}

/// Everything the mixer asks of the system: Core Audio, Launch Services and TCC.
/// Behind a protocol so the mixer's state machine is tested without audio.
@MainActor
protocol SoundlyBackend: AnyObject {
    func readProcesses() -> [AudioProcessFacts]
    func runningApps() -> [RunningAppFacts]
    func isPlaying(_ object: AudioObjectID) -> Bool

    /// The TCC SPI is there, so the permission can be read and asked for.
    var canAskPermission: Bool { get }
    /// Preflight only: never prompts.
    func currentPermission() -> SoundlyPermission
    /// May show the system prompt. `completion` runs on the main queue.
    func requestPermission(_ completion: @escaping (Bool) -> Void)

    func defaultOutput() -> OutputDevice?
    /// The device as it is now; `nil` once it's gone.
    func device(_ id: AudioDeviceID) -> OutputDevice?
    /// Where the processes play now (see `OutputRouting`).
    func outputChoice(for objectIDs: [AudioObjectID]) -> OutputChoice

    func makeTap(objectIDs: [AudioObjectID], appName: String, output: OutputDevice,
                 startGain: Float, targetGain: Float) throws -> SoundlyTap
    /// A property listener, alive as long as the returned object (`nil` if it
    /// couldn't register). Handlers run on the main queue.
    func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope, handler: @escaping () -> Void) -> AnyObject?
}

/// The real thing.
@MainActor
final class CoreAudioBackend: SoundlyBackend {
    /// Holds no state: usable as a default argument.
    nonisolated init() {}

    func readProcesses() -> [AudioProcessFacts] { AudioProcessReader.readAll() }
    func runningApps() -> [RunningAppFacts] { AudioProcessReader.runningApps() }
    func isPlaying(_ object: AudioObjectID) -> Bool { AudioProcessReader.isPlaying(object) }

    var canAskPermission: Bool { AudioCapturePermission.isAvailable }
    func currentPermission() -> SoundlyPermission { AudioCapturePermission.current() }
    func requestPermission(_ completion: @escaping (Bool) -> Void) { AudioCapturePermission.request(completion) }

    func defaultOutput() -> OutputDevice? { OutputDevice.currentDefault() }
    func device(_ id: AudioDeviceID) -> OutputDevice? { OutputDevice.read(id) }

    func outputChoice(for objectIDs: [AudioObjectID]) -> OutputChoice {
        let devices = Set(objectIDs.flatMap(AudioProcessReader.outputDevices)).sorted()
        switch OutputRouting.route(devices.map(ProcessOutputDevice.read)) {
        case .undetermined: return .undetermined
        case .ambiguous: return .ambiguous
        case .unusable(let name): return .unusable(name: name)
        case .device(let id): return OutputDevice.read(id).map(OutputChoice.device) ?? .undetermined
        }
    }

    func makeTap(objectIDs: [AudioObjectID], appName: String, output: OutputDevice,
                 startGain: Float, targetGain: Float) throws -> SoundlyTap {
        try AppTap(objectIDs: objectIDs, appName: appName, output: output, startGain: startGain, targetGain: targetGain)
    }

    func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope, handler: @escaping () -> Void) -> AnyObject? {
        AudioPropertyListener(object: object, selector: selector, scope: scope, handler: handler)
    }
}
