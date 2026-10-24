import AppKit
import XCTest
@testable import Hone

/// The client's life with a FAKE adapter: `/bin/sh -c <script>` stands in for perl +
/// the dylib, so nothing here ever touches MediaRemote or the user's music. Every
/// client is built with `launch:`; without it the client would look up the real
/// dylib next to the test binary.
///
/// The fakes talk the real protocol: JSON lines on stdout, and they wait on stdin
/// with `read` (a shell builtin, so no child process is left behind), which is also
/// how a test tells them to move on: `client.send(.play)` writes "play\n".
@MainActor
final class NowPlayingClientLifecycleTests: XCTestCase {
    private var directory: URL!
    private var counter: String { directory.appendingPathComponent("launches").path }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hone-np-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    private static let trackLine = #"echo '{"title":"First","artist":"Someone","playing":true,"rate":1,"elapsed":1}'"#

    /// `$1` is the launch counter file, `$2` the file the fake writes its pid to.
    private func fake(_ script: String) -> NowPlayingLaunch {
        NowPlayingLaunch(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "sh", counter, directory.appendingPathComponent("pid").path]
        )
    }

    /// Dies at once, every time.
    private var dying: NowPlayingLaunch { fake(#"echo x >> "$1"; exit 1"#) }

    /// Reports a track, waits for a command, reports nothing playing, waits for EOF.
    private var talking: NowPlayingLaunch {
        fake(#"""
        echo x >> "$1"; echo $$ > "$2"
        echo 'this line is not json'
        \#(Self.trackLine)
        read line
        echo '{"empty":true}'
        read line
        """#)
    }

    private func policy(maxFailures: Int, delay: TimeInterval = 0.02) -> NowPlayingRestartPolicy {
        NowPlayingRestartPolicy(delays: [delay], maxFailures: maxFailures, window: 600, healthyUptime: 600)
    }

    private func client(
        _ launch: NowPlayingLaunch,
        policy: NowPlayingRestartPolicy? = nil,
        wakeCenter: NotificationCenter = NotificationCenter(),
        slowRetryInterval: TimeInterval = 600
    ) -> NowPlayingClient {
        NowPlayingClient(
            launch: launch,
            restartPolicy: policy ?? self.policy(maxFailures: 3),
            wakeCenter: wakeCenter,
            slowRetryInterval: slowRetryInterval
        )
    }

    private var launches: Int {
        let text = (try? String(contentsOfFile: counter, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    /// Polls on the main run loop (the client's callbacks live there).
    @discardableResult
    private func wait(_ timeout: TimeInterval = 4, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// `wait`, failing the test on timeout.
    private func expect(
        _ message: String = "timed out waiting", timeout: TimeInterval = 4,
        file: StaticString = #filePath, line: UInt = #line, until condition: () -> Bool
    ) async {
        if await !wait(timeout, until: condition) { XCTFail(message, file: file, line: line) }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func wake(_ center: NotificationCenter) {
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    // MARK: Stopping

    func testStopIsIdempotent() async {
        let client = client(talking)
        client.stop()                       // never started
        client.stop()
        XCTAssertEqual(client.status, .stopped)

        client.start()
        XCTAssertEqual(client.status, .running)
        await wait { client.track != nil }
        client.stop()
        client.stop()
        XCTAssertEqual(client.status, .stopped)
        XCTAssertNil(client.track)

        // Commands to a stopped client are dropped, not a crash.
        client.send(.play)
        client.send(.seek(10))
    }

    func testStartTwiceLaunchesOnce() async {
        let client = client(talking)
        defer { client.stop() }
        client.start()
        client.start()
        await wait { client.track != nil }
        await pause(0.15)
        XCTAssertEqual(launches, 1)
    }

    func testNoProcessSurvivesStop() async throws {
        let client = client(talking)
        client.start()
        await expect { client.track != nil }

        let text = try String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8)
        let pid = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(isAlive(pid), "the fake adapter should be up while running")

        client.stop()
        await expect("the adapter outlived stop()") { !self.isAlive(pid) }
    }

    // MARK: Reading

    func testALineBecomesATrackAndEmptyClearsIt() async {
        let client = client(talking)
        defer { client.stop() }
        client.start()

        // The first line of the fake is garbage: skipped, not fatal.
        await expect { client.track != nil }
        XCTAssertEqual(client.track?.title, "First")
        XCTAssertEqual(client.track?.artist, "Someone")
        XCTAssertEqual(client.track?.isPlaying, true)
        XCTAssertEqual(client.status, .running)

        client.send(.play)                  // the fake reads it and answers {"empty":true}
        await expect { client.track == nil }
        XCTAssertEqual(client.status, .running)
    }

    // MARK: Dying

    func testAnAdapterThatKeepsDyingIsRestartedThenGivenUp() async {
        let client = client(dying)
        defer { client.stop() }
        client.start()

        await expect { client.status == .unavailable(NowPlayingClient.failedText) }
        XCTAssertEqual(launches, 3, "one launch per allowed failure, then no more")
        XCTAssertNil(client.track)

        await pause(0.2)
        XCTAssertEqual(launches, 3, "given up means given up")
    }

    func testAnAdapterThatRecoversKeepsRunning() async {
        let client = client(fake(#"""
        echo x >> "$1"
        if [ "$(wc -l < "$1")" -lt 2 ]; then exit 1; fi
        \#(Self.trackLine)
        read line
        """#))
        defer { client.stop() }
        client.start()

        await expect { client.track != nil }
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(client.status, .running)
    }

    func testStopCancelsARestartThatIsPending() async {
        let client = client(dying, policy: policy(maxFailures: 10, delay: 0.3))
        client.start()
        await expect { self.launches == 1 }
        client.stop()

        await pause(0.6)                    // the 0.3 s restart would have happened by now
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(client.status, .stopped)
    }

    // MARK: Coming back

    func testWakingUpRetriesAGivenUpAdapterFromScratch() async {
        let center = NotificationCenter()
        let client = client(dying, policy: policy(maxFailures: 2), wakeCenter: center)
        defer { client.stop() }
        client.start()
        await expect { client.status == .unavailable(NowPlayingClient.failedText) }
        XCTAssertEqual(launches, 2)

        wake(center)
        // A fresh policy: two more launches before it gives up again.
        await expect { self.launches == 4 }
        await expect { client.status == .unavailable(NowPlayingClient.failedText) }
    }

    func testWakingUpWhileRunningChangesNothing() async {
        let center = NotificationCenter()
        let client = client(talking, wakeCenter: center)
        defer { client.stop() }
        client.start()
        await expect { client.track != nil }

        wake(center)
        await pause(0.2)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(client.track?.title, "First")
    }

    func testWakingUpAfterStopDoesNothing() async {
        let center = NotificationCenter()
        let client = client(dying, policy: policy(maxFailures: 2), wakeCenter: center)
        client.start()
        await expect { client.status == .unavailable(NowPlayingClient.failedText) }
        client.stop()
        let before = launches

        wake(center)
        await pause(0.2)
        XCTAssertEqual(launches, before)
        XCTAssertEqual(client.status, .stopped)
    }

    func testAGivenUpAdapterIsRetriedSlowlyUntilStop() async {
        let client = client(dying, policy: policy(maxFailures: 2), slowRetryInterval: 0.15)
        client.start()

        // Two launches to give up, then a slow retry that launches two more.
        await expect { self.launches >= 4 }
        client.stop()
        await pause(0.15)                   // anything already in flight finishes writing
        let settled = launches

        await pause(0.5)                    // several slow-retry periods
        XCTAssertEqual(launches, settled, "the slow retry kept running after stop()")
        XCTAssertEqual(client.status, .stopped)
    }
}
