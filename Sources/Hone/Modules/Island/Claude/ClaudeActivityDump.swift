import Foundation
import Observation

/// Dev tool: the Claude view's data as text, no UI. `HONE_CLAUDE_DUMP=1` prints one
/// snapshot; with `HONE_CLAUDE_DUMP_WATCH=<seconds>` it runs the monitor that long
/// and prints every new snapshot and notice, then how many reads it did.
/// `HONE_CLAUDE_DUMP_ROOT=<folder>` reads that folder instead of `~/.claude`.
/// Like the preview renderer it exits before anything else runs (see `HoneMain`):
/// no windows, no modules, no defaults written. Metadata only: names, states and
/// agent types (what the agents were asked is not even read).
@MainActor
enum ClaudeActivityDump {
    static func run(environment: [String: String]) -> Never {
        let root = environment["HONE_CLAUDE_DUMP_ROOT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? ClaudeActivityReader.defaultRoot
        let reader = ClaudeActivityReader(root: root)
        guard let seconds = environment["HONE_CLAUDE_DUMP_WATCH"].flatMap(TimeInterval.init), seconds > 0 else {
            let now = Date()
            print(text(for: reader.read(now: now), now: now))
            exit(0)
        }

        let monitor = ClaudeActivityMonitor(reader: reader)
        monitor.onNotices = { notices in
            for notice in notices {
                switch notice {
                case .waiting(let session): print("\(clock(Date()))  aviso: à espera de ti · \(session.name) · \(session.project)")
                case .finished(let session): print("\(clock(Date()))  aviso: acabou · \(session.name) · \(session.project)")
                }
            }
        }
        observe(monitor)
        monitor.start()
        let started = Date()
        RunLoop.main.run(until: started.addingTimeInterval(seconds))
        print("\(clock(Date()))  \(monitor.readCount) leituras em \(Int(seconds)) s")
        monitor.stop()
        exit(0)
    }

    private static func observe(_ monitor: ClaudeActivityMonitor) {
        withObservationTracking {
            _ = monitor.snapshot
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let now = Date()
                    print("\(clock(now))  snapshot (leitura \(monitor.readCount))")
                    print(text(for: monitor.snapshot, now: now))
                    observe(monitor)
                }
            }
        }
    }

    static func text(for snapshot: ClaudeSnapshot?, now: Date) -> String {
        guard let snapshot else { return "sem ~/.claude: a vista do Claude fica escondida" }
        var lines = ["\(snapshot.sessions.count) sessões · \(snapshot.activeCount) ativas · \(snapshot.waiting.count) à espera"]
        for session in snapshot.sessions {
            let agents = session.agents.map { "\($0.type)(\($0.isMine ? "mine" : "outro"))" }.joined(separator: " ")
            var line = "  \(label(session.state).padding(toLength: 11, withPad: " ", startingAt: 0))"
                + " \(session.name) · \(session.project) · \(age(since: session.since, now: now))"
            if !agents.isEmpty { line += " · \(agents)" }
            lines.append(line)
        }
        let inUse = snapshot.myAgents.filter { snapshot.runningCount(of: $0.name) > 0 }.count
        let band = snapshot.myAgents.map { "\($0.name) \(snapshot.runningCount(of: $0.name))" }.joined(separator: " · ")
        lines.append("Os teus agentes (\(inUse) de \(snapshot.myAgents.count) em uso): \(band)")
        let mine = Set(snapshot.myAgents.map(\.name))
        let others = snapshot.agentUsage.keys.filter { !mine.contains($0) }.sorted()
        if !others.isEmpty {
            lines.append("Outros: " + others.map { "\($0) \(snapshot.runningCount(of: $0))" }.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    private static func label(_ state: ClaudeSession.State) -> String {
        switch state {
        case .waiting: "à espera"
        case .working: "a trabalhar"
        case .idle: "idle"
        }
    }

    private static func age(since: Date, now: Date) -> String {
        let minutes = Int(max(now.timeIntervalSince(since), 0) / 60)
        if minutes < 1 { return "agora" }
        if minutes < 60 { return "há \(minutes) min" }
        return "há \(minutes / 60) h \(minutes % 60) min"
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}
