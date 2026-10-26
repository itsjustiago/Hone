import SwiftUI
import HoneDesign

/// What the island can ask of the controller. No-ops by default (previews).
struct IslandActions {
    var hover: @MainActor (Bool) -> Void = { _ in }
    var click: @MainActor () -> Void = {}
    var send: @MainActor (NowPlayingCommand) -> Void = { _ in }
    var openApp: @MainActor () -> Void = {}
}

/// The island in one presentation, from plain values so the preview renderer can
/// draw it offscreen. It draws itself at the top centre of whatever space it is
/// given: the panel gives it a fixed canvas centred on the notch.
struct IslandView: View {
    let presentation: IslandPresentation
    let notch: CGSize
    let track: NowPlayingTrack?
    let artwork: IslandArtwork?
    let appName: String?
    var actions = IslandActions()

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGSize { IslandMetrics.size(for: presentation, notch: notch) }
    private var ear: CGFloat { IslandMetrics.earRadius(for: presentation) }
    private var shape: NotchShape {
        NotchShape(earRadius: ear, bottomRadius: IslandMetrics.bottomRadius(for: presentation))
    }
    private var tint: Color { artwork?.tint ?? IslandPalette.fallbackTint }
    private var isPlaying: Bool { track?.isPlaying ?? false }

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(IslandPalette.island)
            content
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .onHover { actions.hover($0) }
        .onTapGesture { actions.click() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The wings stay put from compact to expanded (only the cover leaves them for
    /// the player, and the equaliser goes: the pause button says the state); what
    /// sits under the notch comes in and out on its own.
    @ViewBuilder
    private var content: some View {
        if let track, presentation != .hidden {
            VStack(spacing: 0) {
                wings(showsItems: presentation != .expanded)
                switch presentation {
                case .peek:
                    peekLine(track)
                        .transition(contentTransition)
                case .expanded:
                    player(track)
                        .transition(contentTransition)
                case .hidden, .compact:
                    EmptyView()
                }
            }
            .transition(contentTransition)
        }
    }

    /// Comes in a beat after the shape, out of a blur and from a touch smaller,
    /// anchored at the top; leaves at once with a quick fade.
    private var contentTransition: AnyTransition {
        let insertion: AnyTransition = reduceMotion
            ? AnyTransition.opacity.animation(IslandMotion.reduced)
            : AnyTransition.modifier(active: IslandContentEntrance(progress: 0),
                                     identity: IslandContentEntrance(progress: 1))
                .animation(IslandMotion.contentIn)
        return .asymmetric(insertion: insertion, removal: AnyTransition.opacity.animation(IslandMotion.contentOut))
    }

    // MARK: Beside the notch

    /// Cover in the left wing, equaliser in the right one, the notch in between.
    /// Both sit in a box the size of the small cover, the same distance from the
    /// island's sides.
    private func wings(showsItems: Bool) -> some View {
        let wing = max(0, (size.width - notch.width) / 2 - ear)
        let inset = max(0, (notch.height - IslandMetrics.smallCover) / 2)
        return HStack(spacing: 0) {
            ZStack {
                if showsItems {
                    IslandCover(artwork: artwork, size: IslandMetrics.smallCover,
                                corner: IslandMetrics.smallCoverCorner)
                        .matchedGeometryEffect(id: "cover", in: namespace)
                }
            }
            .padding(.leading, inset)
            .frame(width: wing, alignment: .leading)
            Spacer(minLength: 0)
            ZStack {
                if showsItems {
                    IslandEqualizer(isPlaying: isPlaying, tint: tint)
                        .animation(IslandMotion.trackChange, value: tint)
                }
            }
            .padding(.trailing, inset)
            .frame(width: wing, alignment: .trailing)
        }
        .padding(.horizontal, ear)
        .frame(width: size.width, height: notch.height)
    }

    /// «Título — Artista» on one line, under the notch.
    private func peekLine(_ track: NowPlayingTrack) -> some View {
        ZStack {
            Text(Self.peekText(track))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .id(track.id)
                .transition(.opacity)
        }
        .animation(IslandMotion.trackChange, value: track.id)
        .padding(.horizontal, ear + 16)
        .frame(width: size.width, height: IslandMetrics.peekExtraHeight - 4, alignment: .center)
    }

    static func peekText(_ track: NowPlayingTrack) -> AttributedString {
        var title = AttributedString(track.title.isEmpty ? track.artist : track.title)
        title.foregroundColor = IslandPalette.primaryText
        title.font = .system(size: 12, weight: .semibold)
        guard !track.title.isEmpty, !track.artist.isEmpty else { return title }
        var artist = AttributedString(" — " + track.artist)
        artist.foregroundColor = IslandPalette.secondaryText
        return title + artist
    }

    // MARK: The open player

    /// The cover row and, under it, the progress row, `expandedInset` from the body's
    /// sides and bottom. A stream with no length has no progress row: the cover row
    /// then sits in the middle of the space under the notch.
    private func player(_ track: NowPlayingTrack) -> some View {
        let hasProgress = track.duration != nil
        return VStack(spacing: IslandMetrics.expandedRowSpacing) {
            HStack(spacing: 12) {
                Button(action: actions.openApp) {
                    IslandCover(artwork: artwork, size: IslandMetrics.largeCover,
                                corner: IslandMetrics.largeCoverCorner)
                        .matchedGeometryEffect(id: "cover", in: namespace)
                }
                .buttonStyle(IslandPressStyle())
                .accessibilityLabel(appName.map { "Abrir \($0)" } ?? "Abrir o leitor")

                // Both titles overlap while a new track crossfades in: no jump in width.
                ZStack(alignment: .leading) {
                    titles(track)
                        .id(track.id)
                        .transition(.opacity)
                }
                .animation(IslandMotion.trackChange, value: track.id)
                Spacer(minLength: 4)
                controls(track)
            }
            if let duration = track.duration {
                IslandProgressRow(track: track, duration: duration, tint: tint,
                                  ticking: track.isPlaying, seek: { actions.send(.seek($0)) })
                    .animation(IslandMotion.trackChange, value: tint)
            }
        }
        .padding(.horizontal, ear + IslandMetrics.expandedInset)
        .padding(.top, hasProgress ? IslandMetrics.expandedTopGap : 0)
        .padding(.bottom, hasProgress ? IslandMetrics.expandedBottomPadding : 0)
        .frame(width: size.width, height: size.height - notch.height)
    }

    private func titles(_ track: NowPlayingTrack) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title.isEmpty ? "Sem título" : track.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(IslandPalette.primaryText)
            if !track.artist.isEmpty {
                Text(track.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(IslandPalette.secondaryText)
            }
            if let appName {
                Text(appName)
                    .font(.system(size: 11))
                    .foregroundStyle(IslandPalette.tertiaryText)
                    .padding(.top, 2)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    /// Their hit areas are round and wider than the glyphs, so the last one reaches
    /// past the inset: the ⏭ glyph, not its empty margin, sits on it.
    private func controls(_ track: NowPlayingTrack) -> some View {
        HStack(spacing: 2) {
            IslandControlButton(systemName: "backward.fill", glyphSize: 14, label: "Anterior") {
                actions.send(.previous)
            }
            IslandControlButton(systemName: track.isPlaying ? "pause.fill" : "play.fill", glyphSize: 20,
                                label: track.isPlaying ? "Pausar" : "Tocar") {
                actions.send(.toggle)
            }
            IslandControlButton(systemName: "forward.fill", glyphSize: 14, label: "Seguinte") {
                actions.send(.next)
            }
        }
        .padding(.trailing, -IslandMetrics.controlGlyphInset)
    }
}

/// The content's way in: blurred, transparent and a touch smaller at 0, as it is at
/// 1. The blur is 0 at rest, so it only costs while the content arrives.
private struct IslandContentEntrance: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - (1 - progress) * (1 - IslandMotion.contentScale), anchor: .top)
            .blur(radius: (1 - progress) * IslandMotion.contentBlur)
            .opacity(progress)
    }
}
