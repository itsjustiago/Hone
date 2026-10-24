import AppKit

/// The player's time maths: labels, the bar's fill and where a click on it lands.
/// Pure, so it is tested without a view.
enum IslandTime {
    /// The longest time the player shows (99:59:59). `Int(_:)` traps on a Double it
    /// cannot hold, and an app may publish any number, so it is capped first.
    static let maxLabelSeconds: TimeInterval = 359_999

    /// `m:ss` under an hour, `h:mm:ss` from there. Anything not a real, positive
    /// number of seconds reads as `0:00`; an absurdly long one reads as the cap.
    static func format(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? Int(min(max(0, seconds), maxLabelSeconds).rounded(.down)) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// How full the progress bar is, 0…1. 0 when the length is unknown.
    static func fraction(position: TimeInterval, duration: TimeInterval?) -> Double {
        guard let duration, duration > 0, position.isFinite else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    /// The instant a click or drag at `x` (points from the bar's leading edge) asks
    /// for. `nil` when the track has no length or the bar no width: nothing to seek.
    static func seconds(atX x: CGFloat, width: CGFloat, duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration > 0, width > 0, x.isFinite else { return nil }
        let fraction = min(max(Double(x / width), 0), 1)
        return fraction * duration
    }
}

/// Hover rules the state machine leaves to the controller.
enum IslandHover {
    /// `IslandState` ignores a hover while no track is loaded, and AppKit sends no
    /// new "entered" to a pointer that never moved. So when a track shows up under
    /// a pointer that is already over the notch, the controller reports it again.
    static func shouldReenter(hadTrack: Bool, hasTrack: Bool, pointerInside: Bool) -> Bool {
        !hadTrack && hasTrack && pointerInside
    }

    /// Whether the pointer is over `frame` (global AppKit coordinates). `CGRect.contains`
    /// leaves out the top edge, and that is exactly the row the pointer sits on when
    /// it is pushed to the top of the screen (`mouseLocation.y == maxY`), where the
    /// island lives. `NSMouseInRect` counts that edge in.
    static func pointerInside(_ pointer: CGPoint, frame: CGRect) -> Bool {
        NSMouseInRect(pointer, frame, false)
    }
}

/// The Settings line about the music source.
struct IslandSourceStatus: Equatable {
    enum Tone: Equatable { case off, ok, idle, problem }

    let text: String
    let tone: Tone

    init(status: NowPlayingClient.Status, hasTrack: Bool) {
        switch status {
        case .stopped:
            text = "Desligada"; tone = .off
        case .running:
            text = hasTrack ? "A ler a música" : "Sem música a tocar"
            tone = hasTrack ? .ok : .idle
        case .unavailable(let reason):
            text = reason; tone = .problem
        }
    }
}
