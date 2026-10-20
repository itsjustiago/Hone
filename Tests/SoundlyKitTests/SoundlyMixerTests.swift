import XCTest
import CoreAudio
@testable import SoundlyKit

/// What happened, in order, across every fake tap of a test.
private final class EventLog {
    var events: [String] = []
}

@MainActor
private final class FakeTap: SoundlyTap {
    let serial: Int
    let output: OutputDevice
    let startGain: Float
    var objectIDs: [AudioObjectID]
    var targetGain: Float
    var hasRendered = false
    var refusesUpdate = false
    private(set) var isInvalidated = false
    private let log: EventLog

    init(serial: Int, objectIDs: [AudioObjectID], output: OutputDevice, startGain: Float, targetGain: Float, log: EventLog) {
        self.serial = serial
        self.objectIDs = objectIDs
        self.output = output
        self.startGain = startGain
        self.targetGain = targetGain
        self.log = log
        log.events.append("make \(serial)")
    }

    func update(objectIDs newIDs: [AudioObjectID]) -> Bool {
        guard !refusesUpdate else { return false }
        objectIDs = newIDs
        return true
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        log.events.append("invalidate \(serial)")
    }
}

@MainActor
private final class FakeBackend: SoundlyBackend {
    final class Token {}

    var processes: [AudioProcessFacts] = []
    var apps: [RunningAppFacts] = []
    var canAskPermission = true
    var permission: SoundlyPermission = .granted
    var permissionRequests: [(Bool) -> Void] = []
    var defaultDevice: OutputDevice?
    var devices: [AudioDeviceID: OutputDevice] = [:]
    /// Per process object; anything unset is `.undetermined`.
    var choices: [AudioObjectID: OutputChoice] = [:]
    var tapError: Error?
    var tapAttempts = 0
    private(set) var taps: [FakeTap] = []
    let log = EventLog()
    private var handlers: [String: () -> Void] = [:]

    func readProcesses() -> [AudioProcessFacts] { processes }
    func runningApps() -> [RunningAppFacts] { apps }
    func isPlaying(_ object: AudioObjectID) -> Bool { processes.first { $0.objectID == object }?.isPlaying ?? false }
    func currentPermission() -> SoundlyPermission { permission }
    func requestPermission(_ completion: @escaping (Bool) -> Void) { permissionRequests.append(completion) }
    func defaultOutput() -> OutputDevice? { defaultDevice }
    func device(_ id: AudioDeviceID) -> OutputDevice? { devices[id] }

    func outputChoice(for objectIDs: [AudioObjectID]) -> OutputChoice {
        let found = objectIDs.compactMap { choices[$0] }
        return found.first ?? .undetermined
    }

    func makeTap(objectIDs: [AudioObjectID], appName: String, output: OutputDevice,
                 startGain: Float, targetGain: Float) throws -> SoundlyTap {
        tapAttempts += 1
        if let tapError { throw tapError }
        let tap = FakeTap(serial: taps.count + 1, objectIDs: objectIDs, output: output,
                          startGain: startGain, targetGain: targetGain, log: log)
        taps.append(tap)
        return tap
    }

    func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope, handler: @escaping () -> Void) -> AnyObject? {
        handlers["\(object)/\(selector)"] = handler
        return Token()
    }

    func fire(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        handlers["\(object)/\(selector)"]?()
    }
}

@MainActor
final class SoundlyMixerTests: XCTestCase {
    private let speakers = OutputDevice(id: 50, uid: "BuiltInSpeakers", name: "Colunas", sampleRate: 48_000,
                                        transport: kAudioDeviceTransportTypeBuiltIn)
    private let headset = OutputDevice(id: 60, uid: "USBHeadset", name: "Headset USB", sampleRate: 48_000,
                                       transport: kAudioDeviceTransportTypeUSB)
    private let airPods = OutputDevice(id: 70, uid: "AirPods", name: "AirPods", sampleRate: 48_000,
                                       transport: kAudioDeviceTransportTypeBluetooth)
    private let spotify = "com.spotify.client"
    private let zoom = "us.zoom.xos"
    private let spotifyObject: AudioObjectID = 10
    private let zoomObject: AudioObjectID = 20

