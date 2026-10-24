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
/// given: the panel may be larger for a moment while it grows or shrinks.
struct IslandView: View {
    let presentation: IslandPresentation
    let notch: CGSize
    let track: NowPlayingTrack?
    let artwork: IslandArtwork?
    let appName: String?
    var actions = IslandActions()

    @Namespace private var namespace

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

    @ViewBuilder
    private var content: some View {
        if let track {
            switch presentation {
            case .hidden:
                EmptyView()
            case .compact:
                wings(showsCover: true)
                    .transition(.opacity)
            case .peek:
                VStack(spacing: 0) {
                    wings(showsCover: true)
                    peekLine(track)
                        .transition(.opacity)
                }
            case .expanded:
                VStack(spacing: 0) {
                    wings(showsCover: false)
                    player(track)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
        }
    }

    // MARK: Beside the notch

    /// Cover in the left wing, equaliser in the right one, the notch in between.
    private func wings(showsCover: Bool) -> some View {
        let wing = max(0, (size.width - notch.width) / 2 - ear)
        let inset = max(0, (notch.height - IslandMetrics.smallCover) / 2)
        return HStack(spacing: 0) {
            ZStack {
                if showsCover {
                    IslandCover(artwork: artwork, size: IslandMetrics.smallCover,
                                corner: IslandMetrics.smallCoverCorner)
                        .matchedGeometryEffect(id: "cover", in: namespace)
                }
            }
            .padding(.leading, inset)
            .frame(width: wing, alignment: .leading)
            Spacer(minLength: 0)
            IslandEqualizer(isPlaying: isPlaying, tint: tint)
                .padding(.trailing, inset)
                .frame(width: wing, alignment: .trailing)
        }
        .padding(.horizontal, ear)
        .frame(width: size.width, height: notch.height)
    }

    /// «Título — Artista» on one line, under the notch.
    private func peekLine(_ track: NowPlayingTrack) -> some View {
        Text(Self.peekText(track))
            .font(.system(size: 12))
            .lineLimit(1)
            .truncationMode(.tail)
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

    private func player(_ track: NowPlayingTrack) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button(action: actions.openApp) {
                    IslandCover(artwork: artwork, size: IslandMetrics.largeCover,
                                corner: IslandMetrics.largeCoverCorner)
                        .matchedGeometryEffect(id: "cover", in: namespace)
                }
                .buttonStyle(IslandPressStyle())
                .accessibilityLabel(appName.map { "Abrir \($0)" } ?? "Abrir o leitor")

                titles(track)
                Spacer(minLength: 4)
                controls(track)
            }
            if let duration = track.duration {
                IslandProgressRow(track: track, duration: duration, tint: tint,
                                  ticking: track.isPlaying, seek: { actions.send(.seek($0)) })
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ear + IslandMetrics.expandedPadding)
        .padding(.bottom, 8)
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
    }
}
