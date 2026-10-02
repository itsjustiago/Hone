import SwiftUI

/// Hone's mascot: a soft, wider-than-tall blob with two little eyes glancing
/// down and to the right. Every tool wears one in its own colour; its mood
/// tells the tool's state at a glance. Reads well from 18pt to 70pt tall.
public struct Blob: View {
    public enum Mood: Sendable, CaseIterable {
        /// On and working: open eyes that blink now and then.
        case awake
        /// Off: dimmed body, eyes closed.
        case asleep
        /// Needs attention: bigger, rounder eyes looking straight ahead.
        case alert
    }

    let color: Color
    let mood: Mood
    let height: CGFloat
    let glow: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blinking = false

    /// - Parameters:
    ///   - height: body height in points; width follows the mascot's ~1.3:1 ratio.
    ///   - glow: soft halo in the body colour — for the large hero blob only.
    public init(color: Color, mood: Mood = .awake, height: CGFloat, glow: Bool = false) {
        self.color = color
        self.mood = mood
        self.height = height
        self.glow = glow
    }

    // Proportions measured from the reference mascot.
    private var width: CGFloat { height * 1.3 }
    private var radius: CGFloat { height * 0.4 }

    /// Asleep, the body sinks toward the card so the tool reads as "off"
    /// without losing its identity colour.
    private var bodyColor: Color {
        mood == .asleep ? color.vibeMix(over: VibeColor.card, amount: 0.38) : color
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(bodyColor)
            .frame(width: width, height: height)
            .overlay { eyes }
            .shadow(color: glow && mood != .asleep ? color.opacity(0.3) : .clear, radius: 14)
            .task(id: mood) { await blinkLoop() }
            .accessibilityHidden(true)
    }

    /// 0 at pill size, 1 at hero size. Small blobs get bigger, higher eyes so
    /// they still read at 19pt; large ones keep the reference's low glance.
    private var scaleT: CGFloat { min(max((height - 20) / 24, 0), 1) }
    private func lerp(_ small: CGFloat, _ large: CGFloat) -> CGFloat { small + (large - small) * scaleT }

    private var gazeCenters: [(CGFloat, CGFloat)] {
        let y = lerp(0.64, 0.79)
        return [(lerp(0.37, 0.48), y), (lerp(0.67, 0.76), y)]
    }

    @ViewBuilder
    private var eyes: some View {
        switch mood {
        case .awake:
            eyePair(size: CGSize(width: height * lerp(0.24, 0.14), height: height * lerp(0.22, 0.125)),
                    centers: gazeCenters)
                .scaleEffect(y: blinking ? 0.12 : 1, anchor: .center)
        case .alert:
            let y = lerp(0.56, 0.66)
            eyePair(size: CGSize(width: height * lerp(0.26, 0.165), height: height * lerp(0.26, 0.165)),
                    centers: [(lerp(0.36, 0.40), y), (lerp(0.62, 0.64), y)])
        case .asleep:
            // Closed: short soft dashes where the eyes were.
            eyePair(size: CGSize(width: height * lerp(0.24, 0.16), height: max(1.5, height * lerp(0.07, 0.045))),
                    centers: gazeCenters,
                    color: VibeColor.blobEye.opacity(0.75))
        }
    }

    private func eyePair(size: CGSize, centers: [(CGFloat, CGFloat)],
                         color: Color = VibeColor.blobEye) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(centers.indices, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: size.width, height: size.height)
                    .position(x: width * centers[i].0, y: height * centers[i].1)
            }
        }
        .frame(width: width, height: height)
    }

    /// Random blinks every 3.5–7s while on screen. `.task` stops with the view,
    /// and Reduce Motion keeps the eyes still.
    private func blinkLoop() async {
        guard mood == .awake, !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 3500...7000)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.07)) { blinking = true }
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.easeOut(duration: 0.09)) { blinking = false }
        }
    }
}
