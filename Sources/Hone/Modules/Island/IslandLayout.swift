import Foundation

// What the island draws, decided by `IslandState` and read by `IslandView`. The
// island holds two things: the music and Claude Code's sessions. Beside the notch
// one of them owns the wings; open, it shows one of two pages.

/// The two pages of the open island. The selector in the notch row switches them
/// when both exist.
enum IslandPage: Equatable, CaseIterable {
    /// The player: the large cover, the titles, the controls.
    case music
    /// The list of sessions and, under it, the strip «Os teus agentes».
    case claude

    var other: IslandPage { self == .music ? .claude : .music }
}

/// Who owns the notch row: what sits in the wings beside the notch.
enum IslandWings: Equatable {
    case none
    /// The cover on the left. Compact and peek put the equaliser on the right; the
    /// open island leaves the right wing to the page selector (or empty).
    case music
    /// Claude's glyph on the left (orange while a session waits) and the number of
    /// active sessions on the right.
    case claude
}

/// How busy Claude Code is, all sessions together.
enum IslandClaudeActivity: Equatable {
    /// No session waiting or working (idle sessions can still be listed).
    case none
    /// Some session working, none waiting.
    case working
    /// Some session waiting for the user: it beats working.
    case waiting
}

/// Claude Code reduced to what the island's rules need. The controller makes it
/// from the monitor's `ClaudeSnapshot`; the view reads the snapshot itself.
struct IslandClaude: Equatable {
    /// Sessions on the Claude page, in any state.
    var listed: Int
    /// Sessions waiting or working.
    var active: Int
    /// Some session waits for the user.
    var isWaiting: Bool
    /// The user has agents of their own: the page shows the strip «Os teus agentes».
    var hasMyAgents: Bool

    /// Nothing to show: no `~/.claude`, the setting off, or no session yet.
    static let none = IslandClaude(listed: 0, active: 0, isWaiting: false, hasMyAgents: false)

    init(listed: Int, active: Int, isWaiting: Bool, hasMyAgents: Bool) {
        self.listed = listed
        self.active = active
        self.isWaiting = isWaiting
        self.hasMyAgents = hasMyAgents
    }

    init(_ snapshot: ClaudeSnapshot?) {
        guard let snapshot else {
            self = .none
            return
        }
        self.init(listed: snapshot.sessions.count, active: snapshot.activeCount,
                  isWaiting: !snapshot.waiting.isEmpty, hasMyAgents: !snapshot.myAgents.isEmpty)
    }

    var activity: IslandClaudeActivity {
        if isWaiting { return .waiting }
        return active > 0 ? .working : .none
    }
}

/// A short line under the notch about Claude sessions, for `IslandTiming.noticeDuration`.
/// Notices of one kind that come while one is on show join it, so the line counts
/// them («2 sessões estão à tua espera»).
struct IslandNotice: Equatable {
    enum Kind: Equatable {
        /// Sessions started waiting for the user.
        case waiting
        /// Sessions went from busy to idle.
        case finished
    }

    let kind: Kind
    /// The sessions' names, in the order their notices came, each session once.
    private(set) var names: [String]
    /// The sessions' ids, beside `names`: the same session twice counts once.
    private(set) var sessionIDs: [String]

    init(kind: Kind, sessionID: String, name: String) {
        self.kind = kind
        names = [name]
        sessionIDs = [sessionID]
    }

    /// From one of the monitor's notices.
    init(_ notice: ClaudeNotice) {
        switch notice {
        case .waiting(let session): self.init(kind: .waiting, sessionID: session.id, name: session.name)
        case .finished(let session): self.init(kind: .finished, sessionID: session.id, name: session.name)
        }
    }

    /// How many sessions it is about.
    var count: Int { names.count }

    /// The line in three parts. Only `subject` gives way when the line is too long:
    /// the name is cut, never what is said of it.
    struct Parts: Equatable {
        var lead: String
        var subject: String
        var trail: String
    }

