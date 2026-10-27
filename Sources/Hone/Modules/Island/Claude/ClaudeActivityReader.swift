import Darwin
import Foundation

/// A file's size and modification date: unchanged stamp, unchanged contents.
struct ClaudeFileStamp: Equatable, Sendable {
    var size: Int
    var modified: Date
}

/// The file access the reader needs, read-only, so tests can see every path it touches.
protocol ClaudeFileAccess {
    /// The names in a folder, `nil` when it can't be listed.
    func names(in folder: URL) -> [String]?
    /// `nil` when the file is missing.
    func stamp(of file: URL) -> ClaudeFileStamp?
    /// Up to `maxBytes` from the start of the file.
    func head(of file: URL, maxBytes: Int) -> Data?
    /// Up to `maxBytes` from the end of the file.
    func tail(of file: URL, maxBytes: Int) -> Data?
}

struct ClaudeDiskFiles: ClaudeFileAccess {
    func names(in folder: URL) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    func stamp(of file: URL) -> ClaudeFileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return ClaudeFileStamp(size: size.intValue, modified: modified)
    }

    func head(of file: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes) ?? Data()
    }

    func tail(of file: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        return try? handle.readToEnd() ?? Data()
    }
}

/// Is a session's process still the one that wrote its file?
enum ClaudeProcess {
    /// When a session's file says its process started. The file is written a moment
    /// after the process starts, so the two never match exactly.
    enum Start: Equatable {
        /// `startedAt`: epoch milliseconds, no time zone to get wrong. Measured 0.3 to
        /// 1.5 s after the process's own start.
        case epoch(Date)
        /// `procStart` (older files): local time, to the second.
        case text(Date)

        var date: Date {
            switch self {
            case .epoch(let date), .text(let date): date
            }
        }

        /// The file's start minus the process's own, in seconds, that still counts
        /// as the same process.
        var tolerance: ClosedRange<TimeInterval> {
            switch self {
            case .epoch: -1...10
            case .text: -2...2
            }
        }
    }

    /// `startedAt` when the file has it, else `procStart`; `nil` if neither says.
    static func start(startedAt: Double?, procStart: String?) -> Start? {
        if let startedAt, startedAt > 0 { return .epoch(Date(timeIntervalSince1970: startedAt / 1000)) }
        return parseStart(procStart).map(Start.text)
    }

    /// Alive (`kill(pid, 0)`, EPERM counts) and, when its start is known, started
    /// when the file says: a reused pid belongs to someone else.
    static func isAlive(pid: Int32, start: Start?) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0, errno != EPERM { return false }
        guard let start, let actual = startTime(of: pid) else { return true }
        return start.tolerance.contains(start.date.timeIntervalSince(actual))
    }

    static func startTime(of pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// `procStart` as Claude Code writes it: `Mon Oct 26 10:36:35 2026`, local time.
    static func parseStart(_ text: String?) -> Date? {
        guard let text else { return nil }
        let collapsed = text.split(separator: " ").joined(separator: " ")
        return startFormatter.date(from: collapsed)
    }

    private static let startFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Follows the system's zone: the Mac can change it while Hone is open.
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()
}

/// Reads Claude Code's own bookkeeping under `~/.claude` into a `ClaudeSnapshot`.
/// Read-only and metadata only: it never writes there, never opens the sessions'
/// `.key` files nor their sockets, and keeps no message text.
///
/// - `sessions/<pid>.json`: one per session; dead processes are skipped, and a file
///   caught half written keeps the last whole record it had.
/// - `projects/*/<sessionId>.jsonl`: the transcript's tail, only to see whether a
///   busy session is waiting on `AskUserQuestion` or `ExitPlanMode`.
/// - `projects/*/<sessionId>/subagents/agent-<id>.meta.json` and `.jsonl`: its
///   subagents (their type only: what they were asked is not read), for busy
///   sessions only.
/// - `agents/*.md`: the user's own agents.
///
/// Not thread-safe: it keeps caches, so one queue owns it.
final class ClaudeActivityReader {
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")

    /// Transcript tail first read, then once more if no whole line fits.
    static let transcriptTail = 64 * 1024
    static let transcriptLongTail = 256 * 1024
    static let agentLogTail = 8 * 1024
    static let agentLogLongTail = 64 * 1024
    /// Session files and metas are small; anything bigger is not one.
    static let smallFileLimit = 64 * 1024
    static let agentFileHead = 16 * 1024

