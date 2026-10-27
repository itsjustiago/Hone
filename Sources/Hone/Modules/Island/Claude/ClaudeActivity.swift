import Foundation

/// One of the user's own agents, from `~/.claude/agents/<name>.md`.
struct ClaudeAgentProfile: Equatable, Sendable, Identifiable {
    var name: String
    var description: String

    var id: String { name }
}

/// A subagent running inside a session right now.
struct ClaudeRunningAgent: Equatable, Sendable {
    /// Its `agentType`: "engenheiro", "Explore", "general-purpose"…
    var type: String
    /// One of the user's own agents, not a built-in or a plugin's.
    var isMine: Bool
}

/// A live Claude Code session.
struct ClaudeSession: Equatable, Sendable, Identifiable {
    enum State: Int, Equatable, Sendable, Comparable {
        /// Waiting for the user: status "waiting", or busy with a question or plan unanswered.
        case waiting
        /// Busy: the model or a background agent is at work.
        case working
        case idle

        static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
    }

    /// The session's `sessionId`.
    var id: String
    var pid: Int32
    /// The session's id in the Claude app (`local_<uuid>`), when it runs there.
    var hostSessionID: String?
    /// The session's title, or its project when it has none.
    var name: String
    /// The repository, not the worktree: `loja` for `…/loja/.claude/worktrees/x`.
    var project: String
    var state: State
    /// When the session last changed between busy and idle.
    var since: Date
    /// Subagents running in it (only read for busy sessions).
    var agents: [ClaudeRunningAgent]
    /// The file says "busy" (working, or waiting on a question the transcript holds):
    /// re-read on a timer, since the transcript is not watched. A "waiting" file is
    /// not: the file changing wakes the monitor.
    var isBusy = false

    /// Opens this session in the Claude app, `nil` when it can't be addressed
    /// (then just activate the app).
    var appURL: URL? { ClaudeActivity.appURL(hostSessionID: hostSessionID) }
}

/// What the island knows about Claude Code at one moment. Sessions are kept in
/// display order: waiting, working, idle; the most recent first in each group.
struct ClaudeSnapshot: Equatable, Sendable {
    private(set) var sessions: [ClaudeSession]
    var myAgents: [ClaudeAgentProfile]

    init(sessions: [ClaudeSession], myAgents: [ClaudeAgentProfile]) {
        self.sessions = sessions.sorted { a, b in
            a.state != b.state ? a.state < b.state : a.since > b.since
        }
        self.myAgents = myAgents
    }

    var waiting: [ClaudeSession] { sessions.filter { $0.state == .waiting } }

    /// Sessions waiting or working.
    var activeCount: Int { sessions.filter { $0.state != .idle }.count }

    /// Agent type → the sessions running at least one of it, in display order.
    var agentUsage: [String: [ClaudeSession]] {
        var usage: [String: [ClaudeSession]] = [:]
        for session in sessions {
            for type in Set(session.agents.map(\.type)) { usage[type, default: []].append(session) }
        }
        return usage
    }

    /// Instances of an agent type running across all sessions.
    func runningCount(of type: String) -> Int {
        sessions.reduce(0) { $0 + $1.agents.filter { $0.type == type }.count }
    }
}

enum ClaudeNotice: Equatable, Sendable {
    /// The session started waiting for the user.
    case waiting(ClaudeSession)
    /// The session went from waiting or working to idle.
    case finished(ClaudeSession)
}

/// The rules of the Claude view, as pure functions: no clock, no files.
enum ClaudeActivity {
    /// Idle sessions show for this long after they went idle.
    static let idleWindow: TimeInterval = 3 * 60 * 60
    /// A subagent whose transcript hasn't moved for this long is not running.
    static let agentStaleAfter: TimeInterval = 30 * 60
    /// How often a busy session is re-read: its transcript is not watched.
    static let busyRefreshInterval: TimeInterval = 2

    /// What changed for the user between two snapshots. The first snapshot and
    /// sessions that vanished (their process died) say nothing.
    static func notices(from old: ClaudeSnapshot?, to new: ClaudeSnapshot) -> [ClaudeNotice] {
        guard let old else { return [] }
        let before = Dictionary(old.sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        return new.sessions.compactMap { session in
            let was = before[session.id]
            switch session.state {
            case .waiting where was != .waiting:
                return .waiting(session)
            case .idle where was == .waiting || was == .working:
                return .finished(session)
            default:
                return nil
            }
        }
    }

    /// When the snapshot next needs a read without any file event: every
    /// `busyRefreshInterval` while a session's file says busy, else when the oldest
    /// idle session leaves the window. `nil`: nothing to do until a file changes
    /// (a "waiting" file is one: it never leaves the window).
    static func nextRefresh(after snapshot: ClaudeSnapshot?, now: Date) -> Date? {
        guard let snapshot else { return nil }
        if snapshot.sessions.contains(where: \.isBusy) { return now.addingTimeInterval(busyRefreshInterval) }
        return snapshot.sessions.filter { $0.state == .idle }.map { $0.since.addingTimeInterval(idleWindow) }.min()
    }

    /// The repository a session works in: the folder above `.claude/worktrees`
    /// for a worktree, the last folder otherwise.
    static func project(fromCWD cwd: String) -> String {
        let path = cwd.hasSuffix("/") && cwd.count > 1 ? String(cwd.dropLast()) : cwd
        if let range = path.range(of: "/.claude/worktrees/") {
            let repo = (String(path[..<range.lowerBound]) as NSString).lastPathComponent
            if !repo.isEmpty { return repo }
        }
        return (path as NSString).lastPathComponent
    }

    /// `claude://code/continue?session=<id>`, which the Claude app opens on that
    /// session. The app accepts only `local_` ids of letters, digits and dashes.
    static func appURL(hostSessionID: String?) -> URL? {
        guard let id = hostSessionID, id.hasPrefix("local_"),
              ClaudeActivityReader.isSafeID(String(id.dropFirst("local_".count))) else { return nil }
        return URL(string: "claude://code/continue?session=\(id)")
    }
}
