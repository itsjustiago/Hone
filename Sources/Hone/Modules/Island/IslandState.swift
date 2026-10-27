import Foundation

/// What the island shows, from nothing to the open island. `IslandLayout` says
/// whose it is (the music's or Claude's) and which page is open.
enum IslandPresentation: Equatable, CaseIterable {
    /// Only the hover zone inside the notch: nothing to see.
    case hidden
    /// The wings beside the notch: cover and equaliser, or Claude's glyph and count.
    case compact
    /// A line under the notch for a moment: a new track's title, or a Claude notice.
    case peek
    /// The open island: the player, or the Claude page.
    case expanded
}

/// How long each step of the island takes, in seconds.
struct IslandTiming: Equatable {
    /// The pointer must stay this long over the island before it opens on hover,
    /// so passing over the notch on the way to the menu bar opens nothing.
    var hoverDwell: TimeInterval = 0.15
    /// After the pointer leaves, the player stays open this long, so a slip
    /// off the edge doesn't close it.
    var collapseDelay: TimeInterval = 0.35
    /// A paused track keeps its compact island this long before it hides.
    var pausedLinger: TimeInterval = 10
    var peekDuration: TimeInterval = 2.5
    /// A Claude notice («‹nome› está à tua espera», «✓ ‹nome› acabou») shows this
    /// long, counted again when another of its kind joins it.
    var noticeDuration: TimeInterval = 3.5
}

enum IslandEvent: Equatable {
    /// The system's current track, or its play state, changed.
    case track(id: String, isPlaying: Bool)
    /// Nothing is loaded any more (the player quit, the tab closed).
    case trackCleared
    case hoverEntered
    case hoverExited
    case clicked
    /// Claude Code's sessions changed (`IslandClaude.none` when the feature is off).
    case claude(IslandClaude)
    /// What one snapshot of the sessions had to say, all at once.
    case claudeNotices([ClaudeNotice])
    /// The page selector was used.
    case pageSelected(IslandPage)
    /// Fold the open island now (a session was opened in the Claude app). It stays
    /// folded while the pointer rests on it; leaving and coming back, or a click,
    /// opens it again.
    case dismissed
}

/// The island's decisions, as a value: events and dates in, a layout out. No
/// timers and no clock, so every rule can be tested with injected dates; the
/// controller asks `nextChange(after:)` and sleeps until then.
///
/// Priority: expanded > peek > compact > hidden. The island has something to show
/// (`hasContent`) with a track or with listed Claude sessions; without either it
/// takes no hover and no click.
struct IslandState {
    var openOnHover: Bool
    var peekOnTrackChange: Bool
    var timing: IslandTiming

    /// The track on show, `nil` once cleared.
    private var trackID: String?
    /// The last track seen, kept through a clear: a different id after it is "new".
    private var lastTrackID: String?
    private var isPlaying = false
    /// When the music went from playing to paused. `nil` if it never did while we
    /// watched (it was already paused when first seen): there is no linger then.
    private var pausedSince: Date?
    /// When the track last changed to a different one.
    private var peekSince: Date?
    private var hoverSince: Date?
    /// Opened by a click, or re-entered while folding: stays open while the
    /// pointer is over it, whatever `openOnHover` says.
    private var pinned = false
    /// Until when the player stays open after the pointer left.
    private var collapseAt: Date?
    /// Folded by `.dismissed` under a pointer that has not left yet.
    private var dismissed = false

    /// What the island knows of Claude Code.
    private(set) var claude = IslandClaude.none
    private var notice: IslandNotice?
    /// When `notice` came, or last took in another of its kind.
    private var noticeSince: Date?
    /// The page of the open island, held from the moment it opened (see `holdPage`).
    /// Stale while folded: only read while expanded.
    private var heldPage: IslandPage?

    init(openOnHover: Bool = true, peekOnTrackChange: Bool = true, timing: IslandTiming = IslandTiming()) {
        self.openOnHover = openOnHover
        self.peekOnTrackChange = peekOnTrackChange
        self.timing = timing
    }

    /// The state of an island that has just come up (a screen plugged in) beside
    /// `other`: its settings and what there is to show (the track, how long it has
    /// been paused, the sessions), but no peek, no notice and no pointer. The next
    /// different track still peeks.
    init(contentOf other: IslandState) {
        self.init(openOnHover: other.openOnHover, peekOnTrackChange: other.peekOnTrackChange, timing: other.timing)
        trackID = other.trackID
        lastTrackID = other.lastTrackID
        isPlaying = other.isPlaying
        pausedSince = other.pausedSince
        claude = other.claude
    }