    let root: URL
    private let files: ClaudeFileAccess
    private let isAlive: (Int32, ClaudeProcess.Start?) -> Bool

    /// The last whole record of each session file, by file name.
    private var recordCache: [String: SessionRecord] = [:]
    private var transcripts: [String: URL] = [:]
    private var waitingCache: [URL: (stamp: ClaudeFileStamp, waiting: Bool)] = [:]
    private var metaCache: [URL: (stamp: ClaudeFileStamp, meta: AgentMeta?)] = [:]
    private var endedCache: [URL: (stamp: ClaudeFileStamp, ended: Bool)] = [:]
    private var profileCache: [URL: (stamp: ClaudeFileStamp, profile: ClaudeAgentProfile?)] = [:]

    init(root: URL = ClaudeActivityReader.defaultRoot,
         files: ClaudeFileAccess = ClaudeDiskFiles(),
         isAlive: @escaping (Int32, ClaudeProcess.Start?) -> Bool = { ClaudeProcess.isAlive(pid: $0, start: $1) }) {
        self.root = root
        self.files = files
        self.isAlive = isAlive
    }

    var rootExists: Bool { files.names(in: root) != nil }

    /// `nil` without `~/.claude`: no Claude Code here, nothing to show.
    func read(now: Date) -> ClaudeSnapshot? {
        guard rootExists else { return nil }
        let myAgents = readAgents()
        let mine = Set(myAgents.map(\.name))

        var latest: [String: (record: SessionRecord, updated: Double)] = [:]
        for record in readSessionRecords() {
            let updated = record.updatedAt ?? 0
            if let other = latest[record.sessionId], other.updated >= updated { continue }
            latest[record.sessionId] = (record, updated)
        }

        var seenTranscripts: Set<URL> = []
        var seenAgentFiles: Set<URL> = []
        var sessions: [ClaudeSession] = []
        for (record, _) in latest.values {
            guard isAlive(record.pid, ClaudeProcess.start(startedAt: record.startedAt, procStart: record.procStart))
            else { continue }
            let since = Date(timeIntervalSince1970: (record.statusUpdatedAt ?? record.updatedAt ?? 0) / 1000)
            var state = ClaudeSession.State.idle
            var agents: [ClaudeRunningAgent] = []
            let isBusy = record.status == "busy"
            // Claude Code 2.1.3xx writes "waiting" (with `waitingFor`) for some waits;
            // others stay "busy" with the question pending in the transcript.
            if isBusy || record.status == "waiting" {
                state = record.status == "waiting" ? .waiting : .working
                if let transcript = transcriptURL(for: record.sessionId) {
                    seenTranscripts.insert(transcript)
                    if state == .working, isWaiting(transcript: transcript) { state = .waiting }
                    agents = runningAgents(beside: transcript, now: now, mine: mine, seen: &seenAgentFiles)
                }
            } else if now.timeIntervalSince(since) >= ClaudeActivity.idleWindow {
                continue
            }
            let project = record.cwd.map(ClaudeActivity.project(fromCWD:)) ?? ""
            let title = record.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            sessions.append(ClaudeSession(
                id: record.sessionId,
                pid: record.pid,
                hostSessionID: record.hostSessionId,
                name: title.isEmpty ? project : title,
                project: project,
                state: state,
                since: since,
                agents: agents,
                isBusy: isBusy
            ))
        }

        // Forget what no live session refers to any more.
        waitingCache = waitingCache.filter { seenTranscripts.contains($0.key) }
        metaCache = metaCache.filter { seenAgentFiles.contains($0.key) }
        endedCache = endedCache.filter { seenAgentFiles.contains($0.key) }
        let ids = Set(latest.keys)
        transcripts = transcripts.filter { ids.contains($0.key) }

        return ClaudeSnapshot(sessions: sessions, myAgents: myAgents)
    }

    // MARK: Sessions

    private struct SessionRecord: Decodable {
        var pid: Int32
        var sessionId: String
        var name: String?
        var cwd: String?
        var status: String?
        var updatedAt: Double?
        var statusUpdatedAt: Double?
        /// Epoch milliseconds, whatever the time zone.
        var startedAt: Double?
        var procStart: String?
        var hostSessionId: String?
    }

