import SwiftUI
import HoneDesign

/// The cover, or a note on dark grey when the track has none (or it didn't decode).
struct IslandCover: View {
    let artwork: IslandArtwork?
    let size: CGFloat
    let corner: CGFloat

    /// Dev tool: told of the island's cover frame each time the island is drawn
    /// (`IslandFrameProbe`). Nil in the app.
    nonisolated(unsafe) static var probe: ((CGRect) -> Void)?

    /// Which picture is up: a new one crossfades over the old one.
    private var key: ObjectIdentifier? { artwork.map { ObjectIdentifier($0.image) } }

    var body: some View {
        ZStack {
            picture
                .id(key)
                .transition(.opacity)
        }
        .animation(IslandMotion.trackChange, value: key)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    @ViewBuilder
    private var picture: some View {
        if let artwork {
            Image(nsImage: artwork.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                IslandPalette.placeholder
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(IslandPalette.tertiaryText)
            }
        }
    }
}

/// Four bars that dance while the music plays, centred in a box the size of the
/// small cover so the right wing mirrors the cover in the left one. Pure animation,
/// no audio is read: each bar breathes at its own pace so they never move in step.
/// Paused, they stand still, all level at the bottom; a pause or a resume eases them
/// down or up (`IslandEqualizerLevel`). With Reduce Motion on they stand still while
/// playing too.
///
/// The motion is a function of the clock (`IslandEqualizerMotion`) drawn by a
/// `TimelineView` a dozen times a second while playing, at the display's rate only
/// for the ease, and not at all once still: no animation loop of SwiftUI's own,
/// which would redraw at the display's rate (120 Hz) for as long as the compact
/// island is up.
struct IslandEqualizer: View {
    let isPlaying: Bool
    let tint: Color

    static let barWidth: CGFloat = 3
    static let maxHeight: CGFloat = 14
    /// Frames per second while playing.
    private static let tick: TimeInterval = 1.0 / 12
    /// Dev tool: told of every frame the bars are drawn for (`IslandFrameProbe`). Nil in the app.
    nonisolated(unsafe) static var probe: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var level: IslandEqualizerLevel
    /// While `level` is on its way: the timeline runs at the display's rate.
    @State private var easing = false

    init(isPlaying: Bool, tint: Color) {
        self.isPlaying = isPlaying
        self.tint = tint
        _level = State(initialValue: IslandEqualizerLevel(playing: isPlaying))
    }

    var body: some View {
        // Settled, the bars only move when playing with motion on; otherwise nothing
        // depends on the clock and the timeline stops.
        let dancing = level.target == 1 && !reduceMotion
        TimelineView(.animation(minimumInterval: easing ? nil : Self.tick, paused: !easing && !dancing)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let amount = level.value(at: time)
            let _ = Self.probe?()
            bars(IslandEqualizerMotion.bars.indices.map {
                CGFloat(IslandEqualizerMotion.fraction(bar: $0, at: time, level: amount, still: reduceMotion))
                    * Self.maxHeight
            })
        }
        .frame(width: IslandMetrics.smallCover, height: IslandMetrics.smallCover)
        .onChange(of: isPlaying) { _, playing in
            level = level.retargeted(playing: playing, at: Date.now.timeIntervalSinceReferenceDate)
            easing = true
        }
        .task(id: level) {
            let left = level.end - Date.now.timeIntervalSinceReferenceDate
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            if !Task.isCancelled { easing = false }
        }
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
                .frame(width: IslandMetrics.controlHitSize, height: IslandMetrics.controlHitSize)
                .background(Circle().fill(hovering ? IslandPalette.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(IslandPressStyle())
        .onHover { hovering = $0 }
        .animation(VibeMotion.quick, value: hovering)
        .accessibilityLabel(label)
    }
}

/// A dot on the small cover's top right corner, a little past it, ringed in the
/// island's black: some Claude session waits (orange) or works (terracotta) while
/// the music has the wings. Still; it fades in and out.
struct IslandCoverBadge: View {
    let activity: IslandClaudeActivity

    static let size: CGFloat = 7
    static let ring: CGFloat = 1.5
    /// How far the dot reaches past the cover's top and right edges.
    static let reach: CGFloat = 2

    var body: some View {
        ZStack {
            if activity != .none {
                Circle()
                    .fill(IslandPalette.claude(activity))
                    .frame(width: Self.size, height: Self.size)
                    .padding(Self.ring)
                    .background(Circle().fill(IslandPalette.island))
                    .transition(.opacity)
            }
        }
        .offset(x: Self.reach + Self.ring, y: -(Self.reach + Self.ring))
        .animation(IslandMotion.badge, value: activity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The open island's two pages, music and Claude, as a small segmented control in
/// the notch row's right wing. Each segment takes the row's full height to click.
struct IslandPageSelector: View {
    let page: IslandPage
    /// Claude's segment shows its glyph in this state's colour (still).
    let activity: IslandClaudeActivity
    /// The notch row's height.
    let height: CGFloat
    let select: (IslandPage) -> Void

    static let segment = CGSize(width: 26, height: 20)
    static let padding: CGFloat = 2
    static var width: CGFloat { 2 * segment.width + 2 * padding }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(IslandPalette.chipFill)
                .frame(width: Self.width, height: Self.segment.height + 2 * Self.padding)
            Capsule()
                .fill(IslandPalette.selectedFill)
                .frame(width: Self.segment.width, height: Self.segment.height)
                .offset(x: Self.padding + (page == .music ? 0 : Self.segment.width))
                .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.selector, value: page)
            HStack(spacing: 0) {
                segment(.music, label: "Música") {
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(page == .music ? IslandPalette.primaryText : IslandPalette.secondaryText)
                }
                segment(.claude, label: "Claude") {
                    ClaudeGlyph(color: IslandPalette.claude(activity), size: 11)
                }
            }
            .padding(.horizontal, Self.padding)
        }
        .frame(width: Self.width, height: height)
    }

    private func segment(_ target: IslandPage, label: String,
                         @ViewBuilder glyph: () -> some View) -> some View {
        Button {
            if target != page { select(target) }
        } label: {
            glyph()
                .frame(width: Self.segment.width, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandPressStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(page == target ? .isSelected : [])
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
        // The labels hug the row's ends: the elapsed time's text starts at its left
        // edge and the length's ends at its right edge, in line with what is above.
        return HStack(spacing: 8) {
            timeLabel(position, alignment: .leading)
            bar(fraction: fraction)
            timeLabel(duration, alignment: .trailing)
        }
        .frame(height: IslandMetrics.progressRowHeight)
    }

    private func timeLabel(_ seconds: TimeInterval, alignment: Alignment) -> some View {
        Text(IslandTime.format(seconds))
            .font(.system(size: IslandMetrics.timeLabelFontSize, weight: .medium).monospacedDigit())
            .foregroundStyle(IslandPalette.tertiaryText)
            .lineLimit(1)
            .frame(minWidth: IslandMetrics.timeLabelMinWidth, alignment: alignment)
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
        .frame(height: IslandMetrics.progressRowHeight)
        .accessibilityElement()
        .accessibilityLabel("Progresso")
        .accessibilityValue("\(IslandTime.format(fraction * duration)) de \(IslandTime.format(duration))")
    }
}