    /// A track, or listed Claude sessions: the island keeps its window and its
    /// hover zone, and the hover and the click can open it.
    var hasContent: Bool { trackID != nil || claude.listed > 0 }

    /// A track, or a session at work: what can bring the island up with no pointer
    /// on the notch. Only idle sessions listed, it stays hidden until the hover.
    var canShowOnItsOwn: Bool { trackID != nil || claude.active > 0 }

    mutating func handle(_ event: IslandEvent, at now: Date) {
        // The page is held as it was before the event, so the event can't move it.
        holdPage(at: now)
        switch event {
        case let .track(id, playing):
            // The very first track seen (after launch) never peeks: lastTrackID is nil.
            if let last = lastTrackID, last != id { peekSince = now }
            lastTrackID = id
            trackID = id
            if playing != isPlaying { pausedSince = playing ? nil : now }
            isPlaying = playing

        case .trackCleared:
            trackID = nil
            isPlaying = false
            pausedSince = nil
            peekSince = nil

        case .hoverEntered:
            // With nothing to show there is nothing to open; a pointer already inside
            // when something shows up is the controller's to report again.
            guard hasContent, hoverSince == nil else { return }
            // Back before it folded: keep it open instead of flickering.
            if presentation(at: now) == .expanded { pinned = true }
            collapseAt = nil
            dismissed = false
            hoverSince = now

        case .hoverExited:
            guard hoverSince != nil else { return }
            collapseAt = presentation(at: now) == .expanded
                ? now.addingTimeInterval(timing.collapseDelay) : nil
            hoverSince = nil
            pinned = false
            dismissed = false

        case .clicked:
            // A click can only land on the island, so it needs the pointer over it.
            guard hasContent, hoverSince != nil else { return }
            pinned = true
            dismissed = false

        case .claude(let claude):
            self.claude = claude
            // No session left, nothing to tell about.
            if claude.listed == 0 { clearNotice() }

        case .claudeNotices(let notices):
            // Open, the island already shows how the sessions are.
            guard !isExpanded(at: now) else { return }
            for notice in notices { take(IslandNotice(notice), at: now) }

        case .pageSelected(let page):
            guard isExpanded(at: now), hasBothPages else { return }
            heldPage = page

        case .dismissed:
            pinned = false
            collapseAt = nil
            dismissed = hoverSince != nil
        }
        if !hasContent { forgetPointer() }
        // A click may have just opened it, or the event took the page away.
        holdPage(at: now)
    }

    func presentation(at now: Date) -> IslandPresentation {
        if isExpanded(at: now) { return .expanded }
        if peek(at: now) != nil { return .peek }
        if isCompact(at: now) { return .compact }
        return .hidden
    }

    /// Everything the island draws at `now`. See `IslandLayout` for each field.
    func layout(at now: Date) -> IslandLayout {
        let presentation = presentation(at: now)
        let musicInView = isMusicInView(at: now)
        var layout = IslandLayout.music(presentation)
        layout.claudeActivity = claude.activity
        layout.activeSessions = claude.active
        switch presentation {
        case .hidden:
            break
        case .compact:
            layout.wings = musicInView ? .music : .claude
        case .peek:
            let peek = peek(at: now) ?? .track
            layout.peek = peek
            layout.wings = peek == .track || musicInView ? .music : .claude
        case .expanded:
            let page = openPage(at: now)
            layout.page = page
            layout.wings = page == .music || trackID != nil ? .music : .claude
            layout.showsPageSelector = hasBothPages
            if page == .claude {
                layout.claudeRows = min(claude.listed, IslandMetrics.claudeMaxRows)
                layout.hasAgentsStrip = claude.hasMyAgents
            }
        }
        if presentation == .compact || presentation == .peek, layout.wings == .music {
            layout.coverBadge = claude.activity
        }
        return layout
    }

    /// The next instant after `now` when the layout can change with no new event,
    /// or `nil` if nothing is pending. May name an instant that turns out not to
    /// change anything (a higher priority still on top).
    func nextChange(after now: Date) -> Date? {
        var instants: [Date] = []
        if let hoverSince, !pinned, !dismissed, openOnHover {
            instants.append(hoverSince.addingTimeInterval(timing.hoverDwell))
        }
        if let collapseAt { instants.append(collapseAt) }
        if let peekSince, isPlaying, peekOnTrackChange {
            instants.append(peekSince.addingTimeInterval(timing.peekDuration))
        }
        if let pausedSince, !isPlaying {
            instants.append(pausedSince.addingTimeInterval(timing.pausedLinger))
        }
        if let noticeSince {
            instants.append(noticeSince.addingTimeInterval(timing.noticeDuration))
        }
        return instants.filter { $0 > now }.min()
    }

