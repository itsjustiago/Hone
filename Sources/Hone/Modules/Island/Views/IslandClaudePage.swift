import AppKit
import SwiftUI
import HoneDesign

/// The open island's Claude page, under the notch row: the sessions (scrolling past
/// `IslandMetrics.claudeMaxRows`) and, when the user has agents of their own, the
/// strip «Os teus agentes». The island's size comes from the layout; this only fills it.
struct IslandClaudePage: View {
    let snapshot: ClaudeSnapshot?
    let layout: IslandLayout
    /// The island's size, and the notch's: the page is the room under the notch row.
    let size: CGSize
    let notch: CGSize
    let ear: CGFloat
    let open: (ClaudeSession) -> Void

    private var inset: CGFloat { ear + IslandMetrics.expandedInset }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The rows' hover reaches `rowPadding` past the inset; their dots sit on it.
            IslandSessionList(sessions: snapshot?.sessions ?? [], rows: layout.claudeRows, open: open)
                .padding(.horizontal, inset - IslandSessionRow.padding)
            if layout.hasAgentsStrip, let snapshot {
                IslandAgentsStrip(snapshot: snapshot, width: max(0, size.width - 2 * inset))
                    .padding(.top, IslandMetrics.agentsStripGap)
                    .padding(.horizontal, inset)
            }
        }
        .padding(.top, IslandMetrics.claudeTopGap)
        .frame(width: size.width, height: max(0, size.height - notch.height), alignment: .top)
    }
}

// MARK: - The sessions

/// `rows` rows tall. With more sessions than that it scrolls, and fades at the
/// bottom until the last one is in view, so it shows there is more.
private struct IslandSessionList: View {
    let sessions: [ClaudeSession]
    let rows: Int
    let open: (ClaudeSession) -> Void

    @Environment(\.islandOffscreen) private var offscreen
    @State private var atEnd = false

    private static let space = "IslandSessionList"
    private static let fade: CGFloat = 10

    var body: some View {
        let height = CGFloat(rows) * IslandMetrics.claudeRowHeight
        let scrolls = sessions.count > rows
        Group {
            if offscreen {
                // The renderer draws no scroll view: the top of the list, cut.
                list.frame(height: height, alignment: .top).clipped()
            } else {
                ScrollView(.vertical) {
                    list.background(endReader)
                }
                .scrollIndicators(.never)
                .scrollDisabled(!scrolls)
                .coordinateSpace(name: Self.space)
                .onPreferenceChange(IslandListEnd.self) { maxY in
                    atEnd = maxY <= height + 0.5
                }
            }
        }
        .frame(height: height)
        .mask(mask(fades: scrolls && !atEnd))
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(sessions) { session in
                IslandSessionRow(session: session) { open(session) }
            }
        }
    }

    /// Where the list's bottom is in the scroll view: at its height, the last row is in.
    private var endReader: some View {
        GeometryReader { geo in
            Color.clear.preference(key: IslandListEnd.self, value: geo.frame(in: .named(Self.space)).maxY)
        }
    }

    private func mask(fades: Bool) -> some View {
        VStack(spacing: 0) {
            Color.black
            ZStack {
                Color.black.opacity(fades ? 0 : 1)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
            }
            .frame(height: Self.fade)
        }
        .animation(VibeMotion.quick, value: fades)
    }
}

private struct IslandListEnd: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One session: its state's dot, its name, its project and how long ago it moved,
/// and the agents running in it. The whole row opens it in the Claude app.
private struct IslandSessionRow: View {
    let session: ClaudeSession
    let open: () -> Void

