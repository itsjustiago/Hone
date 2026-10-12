// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import Foundation

public enum FoldMath {
    public static func progress(angle: Double, clearAngle: Double) -> Double {
        guard angle.isFinite, clearAngle.isFinite else { return 0 }
        let clear = min(140, max(60, clearAngle))
        let t = min(1, max(0, (clear - angle) / (clear - 5)))
        return t * t * (3 - 2 * t)
    }

    public static func smooth(current: Double, target: Double, dt: Double) -> Double {
        guard current.isFinite, target.isFinite, dt.isFinite else { return 0 }
        let t = min(1, max(0, target))
        let next = current + (t - current) * (1 - exp(-max(0, dt) / 0.045))
        return abs(next - t) < 0.0001 ? t : next
    }

    public static func decodeReport(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 3, bytes[0] == 1 else { return nil }
        let angle = Int(bytes[1]) | (Int(bytes[2]) << 8)
        guard (0...180).contains(angle) else { return nil }
        return Double(angle)
    }
}

/// One clock can drive both the desktop and its preview, regardless of which
/// view draws first or whether they draw at different refresh rates.
public struct FoldAnimation {
    public private(set) var progress: Double = 0
    private var lastTime: TimeInterval?
    public init() {}
    public mutating func reset() { self = FoldAnimation() }
    public mutating func prime(at now: TimeInterval) { lastTime = now }
    public mutating func sample(target: Double, at now: TimeInterval) -> Double {
        let dt = lastTime.map { min(0.1, max(0, now - $0)) } ?? 0
        progress = FoldMath.smooth(current: progress, target: target, dt: dt)
        lastTime = now
        return progress
    }
}

public enum FoldFramePacing {
    public static func rate(maximum: Int, externalPower: Bool, lowPower: Bool, thermalPressure: Bool, moving: Bool) -> Int {
        let cap = thermalPressure ? 30 : (externalPower && !lowPower && moving ? 120 : 60)
        return max(1,min(maximum,cap))
    }
}