    private func makeMixer(permission: SoundlyPermission = .granted) -> (SoundlyMixer, FakeBackend) {
        let backend = FakeBackend()
        backend.permission = permission
        backend.defaultDevice = speakers
        backend.devices = [speakers.id: speakers, headset.id: headset, airPods.id: airPods]
        backend.apps = [
            RunningAppFacts(pid: 30_300, bundleID: spotify, name: "Spotify", bundlePath: "/Applications/Spotify.app", isUIApp: true),
            RunningAppFacts(pid: 30_700, bundleID: zoom, name: "zoom.us", bundlePath: "/Applications/zoom.us.app", isUIApp: true),
        ]
        backend.processes = [
            AudioProcessFacts(objectID: spotifyObject, pid: 30_300, bundleID: spotify, isPlaying: true,
                              responsiblePID: nil, executablePath: nil),
            AudioProcessFacts(objectID: zoomObject, pid: 30_700, bundleID: zoom, isPlaying: true,
                              responsiblePID: nil, executablePath: nil),
        ]
        let name = "soundly-mixer-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (SoundlyMixer(store: SoundlyStore(defaults: defaults), backend: backend), backend)
    }

    private func status(_ mixer: SoundlyMixer, _ appID: String) -> SoundlyApp.Status? {
        mixer.apps.first { $0.id == appID }?.status
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Output device (which device the tap plays to)

    func testTapPlaysToTheDeviceTheAppUses() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        backend.choices[zoomObject] = .device(headset)
        mixer.start()
        mixer.setVolume(0.5, for: zoom)
        XCTAssertEqual(backend.taps.map(\.output), [headset], "the call stays on the headset, not the default speakers")
        XCTAssertEqual(backend.taps.first?.startGain, 1)
        XCTAssertEqual(backend.taps.first?.targetGain ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(status(mixer, zoom), .adjusted)
    }

    func testUnknownOrAmbiguousDeviceFallsBackToTheDefault() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        backend.choices[zoomObject] = .ambiguous
        mixer.start()
        mixer.setVolume(0.5, for: zoom)
        mixer.setVolume(0.5, for: spotify)  // `.undetermined`: no device open
        XCTAssertEqual(backend.taps.map(\.output), [speakers, speakers])
    }