    /// Between the hover's edge and the dot (and the chips' end).
    static let padding: CGFloat = 8

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Circle()
                    .fill(IslandPalette.claude(session.state))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(IslandPalette.primaryText)
                    subtitle
                        .font(.system(size: 11))
                        .foregroundStyle(IslandPalette.secondaryText)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 8)
                IslandRowChips(agents: session.agents)
            }
            .padding(.horizontal, Self.padding)
            .frame(height: IslandMetrics.claudeRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? IslandPalette.faintFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandRowStyle())
        .onHover { hovering = $0 }
        .animation(VibeMotion.quick, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(IslandClaudeText.accessibilityLabel(session))
        .accessibilityAddTraits(.isButton)
    }

    /// Only the time ticks, once a minute, and only while the page is up. The
    /// minutes are counted from the session's own `since`, so each tick lands as a
    /// minute goes by and the timeline's date is exact (`.everyMinute` gives the
    /// clock's minute, up to 59 s behind).
    @ViewBuilder
    private var subtitle: some View {
        if session.state == .waiting {
            Text(IslandClaudeText.subtitle(session, now: Date()))
        } else {
            TimelineView(.periodic(from: session.since, by: 60)) { context in
                Text(IslandClaudeText.subtitle(session, now: context.date))
            }
        }
    }
}

/// A row darkens a little while pressed: it is too wide to shrink like a control.
private struct IslandRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(VibeMotion.quick, value: configuration.isPressed)
    }
}

/// The agents running in a session, by type: the two most numerous, then «+N».
private struct IslandRowChips: View {
    let agents: [ClaudeRunningAgent]

    var body: some View {
        let running = IslandAgentChips.running(agents)
        HStack(spacing: 4) {
            ForEach(running.shown) { tally in
                IslandChip(text: Text(tally.rowLabel), font: .system(size: 10, weight: .medium),
                           color: tally.isMine ? IslandPalette.primaryText : IslandPalette.secondaryText,
                           fill: tally.isMine ? IslandPalette.mineChipFill : IslandPalette.chipFill,
                           height: 16, padding: 6)
            }
            if running.hidden > 0 {
                IslandChip(text: Text("+\(running.hidden)"), font: .system(size: 10, weight: .medium),
                           color: IslandPalette.secondaryText, fill: IslandPalette.chipFill,
                           height: 16, padding: 6)
            }
        }
        .fixedSize()
    }
}

// MARK: - The strip «Os teus agentes»

/// The user's own agents as chips, those running lit and first. Hovering a lit one
/// says where it runs.
private struct IslandAgentsStrip: View {
    let snapshot: ClaudeSnapshot
    /// The chips' row width: the page's between its insets.
    let width: CGFloat

    @State private var hovered: String?

    private static let chipFont = Font.system(size: 11, weight: .medium).monospacedDigit()
    private static let measuringFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let chipPadding: CGFloat = 8

    var body: some View {
        let chips = IslandAgentChips.strip(snapshot.myAgents, count: snapshot.runningCount(of:))
        let shown = IslandAgentChips.fit(chips.map { Self.width(of: Self.label($0)) },
                                         plusWidth: { Self.width(of: "+\($0)") }, maxWidth: width,
                                         spacing: IslandMetrics.agentChipSpacing,
                                         rows: IslandMetrics.agentChipRows)
        VStack(alignment: .leading, spacing: IslandMetrics.agentChipSpacing) {
            caption(inUse: chips.filter { $0.count > 0 }.count, of: chips.count)
                .frame(width: width, height: IslandMetrics.agentsCaptionHeight)
            IslandChipFlow(spacing: IslandMetrics.agentChipSpacing, rowHeight: IslandMetrics.agentChipHeight,
                           maxRows: IslandMetrics.agentChipRows) {
                ForEach(chips.prefix(shown)) { chip in
                    stripChip(chip)
                        .onHover { inside in
                            if inside, chip.count > 0 {
                                hovered = chip.type
                            } else if hovered == chip.type {
                                hovered = nil
                            }
                        }
                }
                if shown < chips.count {
                    IslandChip(text: Text("+\(chips.count - shown)"), font: Self.chipFont,
                               color: IslandPalette.tertiaryText, fill: IslandPalette.faintFill,
                               height: IslandMetrics.agentChipHeight, padding: Self.chipPadding)
                }
            }
            .frame(width: width, alignment: .topLeading)
        }
    }

