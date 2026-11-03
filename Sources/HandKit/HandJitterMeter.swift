import Foundation

/// Measures how much a point shakes while it should be still: the RMS distance of the
/// last second's samples to their own centre, in whatever units the points come in.
/// Only reports while the point is at rest (the window's extent is below `restSpan` on
/// both axes); a moving point is not jitter, so it reads nil. For independent noise of
/// σ per axis the RMS distance is σ·√2.
public struct HandJitterMeter: Sendable {
    /// Seconds of samples kept.
    public let window: Double
    /// Resting = the window's max − min is below this on x and on y.
    public let restSpan: Double
    /// Fewer samples than this is too little to say.
    public let minSamples: Int

    private var samples: [(t: Double, p: HandPoint)] = []

    public init(window: Double = 1.0, restSpan: Double = 0.02, minSamples: Int = 10) {
        self.window = window
        self.restSpan = restSpan
        self.minSamples = minSamples
    }

    /// `t` in seconds, non-decreasing (an earlier `t` starts over).
    public mutating func add(t: Double, point: HandPoint) {
        if let last = samples.last, t < last.t { samples.removeAll(keepingCapacity: true) }
        samples.append((t, point))
        let old = samples.prefix { $0.t < t - window }.count
        if old > 0 { samples.removeFirst(old) }
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// RMS distance to the window's centre, or nil while the point moves or there are too few samples.
    public var jitter: Double? {
        guard samples.count >= max(minSamples, 1) else { return nil }
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        var sumX = 0.0, sumY = 0.0
        for (_, p) in samples {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
            sumX += p.x; sumY += p.y
        }
        guard maxX - minX < restSpan, maxY - minY < restSpan else { return nil }
        let n = Double(samples.count)
        let cx = sumX / n, cy = sumY / n
        var squares = 0.0
        for (_, p) in samples {
            let dx = p.x - cx, dy = p.y - cy
            squares += dx * dx + dy * dy
        }
        return (squares / n).squareRoot()
    }
}
