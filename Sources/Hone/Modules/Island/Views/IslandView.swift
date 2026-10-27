import SwiftUI
import HoneDesign

/// What the island can ask of the controller. No-ops by default (previews).
struct IslandActions {
    var hover: @MainActor (Bool) -> Void = { _ in }
    var click: @MainActor () -> Void = {}
    var send: @MainActor (NowPlayingCommand) -> Void = { _ in }
    var openApp: @MainActor () -> Void = {}
    /// Opens the session in the Claude app and folds the island.
    var openClaudeSession: @MainActor (ClaudeSession) -> Void = { _ in }
    /// The page selector: shows that page of the open island.
    var selectPage: @MainActor (IslandPage) -> Void = { _ in }
}

/// The island in one layout, from plain values so the preview renderer can draw
/// it offscreen. It draws itself at the top centre of whatever space it is given:
/// the panel gives it a fixed canvas centred on the notch.
struct IslandView: View {
    let layout: IslandLayout
    let notch: CGSize
    let track: NowPlayingTrack?
    let artwork: IslandArtwork?
    let appName: String?
    /// The sessions and agents for the Claude wings and page.
    var claude: ClaudeSnapshot?
    var actions = IslandActions()
    /// The shape as it is this frame: the panel moves it on its own spring. `nil`
    /// (the previews) draws `presentation`'s at rest.
    var outline: IslandOutline?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: IslandPresentation { layout.presentation }
    /// The content's layout: always `layout`'s, so SwiftUI moves it as it always
    /// has, while the shape around it follows `outline`.
    private var size: CGSize { IslandMetrics.size(for: layout, notch: notch) }
    private var ear: CGFloat { IslandMetrics.earRadius(for: presentation) }
    private var drawn: IslandOutline { outline ?? IslandOutline(layout, notch: notch) }
    private var shape: NotchShape {
        NotchShape(earRadius: drawn.earRadius, bottomRadius: drawn.bottomRadius)
    }
    private var tint: Color { artwork?.tint ?? IslandPalette.fallbackTint }
    private var isPlaying: Bool { track?.isPlaying ?? false }
    /// The open player has a progress row: a stream with no length has none.
    private var hasProgress: Bool { track?.duration != nil }

