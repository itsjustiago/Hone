import SwiftUI
import HoneDesign

/// The cover, or a note on dark grey when the track has none (or it didn't decode).
struct IslandCover: View {
    let artwork: IslandArtwork?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        ZStack {
            if let artwork {
                Image(nsImage: artwork.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                IslandPalette.placeholder
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(IslandPalette.tertiaryText)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Four bars that dance while the music plays. Pure animation, no audio is read:
/// each bar breathes at its own pace so they never move in step. Paused (or with
/// Reduce Motion on) they stand still, low when paused.
///
/// The motion is a function of the clock (`IslandEqualizerMotion`) drawn by a
/// `TimelineView` a dozen times a second, and only while playing: no animation
/// loop of SwiftUI's own, which would redraw at the display's rate (120 Hz) for as
/// long as the compact island is up.
struct IslandEqualizer: View {
    let isPlaying: Bool
    let tint: Color

    static let barWidth: CGFloat = 3
    static let maxHeight: CGFloat = 14
    /// Height of a bar of a paused track.
    private static let pausedHeight: CGFloat = 3
    /// Frames per second while playing.
    private static let tick: TimeInterval = 1.0 / 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isPlaying && !reduceMotion {
                TimelineView(.animation(minimumInterval: Self.tick)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    bars(IslandEqualizerMotion.bars.indices.map {
                        CGFloat(IslandEqualizerMotion.fraction(bar: $0, at: time)) * Self.maxHeight
                    })
                }
            } else {
                bars(IslandEqualizerMotion.bars.indices.map {
                    isPlaying ? CGFloat(IslandEqualizerMotion.restingFraction(bar: $0)) * Self.maxHeight
                              : Self.pausedHeight
                })
            }
        }
        .frame(height: Self.maxHeight)
        .accessibilityHidden(true)
    }

    private func bars(_ heights: [CGFloat]) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: Self.barWidth, height: heights[index])
            }
        }
    }
}

/// A round control of the open player: the glyph, a soft disc on hover, a small
/// press. Plain so it never takes focus.
struct IslandControlButton: View {
    let systemName: String
    let glyphSize: CGFloat
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(IslandPalette.primaryText)
                .frame(width: 34, height: 34)
                .background(Circle().fill(hovering ? IslandPalette.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(IslandPressStyle())
        .onHover { hovering = $0 }
        .animation(VibeMotion.quick, value: hovering)
        .accessibilityLabel(label)
    }
}

struct IslandPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(VibeMotion.quick, value: configuration.isPressed)
    }
}

/// Elapsed time, the bar and the length. The bar can be clicked or dragged to
/// seek. Ticks once a second only while `ticking` (playing and open).
struct IslandProgressRow: View {
    let track: NowPlayingTrack
    let duration: TimeInterval
    let tint: Color
    let ticking: Bool
    let seek: (TimeInterval) -> Void

    /// Where a drag is, 0…1, while it lasts.
    @State private var scrub: Double?

    var body: some View {
        if ticking {
            TimelineView(.periodic(from: .now, by: 1)) { context in row(at: context.date) }
        } else {
            row(at: Date())
        }
    }

    private func row(at date: Date) -> some View {
        let position = scrub.map { $0 * duration } ?? track.position(at: date)
        let fraction = scrub ?? IslandTime.fraction(position: position, duration: duration)
        return HStack(spacing: 8) {
            timeLabel(position, alignment: .trailing)
            bar(fraction: fraction)
            timeLabel(duration, alignment: .leading)
        }
    }

    private func timeLabel(_ seconds: TimeInterval, alignment: Alignment) -> some View {
        Text(IslandTime.format(seconds))
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(IslandPalette.tertiaryText)
            .lineLimit(1)
            .frame(minWidth: 34, alignment: alignment)
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(IslandPalette.track)
                Capsule().fill(tint).frame(width: max(4, geo.size.width * fraction))
            }
            .frame(height: scrub == nil ? 4 : 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard geo.size.width > 0 else { return }
                        scrub = min(max(Double(value.location.x / geo.size.width), 0), 1)
                    }
                    .onEnded { value in
                        if let seconds = IslandTime.seconds(atX: value.location.x, width: geo.size.width,
                                                            duration: duration) {
                            seek(seconds)
                        }
                        scrub = nil
                    }
            )
            .animation(VibeMotion.quick, value: scrub == nil)
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("Progresso")
        .accessibilityValue("\(IslandTime.format(fraction * duration)) de \(IslandTime.format(duration))")
    }
}
