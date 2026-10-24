import Foundation

/// When to restart the adapter after it dies on its own, and when to stop trying.
/// Pure, so the timing is testable without a process.
struct NowPlayingRestartPolicy {
    enum Decision: Equatable {
        case retry(after: TimeInterval)
        case giveUp
    }

    /// Wait before the 1st, 2nd… consecutive restart; the last one repeats.
    static let delays: [TimeInterval] = [1, 2, 5, 10, 30]
    /// This many failures inside `window` and the adapter is not coming back.
    static let maxFailures = 5
    static let window: TimeInterval = 120
    /// An adapter that lived this long was healthy: its death starts the delays over.
    static let healthyUptime: TimeInterval = 60

    // The numbers above by default; the lifecycle tests shrink them.
    private let delays: [TimeInterval]
    private let maxFailures: Int
    private let window: TimeInterval
    private let healthyUptime: TimeInterval

    private var recent: [Date] = []
    private var consecutive = 0

    init(
        delays: [TimeInterval] = NowPlayingRestartPolicy.delays,
        maxFailures: Int = NowPlayingRestartPolicy.maxFailures,
        window: TimeInterval = NowPlayingRestartPolicy.window,
        healthyUptime: TimeInterval = NowPlayingRestartPolicy.healthyUptime
    ) {
        self.delays = delays.isEmpty ? Self.delays : delays
        self.maxFailures = maxFailures
        self.window = window
        self.healthyUptime = healthyUptime
    }

    /// `uptime` is how long the process that just died had been running.
    mutating func recordFailure(at now: Date, uptime: TimeInterval = 0) -> Decision {
        if uptime >= healthyUptime { consecutive = 0 }
        consecutive += 1
        recent = recent.filter { now.timeIntervalSince($0) < window }
        recent.append(now)
        if recent.count >= maxFailures { return .giveUp }
        return .retry(after: delays[min(consecutive, delays.count) - 1])
    }
}
