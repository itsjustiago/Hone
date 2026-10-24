import Foundation

/// What is playing right now, as the adapter last reported it. A plain value (no
/// AppKit) so the Island and the tests can use it freely.
struct NowPlayingTrack: Equatable {
    /// contentID, or title + U+001F + artist when the app gives none. The adapter
    /// derives the same key (`trackKey` in HoneNowPlaying.m): it re-sends the
    /// artwork exactly when this changes.
    var id: String
    var title: String
    var artist: String
    var album: String
    /// nil for live streams and anything the app gives no length for.
    var duration: TimeInterval?
    /// Position as of `elapsedSampledAt`; use `position(at:)` to read it.
    var elapsed: TimeInterval
    var elapsedSampledAt: Date
    var playbackRate: Double
    var isPlaying: Bool
    /// The app the user sees (Safari for a web page), when the adapter could tell.
    var bundleID: String?
    var pid: Int32?
    var artwork: Data?

    static func makeID(contentID: String?, title: String, artist: String) -> String {
        if let contentID, !contentID.isEmpty { return contentID }
        return title + "\u{1F}" + artist
    }

    /// Where the playhead is at `now`: it only moves while playing, scaled by the
    /// rate, and never leaves [0, duration] (or [0, `maxSeconds`] without a duration).
    /// Clocks drift, so a sample "from the future" counts as no time elapsed.
    func position(at now: Date) -> TimeInterval {
        var value = elapsed
        if isPlaying {
            value += max(0, now.timeIntervalSince(elapsedSampledAt)) * playbackRate
        }
        if let duration { value = min(value, duration) }
        return min(max(value, 0), NowPlayingProtocol.maxSeconds)
    }
}

/// What the Island can ask of the player. `wire` is the line the adapter reads on
/// stdin (see HoneNowPlaying.m).
enum NowPlayingCommand: Equatable {
    case play
    case pause
    case toggle
    case next
    case previous
    case seek(TimeInterval)

    var wire: String {
        switch self {
        case .play: return "play"
        case .pause: return "pause"
        case .toggle: return "toggle"
        case .next: return "next"
        case .previous: return "previous"
        case .seek(let seconds):
            // "%.3f" is never localised, so the adapter always sees a dot.
            let safe = seconds.isFinite ? max(0, seconds) : 0
            return "seek " + String(format: "%.3f", safe)
        }
    }
}
