import AppKit
import Foundation
import Observation
import os

private let journal = Logger(subsystem: "com.tiagof.hone", category: "island")

/// Where the adapter lives and how it is started.
enum NowPlayingAdapter {
    static let libraryName = "libHoneNowPlaying.dylib"

    /// MediaRemote only answers Apple-entitled processes, and /usr/bin/perl is one:
    /// this loader pulls the dylib into it and calls the exported function, which
    /// never returns. The dylib path travels as argv so no quoting can break it.
    static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    static let loaderScript = """
    use DynaLoader;
    my $lib = DynaLoader::dl_load_file($ARGV[0], 0)
        or die "load: " . DynaLoader::dl_error() . "\\n";
    my $fn = DynaLoader::dl_find_symbol($lib, "hone_np_stream")
        or die "symbol: " . DynaLoader::dl_error() . "\\n";
    DynaLoader::dl_install_xsub("main::hone_np_stream", $fn);
    main::hone_np_stream();
    """

    /// The app bundle first (Contents/Frameworks), then next to the executable
    /// (`swift run` / .build/debug, where SwiftPM drops the dylib).
    static func locate(
        privateFrameworks: URL? = Bundle.main.privateFrameworksURL,
        executableDirectory: URL? = Bundle.main.executableURL?.deletingLastPathComponent(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        [privateFrameworks, executableDirectory]
            .compactMap { $0?.appendingPathComponent(libraryName) }
            .first { fileExists($0.path) }
    }
}

/// Runs the "now playing" adapter and publishes what it reports. Starts nothing
/// until `start()`; `stop()` leaves nothing behind. The adapter also dies by itself
/// when this process does (it exits on EOF of its stdin).
///
/// Giving up is not forever: waking the Mac tries again from scratch (the failures
/// that exhausted the policy were often a sleep in the middle of a start), and while
/// it stays given up one slow retry runs every few minutes.
@MainActor
@Observable
final class NowPlayingClient {
    enum Status: Equatable {
        case stopped
        /// Wanted and (re)starting or reading; `track` is nil while nothing plays.
        case running
        /// Gave up. The text is for the user.
        case unavailable(String)
    }

    nonisolated static let missingAdapterText = "Falta o adaptador de música"
    nonisolated static let failedText = "Não consegui ler a música"
    /// While given up, how long to wait between slow retries.
    nonisolated static let slowRetryInterval: TimeInterval = 300

    private(set) var track: NowPlayingTrack?
    private(set) var status: Status = .stopped

    private struct Session {
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let error: FileHandle
        let startedAt: Date
    }

    @ObservationIgnored private let adapterURL: URL?
    @ObservationIgnored private var session: Session?
    /// Bumped on every launch and every teardown: callbacks of a process that is no
    /// longer the current one carry an old number and are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var policy = NowPlayingRestartPolicy()
    @ObservationIgnored private var restartWork: DispatchWorkItem?
    /// The one slow retry while given up. Nil in every other state.
    @ObservationIgnored private var slowRetry: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private let wakeCenter: NotificationCenter
    @ObservationIgnored private let slowRetryInterval: TimeInterval

    /// `adapterURL` overrides the lookup; `wakeCenter` and `slowRetryInterval` are
    /// there for the tests.
    init(
        adapterURL: URL? = nil,
        wakeCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        slowRetryInterval: TimeInterval = NowPlayingClient.slowRetryInterval
    ) {
        self.adapterURL = adapterURL
        self.wakeCenter = wakeCenter
        self.slowRetryInterval = slowRetryInterval
    }

    func start() {
        guard status != .running else { return }
        observeWake()
        restartFromScratch()
    }

    func stop() {
        restartWork?.cancel()
        restartWork = nil
        stopSlowRetry()
        if let wakeObserver { wakeCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        tearDown()
        track = nil
        status = .stopped
    }

    func send(_ command: NowPlayingCommand) {
        guard let session, session.process.isRunning else { return }
        do {
            try session.input.write(contentsOf: Data((command.wire + "\n").utf8))
        } catch {
            journal.error("Could not send \(command.wire, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Process

    /// A clean slate: the policy forgets earlier failures and the adapter is launched.
    private func restartFromScratch() {
        stopSlowRetry()
        policy = NowPlayingRestartPolicy()
        status = .running
        launch()
    }

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = wakeCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
    }

    /// Whatever made the adapter fail before the sleep may be gone: try again.
    private func systemDidWake() {
        guard case .unavailable = status else { return }
        journal.info("Woke up with the adapter unavailable: trying again")
        restartFromScratch()
    }

    private func startSlowRetry() {
        stopSlowRetry()
        let timer = Timer(timeInterval: slowRetryInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .unavailable = self.status else { return }
                self.restartFromScratch()
            }
        }
        // Common modes, like the island's other timers: it must fire with a menu open too.
        RunLoop.main.add(timer, forMode: .common)
        slowRetry = timer
    }

    private func stopSlowRetry() {
        slowRetry?.invalidate()
        slowRetry = nil
    }

    private func launch() {
        restartWork = nil
        guard status == .running, session == nil else { return }
        guard let library = adapterURL ?? NowPlayingAdapter.locate() else {
            status = .unavailable(Self.missingAdapterText)
            return
        }

        generation += 1
        let mine = generation

        let process = Process()
        process.executableURL = NowPlayingAdapter.perl
        process.arguments = ["-e", NowPlayingAdapter.loaderScript, library.path]
        // Nothing from the user's shell (PERL5OPT, PERL5LIB…) should reach the loader.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // A command written to an adapter that just died must fail, not raise SIGPIPE.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let decoder = NowPlayingStreamDecoder()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            let updates = decoder.feed(chunk)
            guard !updates.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(updates, generation: mine) }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            if let text = String(data: chunk, encoding: .utf8) {
                journal.error("adapter: \(text, privacy: .public)")
            }
        }
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.adapterExited(code: code, generation: mine) }
            }
        }

        do {
            try process.run()
        } catch {
            journal.error("Could not start perl: \(error.localizedDescription, privacy: .public)")
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            handleFailure(uptime: 0)
            return
        }
        session = Session(
            process: process,
            input: stdinPipe.fileHandleForWriting,
            output: stdoutPipe.fileHandleForReading,
            error: stderrPipe.fileHandleForReading,
            startedAt: Date()
        )
    }

    private func apply(_ updates: [NowPlayingUpdate], generation mine: Int) {
        guard mine == generation else { return }
        var next = track
        for update in updates { next = NowPlayingProtocol.merge(update, into: next) }
        if next != track { track = next }
    }

    private func adapterExited(code: Int32, generation mine: Int) {
        guard mine == generation, let session else { return }
        journal.error("Adapter exited with status \(code, privacy: .public)")
        let uptime = Date().timeIntervalSince(session.startedAt)
        tearDown()
        track = nil
        handleFailure(uptime: uptime)
    }

    /// The adapter died or never started without being asked to: retry later or give up.
    private func handleFailure(uptime: TimeInterval) {
        switch policy.recordFailure(at: Date(), uptime: uptime) {
        case .retry(let delay):
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.launch() }
            }
            restartWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case .giveUp:
            status = .unavailable(Self.failedText)
            startSlowRetry()
        }
    }

    /// Closes stdin (the adapter exits on EOF) and terminates our own process, if still up.
    private func tearDown() {
        guard let session else { return }
        self.session = nil
        generation += 1
        session.output.readabilityHandler = nil
        session.error.readabilityHandler = nil
        try? session.input.close()
        if session.process.isRunning { session.process.terminate() }
    }
}
