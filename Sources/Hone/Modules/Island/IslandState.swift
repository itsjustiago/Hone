import Foundation

/// What the island shows, from nothing to the full player.
enum IslandPresentation: Equatable {
    /// Only the hover zone inside the notch: nothing to see.
    case hidden
    /// Cover and equaliser in the wings beside the notch.
    case compact
    /// The title, shown for a moment when the track changes.
    case peek
    /// The full player: cover, title and controls.
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
}

enum IslandEvent: Equatable {
    /// The system's current track, or its play state, changed.
    case track(id: String, isPlaying: Bool)
    /// Nothing is loaded any more (the player quit, the tab closed).
    case trackCleared
    case hoverEntered
    case hoverExited
    case clicked
}

/// The island's decisions, as a value: events and dates in, a presentation out.
/// No timers and no clock, so every rule can be tested with injected dates; the
/// controller asks `nextChange(after:)` and sleeps until then.
///
/// Priority: expanded > peek > compact > hidden.
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

    init(openOnHover: Bool = true, peekOnTrackChange: Bool = true, timing: IslandTiming = IslandTiming()) {
        self.openOnHover = openOnHover
        self.peekOnTrackChange = peekOnTrackChange
        self.timing = timing
    }

    mutating func handle(_ event: IslandEvent, at now: Date) {
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
            hoverSince = nil
            pinned = false
            collapseAt = nil

        case .hoverEntered:
            // Without a track there is nothing to open; a pointer already inside
            // when one shows up is the controller's to report again.
            guard trackID != nil, hoverSince == nil else { return }
            // Back before it folded: keep it open instead of flickering.
            if presentation(at: now) == .expanded { pinned = true }
            collapseAt = nil
            hoverSince = now

        case .hoverExited:
            guard hoverSince != nil else { return }
            collapseAt = presentation(at: now) == .expanded
                ? now.addingTimeInterval(timing.collapseDelay) : nil
            hoverSince = nil
            pinned = false

        case .clicked:
            // A click can only land on the island, so it needs the pointer over it.
            guard trackID != nil, hoverSince != nil else { return }
            pinned = true
        }
    }

    func presentation(at now: Date) -> IslandPresentation {
        guard trackID != nil else { return .hidden }
        if isExpanded(at: now) { return .expanded }
        if isPeeking(at: now) { return .peek }
        if isCompact(at: now) { return .compact }
        return .hidden
    }

    /// The next instant after `now` when the presentation can change with no new
    /// event, or `nil` if nothing is pending. May name an instant that turns out
    /// not to change anything (a higher priority still on top).
    func nextChange(after now: Date) -> Date? {
        guard trackID != nil else { return nil }
        var instants: [Date] = []
        if let hoverSince, !pinned, openOnHover {
            instants.append(hoverSince.addingTimeInterval(timing.hoverDwell))
        }
        if let collapseAt { instants.append(collapseAt) }
        if let peekSince, isPlaying, peekOnTrackChange {
            instants.append(peekSince.addingTimeInterval(timing.peekDuration))
        }
        if let pausedSince, !isPlaying {
            instants.append(pausedSince.addingTimeInterval(timing.pausedLinger))
        }
        return instants.filter { $0 > now }.min()
    }

    // MARK: Rules

    /// The pointer is over the island and it was clicked, or it has dwelt long
    /// enough; or it just left and the collapse delay has not run out.
    private func isExpanded(at now: Date) -> Bool {
        if let hoverSince {
            if pinned { return true }
            if openOnHover && now >= hoverSince.addingTimeInterval(timing.hoverDwell) { return true }
        }
        if let collapseAt, now < collapseAt { return true }
        return false
    }

    /// A new track that is playing, for `peekDuration` from the change. It counts
    /// from the change, not from the first sound: a track whose play state lags a
    /// moment behind its title still peeks for the time that is left.
    private func isPeeking(at now: Date) -> Bool {
        guard peekOnTrackChange, isPlaying, let peekSince else { return false }
        return now < peekSince.addingTimeInterval(timing.peekDuration)
    }

    private func isCompact(at now: Date) -> Bool {
        if isPlaying { return true }
        guard let pausedSince else { return false }
        return now < pausedSince.addingTimeInterval(timing.pausedLinger)
    }
}