    // MARK: Rules

    /// The pointer is over the island and it was clicked, or it has dwelt long
    /// enough; or it just left and the collapse delay has not run out.
    private func isExpanded(at now: Date) -> Bool {
        if let hoverSince, !dismissed {
            if pinned { return true }
            if openOnHover && now >= hoverSince.addingTimeInterval(timing.hoverDwell) { return true }
        }
        if let collapseAt, now < collapseAt { return true }
        return false
    }

    /// A notice beats a new track's title.
    private func peek(at now: Date) -> IslandPeek? {
        if let notice, let noticeSince, now < noticeSince.addingTimeInterval(timing.noticeDuration) {
            return .notice(notice)
        }
        return isPeekingTrack(at: now) ? .track : nil
    }

    /// A new track that is playing, for `peekDuration` from the change. It counts
    /// from the change, not from the first sound: a track whose play state lags a
    /// moment behind its title still peeks for the time that is left.
    private func isPeekingTrack(at now: Date) -> Bool {
        guard peekOnTrackChange, isPlaying, let peekSince else { return false }
        return now < peekSince.addingTimeInterval(timing.peekDuration)
    }

    /// The music in view: playing, or paused for less than `pausedLinger`.
    private func isMusicInView(at now: Date) -> Bool {
        guard trackID != nil else { return false }
        if isPlaying { return true }
        guard let pausedSince else { return false }
        return now < pausedSince.addingTimeInterval(timing.pausedLinger)
    }

    /// The music in view takes the wings; else active sessions take them.
    private func isCompact(at now: Date) -> Bool {
        isMusicInView(at: now) || claude.active > 0
    }

    // MARK: Pages

    private func has(_ page: IslandPage) -> Bool {
        page == .music ? trackID != nil : claude.listed > 0
    }

    private var hasBothPages: Bool { has(.music) && has(.claude) }

    /// The page the island opens on: Claude while a session waits, else the music
    /// in view, else Claude with listed sessions, else the music.
    private func pageOnOpening(at time: Date) -> IslandPage {
        if claude.isWaiting { return .claude }
        if isMusicInView(at: time) { return .music }
        return claude.listed > 0 ? .claude : .music
    }

    /// The open page: the held one, or, until an event holds it, the one picked
    /// when the hover dwell opened it. A page that no longer exists gives way to
    /// the other (with neither, the island has already folded).
    private func openPage(at now: Date) -> IslandPage {
        var opening = now
        if let hoverSince, openOnHover {
            opening = min(now, hoverSince.addingTimeInterval(timing.hoverDwell))
        }
        let page = heldPage ?? pageOnOpening(at: opening)
        return has(page) ? page : page.other
    }

    /// While open, fixes the page (so the music pausing past its linger, or a
    /// session starting to wait, never turns it), and drops the notice: open, the
    /// island already shows it. Called around every event: the island only opens
    /// by an event (a click) or by the dwell, which is worked out lazily.
    private mutating func holdPage(at now: Date) {
        guard isExpanded(at: now) else {
            heldPage = nil
            return
        }
        heldPage = openPage(at: now)
        clearNotice()
    }

    // MARK: Notices

    /// A waiting notice takes the place of a finished one; a finished one never
    /// covers a waiting one; one of the kind on show joins it and shows it longer.
    private mutating func take(_ incoming: IslandNotice, at now: Date) {
        if var current = notice, let noticeSince, now < noticeSince.addingTimeInterval(timing.noticeDuration) {
            if current.kind == incoming.kind {
                current.join(incoming)
                notice = current
                self.noticeSince = now
                return
            }
            if current.kind == .waiting { return }
        }
        notice = incoming
        noticeSince = now
    }

    private mutating func clearNotice() {
        notice = nil
        noticeSince = nil
    }

    /// Nothing left to show: no hover, no click, no collapse delay.
    private mutating func forgetPointer() {
        hoverSince = nil
        pinned = false
        collapseAt = nil
        dismissed = false
        heldPage = nil
        clearNotice()
    }
}