    /// A file that doesn't read whole (caught while Claude Code writes it) gives its
    /// last whole record, or the session would vanish for a read and come back as a
    /// new one, with its notice. Files no longer listed are forgotten.
    private func readSessionRecords() -> [SessionRecord] {
        let folder = root.appendingPathComponent("sessions")
        // Only the .json files are ever opened: the .key files beside them are secrets.
        let names = (files.names(in: folder) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        var current: [String: SessionRecord] = [:]
        for name in names {
            if let data = files.head(of: folder.appendingPathComponent(name), maxBytes: Self.smallFileLimit),
               let record = try? JSONDecoder().decode(SessionRecord.self, from: data),
               record.pid > 0, Self.isSafeID(record.sessionId) {
                current[name] = record
            } else {
                current[name] = recordCache[name]
            }
        }
        recordCache = current
        return names.compactMap { current[$0] }
    }

    /// Session and agent ids become path components: letters, digits and dashes only.
    /// (No regex literal: Swift parses those again on every call, and this runs per agent per read.)
    static func isSafeID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-")
        }
    }

    // MARK: Waiting for the user

    /// `projects/*/<id>.jsonl`, found by looking in every project folder (the
    /// folder's slug is not derived from the cwd) and remembered.
    private func transcriptURL(for sessionID: String) -> URL? {
        if let known = transcripts[sessionID], files.stamp(of: known) != nil { return known }
        transcripts[sessionID] = nil
        let projects = root.appendingPathComponent("projects")
        for folder in (files.names(in: projects) ?? []).sorted() where !folder.hasPrefix(".") {
            let candidate = projects.appendingPathComponent(folder).appendingPathComponent("\(sessionID).jsonl")
            if files.stamp(of: candidate) != nil {
                transcripts[sessionID] = candidate
                return candidate
            }
        }
        return nil
    }

    private func isWaiting(transcript: URL) -> Bool {
        guard let stamp = files.stamp(of: transcript) else { return false }
        if let cached = waitingCache[transcript], cached.stamp == stamp { return cached.waiting }
        let lines = completeLines(of: transcript, size: stamp.size,
                                  tail: Self.transcriptTail, longTail: Self.transcriptLongTail)
        let waiting = !Self.pendingQuestions(in: lines).isEmpty
        waitingCache[transcript] = (stamp, waiting)
        return waiting
    }

    /// Tools that stop the session until the user answers.
    static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// The ids of question tool calls with no result yet, in transcript order.
    static func pendingQuestions(in lines: [Data]) -> [String] {
        var pending: [String] = []
        let decoder = JSONDecoder()
        for line in lines {
            guard let event = try? decoder.decode(TranscriptLine.self, from: line) else { continue }
            switch event.type {
            case "assistant":
                for block in event.blocks where block.type == "tool_use" {
                    if let name = block.name, questionTools.contains(name), let id = block.id { pending.append(id) }
                }
            case "user":
                for block in event.blocks where block.type == "tool_result" {
                    pending.removeAll { $0 == block.tool_use_id }
                }
            default:
                continue
            }
        }
        return pending
    }

    /// The few keys a transcript line is read for; text is never decoded into anything kept.
    private struct TranscriptLine: Decodable {
        var type: String?
        var blocks: [Block] = []
        var stopReason: String?

        struct Block: Decodable {
            var type: String?
            var name: String?
            var id: String?
            var tool_use_id: String?
        }

        private enum Keys: String, CodingKey { case type, message }
        private enum MessageKeys: String, CodingKey { case content, stop_reason }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            // `message` is an object on assistant and user lines; anything else is ignored.
            guard let message = try? container.nestedContainer(keyedBy: MessageKeys.self, forKey: .message) else { return }
            // A user's typed prompt is a string, not blocks.
            blocks = (try? message.decodeIfPresent([Block].self, forKey: .content)) ?? []
            stopReason = try? message.decodeIfPresent(String.self, forKey: .stop_reason)
        }
    }

    /// The tail's newline-terminated lines. The first is dropped when the tail
    /// starts inside the file (it is cut), the last when nothing ends it yet.
    private func completeLines(of file: URL, size: Int, tail: Int, longTail: Int) -> [Data] {
        for limit in [tail, longTail] {
            guard let data = files.tail(of: file, maxBytes: limit) else { return [] }
            let lines = Self.completeLines(in: data, startsMidFile: size > limit)
            if !lines.isEmpty || size <= limit { return lines }
        }
        return []
    }

    static func completeLines(in data: Data, startsMidFile: Bool) -> [Data] {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if !lines.isEmpty { lines.removeLast() }  // after the last newline: empty, or a line still being written
        if startsMidFile, !lines.isEmpty { lines.removeFirst() }
        return lines.filter { !$0.isEmpty }.map { Data($0) }
    }

    // MARK: Subagents

    private struct AgentMeta: Decodable {
        var agentType: String?
        var finished: Bool?

        private enum Keys: String, CodingKey { case agentType, finished }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            agentType = try? container.decodeIfPresent(String.self, forKey: .agentType)
            finished = try? container.decodeIfPresent(Bool.self, forKey: .finished)
        }
    }

    /// `<transcript folder>/<sessionId>/subagents`: running = not `finished`, its
    /// log touched within `agentStaleAfter`, and the log's last line is not the
    /// agent's final `end_turn`.
    private func runningAgents(beside transcript: URL, now: Date, mine: Set<String>,
                               seen: inout Set<URL>) -> [ClaudeRunningAgent] {
        let folder = transcript.deletingPathExtension().appendingPathComponent("subagents")
        let metas = (files.names(in: folder) ?? [])
            .filter { $0.hasPrefix("agent-") && $0.hasSuffix(".meta.json") }
            .sorted()
        var agents: [ClaudeRunningAgent] = []
        for name in metas {
            let id = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
            guard Self.isSafeID(id) else { continue }
            let metaURL = folder.appendingPathComponent(name)
            seen.insert(metaURL)
            guard let meta = agentMeta(at: metaURL), meta.finished != true else { continue }
            let log = folder.appendingPathComponent("agent-\(id).jsonl")
            guard let stamp = files.stamp(of: log),
                  now.timeIntervalSince(stamp.modified) < ClaudeActivity.agentStaleAfter else { continue }
            seen.insert(log)
            if hasEnded(log: log, stamp: stamp) { continue }
            let type = meta.agentType ?? "agent"
            agents.append(ClaudeRunningAgent(type: type, isMine: mine.contains(type)))
        }
        return agents
    }

    private func agentMeta(at url: URL) -> AgentMeta? {
        guard let stamp = files.stamp(of: url) else { return nil }
        if let cached = metaCache[url], cached.stamp == stamp { return cached.meta }
        let meta = stamp.size > Self.smallFileLimit ? nil : files.head(of: url, maxBytes: Self.smallFileLimit)
            .flatMap { try? JSONDecoder().decode(AgentMeta.self, from: $0) }
        metaCache[url] = (stamp, meta)
        return meta
    }

    /// The log's last whole line is the agent's final answer. Unknown (no whole
    /// line in the tail) counts as still running: `finished` and the mtime decide.
    private func hasEnded(log: URL, stamp: ClaudeFileStamp) -> Bool {
        if let cached = endedCache[log], cached.stamp == stamp { return cached.ended }
        let last = completeLines(of: log, size: stamp.size,
                                 tail: Self.agentLogTail, longTail: Self.agentLogLongTail).last
        let ended = last.flatMap { try? JSONDecoder().decode(TranscriptLine.self, from: $0) }
            .map { $0.type == "assistant" && $0.stopReason == "end_turn" } ?? false
        endedCache[log] = (stamp, ended)
        return ended
    }

    // MARK: The user's agents

    private func readAgents() -> [ClaudeAgentProfile] {
        let folder = root.appendingPathComponent("agents")
        var seen: Set<URL> = []
        let profiles = (files.names(in: folder) ?? []).filter { $0.hasSuffix(".md") }.sorted().compactMap { name -> ClaudeAgentProfile? in
            let url = folder.appendingPathComponent(name)
            seen.insert(url)
            guard let stamp = files.stamp(of: url) else { return nil }
            if let cached = profileCache[url], cached.stamp == stamp { return cached.profile }
            let profile = files.head(of: url, maxBytes: Self.agentFileHead).flatMap {
                Self.agentProfile(frontmatterOf: String(decoding: $0, as: UTF8.self),
                                  fallbackName: String(name.dropLast(".md".count)))
            }
            profileCache[url] = (stamp, profile)
            return profile
        }
        profileCache = profileCache.filter { seen.contains($0.key) }
        return profiles
    }

    /// `name:` and `description:` from the `---` block at the top of an agent file.
    static func agentProfile(frontmatterOf text: String, fallbackName: String) -> ClaudeAgentProfile? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        guard !name.isEmpty else { return nil }
        return ClaudeAgentProfile(name: name, description: fields["description"] ?? "")
    }
}