    /// The fill is sized by the outline alone; the content, laid out at its own size,
    /// sits over it, and the cover over both. In a stack with the content, the fill
    /// would take the larger of the two while the island grows, and be drawn again
    /// on SwiftUI's clock.
    var body: some View {
        shape.fill(IslandPalette.island)
            .frame(width: drawn.width, height: drawn.height)
            .overlay(alignment: .top) { content }
            .overlay(alignment: .topLeading) { cover }
            .overlay(alignment: .topLeading) { notchRow }
            .clipShape(shape)
            .contentShape(shape)
            .onHover { actions.hover($0) }
            .onTapGesture { actions.click() }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The wings stay put from compact to expanded (the equaliser goes: the pause
    /// button says the state); what sits under the notch comes in and out on its
    /// own. The cover is not in here: see `cover`.
    ///
    /// The music's wings need a track; Claude's need none. Claude's glyph and count,
    /// like the cover, are drawn from the outline (`notchRow`).
    @ViewBuilder
    private var content: some View {
        if let track, layout.wings == .music, presentation != .hidden {
            VStack(spacing: 0) {
                wings(showsItems: presentation != .expanded)
                switch presentation {
                case .peek:
                    peekContent(track)
                        .transition(contentTransition)
                case .expanded:
                    pageContent(track)
                        .transition(contentTransition)
                case .hidden, .compact:
                    EmptyView()
                }
            }
            .transition(contentTransition)
        } else if layout.wings == .claude, presentation != .hidden {
            VStack(spacing: 0) {
                Color.clear
                    .frame(width: size.width, height: notch.height)
                switch presentation {
                case .peek:
                    if let notice = layout.notice {
                        noticeLine(notice)
                            .transition(contentTransition)
                    }
                case .expanded:
                    claudePage
                        .transition(contentTransition)
                case .hidden, .compact:
                    EmptyView()
                }
            }
            .transition(contentTransition)
        }
    }

    /// Under the music's wings: the new track's title, or a Claude notice.
    @ViewBuilder
    private func peekContent(_ track: NowPlayingTrack) -> some View {
        if let notice = layout.notice {
            noticeLine(notice)
        } else {
            peekLine(track)
        }
    }

    /// The open page under the music's wings: the player, or the Claude page
    /// beside the small cover.
    /// Switching pages swaps them the way the content comes in and goes out.
    @ViewBuilder
    private func pageContent(_ track: NowPlayingTrack) -> some View {
        if layout.page == .claude {
            claudePage
                .transition(contentTransition)
        } else {
            player(track)
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

    // MARK: The cover

    /// One cover in every presentation, over the content: beside the notch it is the
    /// left wing's, in the open player the large one that opens the app. Its frame
    /// comes from the outline, so it moves on the panel's spring with the shape,
    /// frame by frame, and grows from the wing into the player as one picture. (Two
    /// covers matched by SwiftUI moved on another clock, and jumped between them.)
    @ViewBuilder
    private var cover: some View {
        if track != nil, layout.showsCover {
            let frame = drawn.coverFrame(notch: notch, hasProgress: hasProgress)
            let inset = drawn.coverInset(notch: notch)
            let opensApp = presentation == .expanded && layout.page == .music
            let _ = IslandCover.probe?(frame)
            Button(action: actions.openApp) {
                IslandCover(artwork: artwork, size: frame.width - 2 * inset, corner: drawn.coverCorner)
                    .overlay(alignment: .topTrailing) { IslandCoverBadge(activity: layout.coverBadge) }
                    .padding(inset)
            }
            .buttonStyle(IslandPressStyle())
            .allowsHitTesting(opensApp)
            .accessibilityHidden(!opensApp)
            .accessibilityLabel(appName.map { "Abrir \($0)" } ?? "Abrir o leitor")
            .offset(x: frame.minX, y: frame.minY)
            // The island's size, so it comes in and goes out with the wings.
            .frame(width: drawn.width, height: drawn.height, alignment: .topLeading)
            .transition(contentTransition)
        }
    }

    // MARK: Beside the notch

    /// What sits in the notch row beside the cover, drawn from the outline like the
    /// cover so it travels with the shape's edge: Claude's glyph and count when
    /// Claude has the wings, and the page selector in the open island's right wing.
    @ViewBuilder
    private var notchRow: some View {
        if presentation != .hidden, layout.wings == .claude {
            claudeWings
                .transition(contentTransition)
        }
        if presentation == .expanded, layout.showsPageSelector {
            let right = drawn.trailingWingSlot(notch: notch).maxX
            IslandPageSelector(page: layout.page, activity: layout.claudeActivity, height: notch.height,
                               select: { actions.selectPage($0) })
                .offset(x: right - IslandPageSelector.width)
                .frame(width: drawn.width, height: drawn.height, alignment: .topLeading)
                .transition(contentTransition)
        }
    }

    /// Claude's glyph where the small cover sits, breathing while a session works,
    /// and the number of active sessions where the equaliser sits, orange while
    /// one waits. With none active (the open page, all idle) the right wing is empty.
    private var claudeWings: some View {
        let glyph = drawn.leadingWingSlot(notch: notch)
        let count = drawn.trailingWingSlot(notch: notch)
        let activity = layout.claudeActivity
        return ZStack(alignment: .topLeading) {
            ClaudeGlyph(color: IslandPalette.claude(activity), size: Self.wingGlyph, pulses: activity == .working)
                .frame(width: glyph.width, height: glyph.height)
                .offset(x: glyph.minX, y: glyph.minY)
            if layout.activeSessions > 0 {
                Text("\(layout.activeSessions)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(activity == .waiting ? IslandPalette.claudeWaiting : IslandPalette.primaryText)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: count.width, height: count.height)
                    .offset(x: count.minX, y: count.minY)
            }
        }
        .frame(width: drawn.width, height: drawn.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.claudeWingsLabel(activity: activity, active: layout.activeSessions))
    }

    /// Claude's glyph in the wing: a little smaller than the cover it stands for.
    static let wingGlyph: CGFloat = 15

    static func claudeWingsLabel(activity: IslandClaudeActivity, active: Int) -> String {
        let sessions = active == 1 ? "1 sessão ativa" : "\(active) sessões ativas"
        switch activity {
        case .waiting: return "Claude: \(sessions), alguma à tua espera"
        case .working: return "Claude: \(sessions)"
        case .none: return "Claude: nenhuma sessão ativa"
        }
    }

    /// Room for the cover in the left wing, equaliser in the right one, the notch in
    /// between. Both sit in a box the size of the small cover, the same distance
    /// from the island's sides.
    private func wings(showsItems: Bool) -> some View {
        let wing = max(0, (size.width - notch.width) / 2 - ear)
        let inset = max(0, (notch.height - IslandMetrics.smallCover) / 2)
        return HStack(spacing: 0) {
            Color.clear
                .frame(width: wing)
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

    /// A Claude notice under the notch, where a new track's title goes and in its
    /// type: Claude's glyph, then the line. Only the name gives way when it is long.
    private func noticeLine(_ notice: IslandNotice) -> some View {
        let parts = notice.parts
        let emphasis = Font.system(size: 12, weight: .semibold)
        return HStack(spacing: 6) {
            ClaudeGlyph(color: notice.kind == .waiting ? IslandPalette.claudeWaiting : IslandPalette.claude,
                        size: 12)
            HStack(spacing: 0) {
                if !parts.lead.isEmpty {
                    Text(parts.lead)
                        .font(emphasis)
                        .foregroundStyle(IslandPalette.primaryText)
                        .fixedSize()
                }
                Text(parts.subject)
                    .font(emphasis)
                    .foregroundStyle(IslandPalette.primaryText)
                    .truncationMode(.tail)
                Text(parts.trail)
                    .font(.system(size: 12))
                    .foregroundStyle(IslandPalette.secondaryText)
                    .fixedSize()
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notice.text)
        .padding(.horizontal, ear + 16)
        .frame(width: size.width, height: IslandMetrics.peekExtraHeight - 4, alignment: .center)
    }

    // MARK: The Claude page

    /// The session rows and the agents' strip, under the notch row.
    private var claudePage: some View {
        IslandClaudePage(snapshot: claude, layout: layout, size: size, notch: notch, ear: ear,
                         open: { actions.openClaudeSession($0) })
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
                // The cover's place: `cover` draws it here at rest.
                Color.clear
                    .frame(width: IslandMetrics.largeCover, height: IslandMetrics.largeCover)

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
