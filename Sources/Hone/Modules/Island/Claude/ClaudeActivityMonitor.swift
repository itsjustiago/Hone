import CoreServices
import Foundation
import Observation

/// Keeps a `ClaudeSnapshot` fresh at little cost. It reads again when
/// - a file changes in `~/.claude/sessions` or `~/.claude/agents` (FSEvents; the
///   noisy `projects/` is never watched);
/// - a session's process exits without touching its file;
/// - every `ClaudeActivity.busyRefreshInterval` while some session's file says busy
///   (a "waiting" file changing is an event like any other);
/// - an idle session leaves the window.
/// With no session busy and no file changing it does no work at all.
/// Reads run on a utility queue; the snapshot is published on the main thread.
@MainActor
@Observable
final class ClaudeActivityMonitor {
    /// `nil` before the first read, after `stop()`, and without `~/.claude`.
    private(set) var snapshot: ClaudeSnapshot?

    /// Told on the main thread, once per new snapshot and after `snapshot` holds it,
    /// what that snapshot had to say: sessions that started waiting or finished.
    /// Never called with nothing.
    @ObservationIgnored var onNotices: (([ClaudeNotice]) -> Void)?
    /// Reads done since launch (for the dump: proof that idle costs nothing).
    @ObservationIgnored private(set) var readCount = 0

    @ObservationIgnored private let worker: ClaudeActivityWorker
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isRunning = false

    init(reader: ClaudeActivityReader = ClaudeActivityReader()) {
        worker = ClaudeActivityWorker(reader: reader)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let generation = generation
        worker.start { [weak self] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(snapshot, generation: generation) }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        worker.stop()
        snapshot = nil
    }

    private func receive(_ new: ClaudeSnapshot?, generation: Int) {
        guard isRunning, generation == self.generation else { return }
        readCount += 1
        let old = snapshot
        guard new != old else { return }
        snapshot = new
        guard let new else { return }
        let notices = ClaudeActivity.notices(from: old, to: new)
        if !notices.isEmpty { onNotices?(notices) }
    }
}

/// The monitor's off-main half: the reader, the FSEvents stream, the process
/// sources and the timer, all owned by one serial utility queue.
final class ClaudeActivityWorker: @unchecked Sendable {
    /// FSEvents coalesces changes over this long.
    static let eventLatency: CFTimeInterval = 0.5
    static let timerLeeway: DispatchTimeInterval = .milliseconds(500)

    private let queue = DispatchQueue(label: "app.hone.island.claude", qos: .utility)
    private let reader: ClaudeActivityReader
    private var deliver: ((ClaudeSnapshot?) -> Void)?
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var exitSources: [Int32: DispatchSourceProcess] = [:]
    private var readQueued = false

    init(reader: ClaudeActivityReader) {
        self.reader = reader
    }

    func start(deliver: @escaping (ClaudeSnapshot?) -> Void) {
        queue.async { [self] in
            guard self.deliver == nil else { return }
            // Without ~/.claude there is nothing to watch: the snapshot stays nil.
            guard reader.rootExists else { return }
            self.deliver = deliver
            startStream()
            requestRead()
        }
    }

    func stop() {
        queue.async { [self] in
            deliver = nil
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
            timer?.cancel()
            timer = nil
            exitSources.values.forEach { $0.cancel() }
            exitSources = [:]
        }
    }

    /// Coalesces bursts (several events, an exit and the timer) into one read.
    private func requestRead() {
        guard !readQueued else { return }
        readQueued = true
        queue.async { [self] in
            readQueued = false
            read()
        }
    }

    private func read() {
        guard let deliver else { return }
        let now = Date()
        let snapshot = reader.read(now: now)
        watchExits(of: Set(snapshot?.sessions.map(\.pid) ?? []))
        schedule(at: ClaudeActivity.nextRefresh(after: snapshot, now: now), now: now)
        deliver(snapshot)
    }

    // MARK: Sources

    private func startStream() {
        let paths = ["sessions", "agents"].map { reader.root.appendingPathComponent($0).path } as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<ClaudeActivityWorker>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<ClaudeActivityWorker>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ClaudeActivityWorker>.fromOpaque(info).takeUnretainedValue().requestRead()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.eventLatency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    private func watchExits(of pids: Set<Int32>) {
        for (pid, source) in exitSources where !pids.contains(pid) {
            source.cancel()
            exitSources[pid] = nil
        }
        for pid in pids where exitSources[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in self?.requestRead() }
            source.resume()
            exitSources[pid] = source
        }
    }

    private func schedule(at date: Date?, now: Date) {
        guard let date else {
            timer?.cancel()
            timer = nil
            return
        }
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.requestRead() }
            timer.resume()
            self.timer = timer
        }
        let delay = max(date.timeIntervalSince(now), 0.1)
        timer?.schedule(deadline: .now() + delay, leeway: Self.timerLeeway)
    }
}
