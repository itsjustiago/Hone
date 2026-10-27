import CoreGraphics
import Foundation

/// The Claude page's words, as pure functions: no clock, no views.
enum IslandClaudeText {
    /// How long ago `since` was: «agora» under a minute, «há N min» under an hour,
    /// «há N h» from then on. A `since` in the future (clocks) is «agora».
    static func ago(_ since: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(since)
        if seconds < 60 { return "agora" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "há \(minutes) min" }
        return "há \(minutes / 60) h"
    }

    /// The line under a session's name: «‹projeto› · há 3 min», or «‹projeto› · à
    /// tua espera» while it waits.
    static func subtitle(_ session: ClaudeSession, now: Date) -> String {
        let when = session.state == .waiting ? "à tua espera" : ago(session.since, now: now)
        return "\(session.project) · \(when)"
    }

    /// What VoiceOver reads for a session's row.
    static func accessibilityLabel(_ session: ClaudeSession) -> String {
        "\(session.name), \(session.project), \(stateName(session.state))"
    }

    static func stateName(_ state: ClaudeSession.State) -> String {
        switch state {
        case .waiting: return "à tua espera"
        case .working: return "a trabalhar"
        case .idle: return "parada"
        }
    }

    /// The strip's caption while the pointer is on a running agent: «‹agente› em
    /// ‹sessão A›, ‹sessão B›».
    static func usage(of agent: String, in sessions: [ClaudeSession]) -> String {
        "\(agent) em \(sessions.map(\.name).joined(separator: ", "))"
    }
}

/// The agent chips: the ones on a session's row and the strip «Os teus agentes».
/// Their order and where they are cut, as pure functions.
enum IslandAgentChips {
    /// An agent type and how many of it run.
    struct Tally: Equatable, Identifiable {
        var type: String
        var count: Int
        /// One of the user's own agents.
        var isMine: Bool

        var id: String { type }

        /// On a session's row: «engenheiro», or «engenheiro ×4» for several.
        var rowLabel: String { count > 1 ? "\(type) ×\(count)" : type }
    }

    /// The most chips a session's row shows; the rest become «+N».
    static let rowLimit = 2

    /// A session's running agents by type, the most numerous first (ties in the
    /// order they started), at most `limit`; `hidden` is how many types are left.
    static func running(_ agents: [ClaudeRunningAgent], limit: Int = rowLimit) -> (shown: [Tally], hidden: Int) {
        var tallies: [Tally] = []
        for agent in agents {
            if let index = tallies.firstIndex(where: { $0.type == agent.type }) {
                tallies[index].count += 1
                tallies[index].isMine = tallies[index].isMine || agent.isMine
            } else {
                tallies.append(Tally(type: agent.type, count: 1, isMine: agent.isMine))
            }
        }
        let ordered = tallies.enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map(\.element)
        let shown = Array(ordered.prefix(max(0, limit)))
        return (shown, ordered.count - shown.count)
    }

    /// The strip: the user's agents running now, the most instances first (ties
    /// alphabetical), then the others alphabetically. `count` is how many of a type
    /// run across all sessions.
    static func strip(_ agents: [ClaudeAgentProfile], count: (String) -> Int) -> [Tally] {
        let tallies = agents.map { Tally(type: $0.name, count: count($0.name), isMine: true) }
        let byName: (Tally, Tally) -> Bool = {
            $0.type.localizedStandardCompare($1.type) == .orderedAscending
        }
        let lit = tallies.filter { $0.count > 0 }
            .sorted { $0.count != $1.count ? $0.count > $1.count : byName($0, $1) }
        let unlit = tallies.filter { $0.count == 0 }.sorted(by: byName)
        return lit + unlit
    }

    /// The row each chip falls on when they flow left to right, `spacing` apart, in
    /// rows `maxWidth` wide. A chip wider than a row gets a row of its own.
    static func flowRows(_ widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [Int] {
        var row = 0, x: CGFloat = 0, rows: [Int] = []
        for width in widths {
            if x > 0, x + spacing + width > maxWidth {
                row += 1
                x = 0
            }
            x += (x > 0 ? spacing : 0) + width
            rows.append(row)
        }
        return rows
    }

    /// How many of the chips show in `rows` rows: all of them if they fit, else as
    /// many as fit with a «+N» chip (`plusWidth(N)` wide) after them.
    static func fit(_ widths: [CGFloat], plusWidth: (Int) -> CGFloat, maxWidth: CGFloat,
                    spacing: CGFloat, rows: Int) -> Int {
        func fits(_ widths: [CGFloat]) -> Bool {
            (flowRows(widths, maxWidth: maxWidth, spacing: spacing).last ?? 0) < rows
        }
        if fits(widths) { return widths.count }
        for shown in stride(from: widths.count - 1, through: 0, by: -1)
        where fits(Array(widths.prefix(shown)) + [plusWidth(widths.count - shown)]) {
            return shown
        }
        return 0
    }
}