    var parts: Parts {
        switch (kind, count) {
        case (.waiting, 1): return Parts(lead: "", subject: names[0], trail: " está à tua espera")
        case (.waiting, _): return Parts(lead: "", subject: "\(count) sessões", trail: " estão à tua espera")
        case (.finished, 1): return Parts(lead: "✓ ", subject: names[0], trail: " acabou")
        case (.finished, _): return Parts(lead: "✓ ", subject: "\(count) sessões", trail: " acabaram")
        }
    }

    /// The line as the island shows it.
    var text: String { parts.lead + parts.subject + parts.trail }

    /// Takes in another notice of the same kind. A session already counted is not
    /// counted again.
    mutating func join(_ other: IslandNotice) {
        for (id, name) in zip(other.sessionIDs, other.names) where !sessionIDs.contains(id) {
            sessionIDs.append(id)
            names.append(name)
        }
    }
}

/// What a peek shows under the notch.
enum IslandPeek: Equatable {
    /// The new track's title: «Título — Artista».
    case track
    /// A Claude notice: someone waits, or finished.
    case notice(IslandNotice)
}

/// Everything the island draws at one moment, decided by `IslandState.layout(at:)`.
/// The panel sizes the shape from it (`IslandMetrics.size(for:notch:)`) and the view
/// draws what it says. Fields that only mean something on one page or presentation
/// hold their neutral value elsewhere, so two layouts that look the same are equal.
struct IslandLayout: Equatable {
    var presentation: IslandPresentation
    /// Who owns the notch row. `.none` only when hidden.
    /// - compact: `.music` while the music is in view, else `.claude`;
    /// - peek: `.music` for a track; for a notice `.music` while the music is in view, else `.claude`;
    /// - expanded: `.music` on the music page, and on the Claude page while there is a
    ///   track (its small cover stays in the left wing, the selector takes the right);
    ///   `.claude` on the Claude page with no track.
    var wings: IslandWings
    /// The open page; `.music` unless expanded.
    var page: IslandPage
    /// What the peek shows; `nil` unless `presentation == .peek`.
    var peek: IslandPeek?
    /// Rows of the session list the Claude page has room for: `min(listed,
    /// IslandMetrics.claudeMaxRows)`; the list scrolls past that. 0 off the Claude page.
    var claudeRows: Int
    /// The Claude page ends with the strip «Os teus agentes». `false` off that page.
    var hasAgentsStrip: Bool
    /// The page selector, in the right wing of the open island: there with both
    /// pages, a track and listed sessions. `false` unless expanded.
    var showsPageSelector: Bool
    /// Claude's state for its glyph (and anything else that shows it).
    var claudeActivity: IslandClaudeActivity
    /// Active sessions, for the Claude wings' count.
    var activeSessions: Int
    /// The badge on the cover while the music owns the wings beside the notch
    /// (compact and peek) and some session is active. `.none` otherwise.
    var coverBadge: IslandClaudeActivity

    /// The island with nothing in it.
    static let empty = music(.hidden)

    /// The island with only music, as it was before Claude: what the previews and
    /// the frame probe draw.
    static func music(_ presentation: IslandPresentation) -> IslandLayout {
        IslandLayout(presentation: presentation, wings: presentation == .hidden ? .none : .music,
                     page: .music, peek: presentation == .peek ? .track : nil, claudeRows: 0,
                     hasAgentsStrip: false, showsPageSelector: false, claudeActivity: .none,
                     activeSessions: 0, coverBadge: .none)
    }

    /// The cover is drawn: the music owns the notch row. Its size and place come
    /// from the outline (`IslandOutline.coverSize`, `coverFrame`).
    var showsCover: Bool { presentation != .hidden && wings == .music }

    /// The notice on show, if the peek is one.
    var notice: IslandNotice? {
        if case .notice(let notice) = peek { return notice }
        return nil
    }
}
