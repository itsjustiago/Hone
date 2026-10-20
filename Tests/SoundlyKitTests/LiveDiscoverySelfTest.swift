import XCTest
import CoreAudio
@testable import SoundlyKit

/// Real-hardware check, skipped unless asked for:
///
///     HONE_SOUNDLY_SELFTEST=1 swift test --filter LiveDiscoverySelfTest
///
/// Reads Core Audio's process list and the running apps, groups them the way the
/// mixer does and prints what it found. Read-only: it builds no tap, plays no
/// audio and never prompts (the permission is only preflighted).
final class LiveDiscoverySelfTest: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONE_SOUNDLY_SELFTEST"] == "1",
                          "real-hardware self-test: set HONE_SOUNDLY_SELFTEST=1")
    }

    func testListsAudioAppsOnThisMac() {
        let processes = AudioProcessReader.readAll()
        let apps = AudioProcessReader.runningApps()
        let byPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let host = getpid()
        let hone = "com.tiagof.hone"  // what the mixer excludes inside Hone

        print("SOUNDLY-SELFTEST permission (this test process, preflight only): \(AudioCapturePermission.current()), SPI available: \(AudioCapturePermission.isAvailable)")
        if let output = OutputDevice.currentDefault() {
            print("SOUNDLY-SELFTEST output: \(output.name) @ \(Int(output.sampleRate)) Hz, bluetooth: \(output.isBluetooth), stereo pair: \(output.stereoChannels)")
        } else {
            print("SOUNDLY-SELFTEST output: none")
        }
        print("SOUNDLY-SELFTEST \(processes.count) Core Audio process objects:")
        for process in processes.sorted(by: { $0.pid < $1.pid }) {
            let owner = AudioAppGrouping.owner(of: process, apps: byPID)
            let listed = owner.map { AudioAppGrouping.isListable($0, hostPID: host, hostBundleIDs: [hone]) } ?? false
            print("SOUNDLY-SELFTEST   pid \(process.pid) obj \(process.objectID) playing=\(process.isPlaying) bundle=\(process.bundleID ?? "-") responsible=\(process.responsiblePID.map(String.init) ?? "-") → \(owner?.bundleID ?? "no owner")\(listed ? "" : " (not listed)")")
        }

        let groups = AudioAppGrouping.groups(processes: processes, apps: apps,
                                             hostPID: host, hostBundleIDs: [hone])
        print("SOUNDLY-SELFTEST \(groups.count) apps in the mixer:")
        for group in groups.sorted(by: { $0.owner.name < $1.owner.name }) {
            let pids = Set(group.processes.map(\.pid)).sorted()
            print("SOUNDLY-SELFTEST   \(group.owner.name) [\(group.owner.bundleID)] pids \(pids) playing=\(group.isPlaying)")
        }
        XCTAssertFalse(groups.contains { $0.owner.pid == host || $0.owner.bundleID == hone }, "the host is never listed")
    }

    /// The whole engine, started for a moment with throwaway preferences (no saved
    /// level, so no tap): listeners register, apps are published, stop clears all.
    @MainActor
    func testMixerPublishesAppsWithoutTaps() {
        let suite = "soundly-selftest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let tool = SoundlyTool(defaults: defaults)
        tool.start()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let mixer = tool.mixer
        print("SOUNDLY-SELFTEST mixer: \(mixer.apps.count) apps, permission \(mixer.permission), output \(mixer.outputDeviceName ?? "none")")
        for app in mixer.apps {
            print("SOUNDLY-SELFTEST   \(app.isPlaying ? "▶" : "·") \(app.name) [\(app.id)] pids \(app.pids) status \(app.status)")
        }
        XCTAssertTrue(mixer.apps.allSatisfy { $0.status == .direct }, "untouched apps get no tap")
        XCTAssertFalse(mixer.apps.contains { $0.id == "com.tiagof.hone" }, "Hone never lists itself")
        XCTAssertEqual(mixer.apps.map(\.id), SoundlyApp.sorted(mixer.apps).map(\.id), "published sorted")
        tool.stop()
        XCTAssertFalse(tool.isRunning)
        XCTAssertTrue(mixer.apps.isEmpty)
    }
}