    func testUnusableDeviceMarksTheAppUnavailable() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        backend.choices[zoomObject] = .unusable(name: "Saída múltipla")
        mixer.start()
        mixer.setVolume(0.5, for: zoom)
        XCTAssertTrue(backend.taps.isEmpty)
        guard case .unavailable(let reason)? = status(mixer, zoom) else { return XCTFail("\(String(describing: status(mixer, zoom)))") }
        XCTAssertTrue(reason.contains("Saída múltipla"), reason)
    }

    func testAppMovingToAnotherDeviceRebuildsItsTapThere() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        mixer.start()
        mixer.setVolume(0.5, for: zoom)
        XCTAssertEqual(backend.taps.map(\.output), [speakers])

        backend.choices[zoomObject] = .device(headset)
        backend.fire(zoomObject, kAudioProcessPropertyDevices)
        XCTAssertEqual(backend.taps.map(\.output), [speakers, headset])
        XCTAssertEqual(backend.taps[1].startGain, 0, "the new tap fades in")
        XCTAssertEqual(backend.taps[1].targetGain, 0.5, accuracy: 1e-6)
        XCTAssertEqual(backend.taps[0].targetGain, 0, "the old one fades out…")
        XCTAssertFalse(backend.taps[0].isInvalidated, "…but keeps the app muted until the new one is read")
        XCTAssertEqual(status(mixer, zoom), .adjusted)

        // The same list again changes nothing.
        backend.fire(zoomObject, kAudioProcessPropertyDevices)
        XCTAssertEqual(backend.taps.count, 2)
    }

    func testPausedAppKeepsTheDeviceItChose() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        backend.choices[zoomObject] = .device(headset)
        mixer.start()
        mixer.setVolume(0.5, for: zoom)
        backend.choices[zoomObject] = .undetermined  // the call ended: no device open
        backend.fire(zoomObject, kAudioProcessPropertyDevices)
        XCTAssertEqual(backend.taps.count, 1, "no hop to the speakers between calls")
    }

    func testTapOnTheDefaultFollowsTheDefault() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        mixer.start()
        mixer.setMuted(true, for: spotify)
        XCTAssertEqual(backend.taps.map(\.output), [speakers])
        backend.defaultDevice = airPods
        mixer.outputDeviceChanged()
        XCTAssertEqual(backend.taps.map(\.output), [speakers, airPods])
        XCTAssertEqual(backend.taps[1].targetGain, 0)
        XCTAssertEqual(mixer.outputDeviceName, "AirPods")
    }

    // MARK: Rebuilds (crossfade, never destroy first)

    func testRebuildCreatesTheNewTapBeforeRetiringTheOld() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        mixer.start()
        mixer.setVolume(0.3, for: spotify)
        // Same device, new sample rate (AirPods to HFP, a lossless track…).
        var resampled = speakers
        resampled.sampleRate = 44_100
        backend.defaultDevice = resampled
        backend.devices[speakers.id] = resampled
        mixer.outputDeviceChanged()

        XCTAssertEqual(backend.log.events, ["make 1", "make 2"], "new tap first, old one untouched")
        XCTAssertEqual(backend.taps[0].targetGain, 0)
        XCTAssertEqual(backend.taps[1].startGain, 0)
        XCTAssertEqual(backend.taps[1].output.sampleRate, 44_100)

        wait(0.15)
        XCTAssertFalse(backend.taps[0].isInvalidated, "held while the new tap isn't read yet")

        backend.taps[1].hasRendered = true
        wait(0.15)
        XCTAssertEqual(backend.log.events, ["make 1", "make 2", "invalidate 1"])
        XCTAssertFalse(backend.taps[1].isInvalidated)
        XCTAssertEqual(status(mixer, spotify), .adjusted)
    }

    func testOldTapIsRetiredAfterATimeoutIfTheNewOneIsNeverRead() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        mixer.start()
        mixer.setVolume(0.3, for: spotify)
        backend.defaultDevice = airPods
        mixer.outputDeviceChanged()
        wait(SoundlyMixer.handoffTimeout + 0.2)
        XCTAssertTrue(backend.taps[0].isInvalidated)
        XCTAssertFalse(backend.taps[1].isInvalidated)
    }

    func testRefusedProcessUpdateCrossfadesToANewTap() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        mixer.start()
        mixer.setVolume(0.3, for: spotify)
        backend.taps[0].refusesUpdate = true
        backend.processes.append(AudioProcessFacts(objectID: 11, pid: 30_301, bundleID: "com.spotify.client.helper",
                                                   isPlaying: true, responsiblePID: 30_300, executablePath: nil))
        mixer.fallbackTick()
        XCTAssertEqual(backend.taps.count, 2)
        XCTAssertEqual(backend.taps[1].objectIDs, [10, 11])
        XCTAssertEqual(backend.taps[1].startGain, 0)
        XCTAssertEqual(backend.taps[0].targetGain, 0)
        XCTAssertFalse(backend.taps[0].isInvalidated)
    }

    func testFailedRebuildLetsGoOfTheOldTapAtOnce() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        mixer.start()
        mixer.setVolume(0.3, for: spotify)
        backend.tapError = AppTap.Failure.unsupportedFormat("teste")
        backend.defaultDevice = airPods
        mixer.outputDeviceChanged()
        XCTAssertTrue(backend.taps[0].isInvalidated, "held at 0 with no successor, it would keep the app silent")
        XCTAssertEqual(status(mixer, spotify), .unavailable(AppTap.Failure.unsupportedFormat("teste").description))
    }

    // MARK: Permission

    func testRefusedPermissionDropsLiveTaps() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        mixer.start()
        mixer.setMuted(true, for: spotify)
        XCTAssertEqual(status(mixer, spotify), .adjusted)

        backend.permission = .denied  // switched off in System Settings
        mixer.fallbackTick()
        XCTAssertTrue(backend.taps[0].isInvalidated, "an unfed muted tap would leave Spotify silent")
        XCTAssertEqual(mixer.permission, .denied)
        XCTAssertEqual(status(mixer, spotify), .needsPermission)
        XCTAssertTrue(backend.permissionRequests.isEmpty, "the tick only preflights")

        backend.permission = .granted
        mixer.fallbackTick()
        XCTAssertEqual(backend.taps.count, 2)
        XCTAssertEqual(status(mixer, spotify), .adjusted)
    }

    func testStartNeverPromptsAndUserActionDoes() {
        let (mixer, backend) = makeMixer(permission: .unknown)
        defer { mixer.stop() }
        mixer.start()
        mixer.fallbackTick()
        XCTAssertTrue(backend.permissionRequests.isEmpty)

        mixer.setVolume(0.4, for: spotify)
        XCTAssertEqual(backend.permissionRequests.count, 1)
        XCTAssertTrue(backend.taps.isEmpty, "no tap before the answer")
        XCTAssertEqual(status(mixer, spotify), .needsPermission)

        backend.permission = .denied
        backend.permissionRequests[0](false)
        XCTAssertTrue(backend.taps.isEmpty)
        XCTAssertEqual(status(mixer, spotify), .needsPermission)
    }

    func testGrantedAnswerAppliesTheLevel() {
        let (mixer, backend) = makeMixer(permission: .unknown)
        defer { mixer.stop() }
        mixer.start()
        mixer.setVolume(0.4, for: spotify)
        backend.permission = .granted
        backend.permissionRequests[0](true)
        XCTAssertEqual(backend.taps.count, 1)
        XCTAssertEqual(status(mixer, spotify), .adjusted)
    }

    // MARK: Release

    func testMovingBackOffTopWithinTheDelayKeepsTheTap() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        mixer.start()
        mixer.setVolume(0.5, for: spotify)
        mixer.setVolume(1, for: spotify)
        XCTAssertEqual(backend.taps[0].targetGain, 1, "ramps back up first")
        mixer.setVolume(0.4, for: spotify)
        wait(SoundlyMixer.releaseDelay * 2.5)
        XCTAssertFalse(backend.taps[0].isInvalidated, "the pending release was cancelled")
        XCTAssertEqual(backend.taps[0].targetGain, 0.4, accuracy: 1e-6)
        XCTAssertEqual(backend.taps.count, 1)
        XCTAssertEqual(status(mixer, spotify), .adjusted)
    }

    func testBackAtTopDropsTheTapAfterTheRamp() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        mixer.start()
        mixer.setVolume(0.5, for: spotify)
        mixer.setVolume(1, for: spotify)
        XCTAssertFalse(backend.taps[0].isInvalidated)
        wait(SoundlyMixer.releaseDelay * 2.5)
        XCTAssertTrue(backend.taps[0].isInvalidated)
        XCTAssertEqual(status(mixer, spotify), .direct)
    }

    // MARK: Failures

    func testFailureMarksUnavailableAndOnlyAUserActionRetries() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        backend.tapError = AppTap.Failure.inputsNotDisabled("Headset USB", -1)
        mixer.start()
        mixer.setVolume(0.5, for: zoom)
        XCTAssertEqual(status(mixer, zoom), .unavailable(AppTap.Failure.inputsNotDisabled("Headset USB", -1).description))
        mixer.fallbackTick()
        XCTAssertEqual(backend.tapAttempts, 1, "no retry loop on its own")

        backend.tapError = nil
        mixer.setVolume(0.4, for: zoom)
        XCTAssertEqual(backend.tapAttempts, 2)
        XCTAssertEqual(status(mixer, zoom), .adjusted)
    }

    func testAppQuittingDropsItsTapsIncludingOneBeingReplaced() {
        let (mixer, backend) = makeMixer()
        defer { mixer.stop() }
        mixer.start()
        mixer.setVolume(0.5, for: spotify)
        backend.defaultDevice = airPods
        mixer.outputDeviceChanged()
        backend.processes.removeAll { $0.objectID == spotifyObject }
        mixer.fallbackTick()
        XCTAssertTrue(backend.taps.allSatisfy(\.isInvalidated))
        XCTAssertNil(status(mixer, spotify))
    }

    func testStopLetsEveryAppGo() {
        let (mixer, backend) = makeMixer()
        mixer.start()
        mixer.setVolume(0.5, for: spotify)
        backend.defaultDevice = airPods
        mixer.outputDeviceChanged()
        mixer.stop()
        XCTAssertTrue(backend.taps.allSatisfy(\.isInvalidated))
        XCTAssertTrue(mixer.apps.isEmpty)
    }
}