    /// «Os teus agentes … N de M em uso», or where the hovered agent runs.
    private func caption(inUse: Int, of total: Int) -> some View {
        ZStack(alignment: .leading) {
            if let hovered, let sessions = snapshot.agentUsage[hovered], !sessions.isEmpty {
                Text(IslandClaudeText.usage(of: hovered, in: sessions))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IslandPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                HStack(spacing: 8) {
                    Text("Os teus agentes")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IslandPalette.secondaryText)
                    Spacer(minLength: 0)
                    Text("\(inUse) de \(total) em uso")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(IslandPalette.tertiaryText)
                }
                .lineLimit(1)
                .transition(.opacity)
            }
        }
        .animation(VibeMotion.quick, value: hovered)
    }

    private func stripChip(_ chip: IslandAgentChips.Tally) -> some View {
        let lit = chip.count > 0
        let text = lit
            ? Text(chip.type).foregroundStyle(IslandPalette.primaryText)
                + Text(" \(chip.count)").foregroundStyle(IslandPalette.secondaryText)
            : Text(chip.type).foregroundStyle(IslandPalette.tertiaryText)
        return IslandChip(text: text, font: Self.chipFont, color: nil,
                          fill: lit ? IslandPalette.litChipFill : IslandPalette.faintFill,
                          height: IslandMetrics.agentChipHeight, padding: Self.chipPadding)
            .accessibilityLabel(lit ? "\(chip.type), \(chip.count) em uso" : chip.type)
    }

    /// The chip's text as one string, for measuring.
    private static func label(_ chip: IslandAgentChips.Tally) -> String {
        chip.count > 0 ? "\(chip.type) \(chip.count)" : chip.type
    }

    /// A chip's width with `text` in it: the text in the chip's font, rounded up
    /// with a point to spare so SwiftUI's own measure never wraps it differently.
    private static func width(of text: String) -> CGFloat {
        let size = (text as NSString).size(withAttributes: [.font: measuringFont])
        return ceil(size.width) + 1 + 2 * chipPadding
    }
}

/// A capsule with a short label: the agents on a session's row and in the strip.
private struct IslandChip: View {
    let text: Text
    let font: Font
    /// `nil`: the text brings its own colours.
    let color: Color?
    let fill: Color
    let height: CGFloat
    let padding: CGFloat

    var body: some View {
        Group {
            if let color {
                text.foregroundStyle(color)
            } else {
                text
            }
        }
        .font(font)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, padding)
        .frame(height: height)
        .background(Capsule().fill(fill))
    }
}

/// Chips left to right in rows `rowHeight` tall, `spacing` apart both ways, at most
/// `maxRows` rows: the strip cuts its chips to fit first, so none is left over (one
/// that is goes out of sight).
private struct IslandChipFlow: Layout {
    let spacing: CGFloat
    let rowHeight: CGFloat
    let maxRows: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let maxWidth = proposal.width ?? widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        let rows = min(maxRows, (IslandAgentChips.flowRows(widths, maxWidth: maxWidth, spacing: spacing).last ?? -1) + 1)
        return CGSize(width: maxWidth, height: rows > 0 ? CGFloat(rows) * rowHeight + CGFloat(rows - 1) * spacing : 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let rows = IslandAgentChips.flowRows(widths, maxWidth: bounds.width, spacing: spacing)
        var x = bounds.minX, row = 0
        for (index, subview) in subviews.enumerated() {
            if rows[index] != row {
                row = rows[index]
                x = bounds.minX
            }
            guard row < maxRows else {
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.maxY + 1_000), proposal: .zero)
                continue
            }
            let y = bounds.minY + CGFloat(row) * (rowHeight + spacing)
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: widths[index], height: rowHeight))
            x += widths[index] + spacing
        }
    }
}
