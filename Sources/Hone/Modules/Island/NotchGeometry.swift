import AppKit
import CoreGraphics

/// Where the physical notch sits on one screen, and where the island goes around it.
/// Everything is in global AppKit coordinates (origin bottom-left of the main screen).
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let notchRect: CGRect

    /// `nil` when the screen has no notch: no safe-area inset at the top, an
    /// auxiliary area missing, or no gap left between the two. The auxiliary
    /// areas are the strips of menu bar to each side of the notch, already in
    /// global coordinates, so the notch is the gap between them.
    init?(screenFrame: CGRect, safeAreaTop: CGFloat, leftArea: CGRect?, rightArea: CGRect?) {
        guard safeAreaTop > 0, let leftArea, let rightArea else { return nil }
        let width = rightArea.minX - leftArea.maxX
        guard width > 0 else { return nil }
        self.screenFrame = screenFrame
        notchRect = CGRect(x: leftArea.maxX, y: screenFrame.maxY - safeAreaTop,
                           width: width, height: safeAreaTop)
    }

    /// The island's frame for a given size: centred on the notch, glued to the top
    /// of the screen, and kept inside it horizontally.
    func islandFrame(size: CGSize) -> CGRect {
        let centred = notchRect.midX - size.width / 2
        let x = max(screenFrame.minX, min(centred, screenFrame.maxX - size.width))
        return CGRect(x: x, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }

    /// `islandFrame(size:)` for a presentation of the music alone.
    func islandFrame(for presentation: IslandPresentation) -> CGRect {
        islandFrame(size: IslandMetrics.size(for: presentation, notch: notchRect.size))
    }

    /// `islandFrame(size:)` for what the island shows.
    func islandFrame(for layout: IslandLayout) -> CGRect {
        islandFrame(size: IslandMetrics.size(for: layout, notch: notchRect.size))
    }
}

/// Every island size in one place, so they are easy to tune.
enum IslandMetrics {
    /// The hover zone sits this far inside the notch on each side, so the island's
    /// black never shows beside the physical notch.
    static let hiddenInset: CGFloat = 6
    /// Compact wings are as wide as the notch is tall, plus this.
    static let wingExtra: CGFloat = 6
    static let peekMinWidth: CGFloat = 300
    static let peekExtraHeight: CGFloat = 30
    static let expandedExtraWidth: CGFloat = 240
    static let expandedMinWidth: CGFloat = 440

    /// The cover beside the notch (compact, peek) and in the open player.
    static let smallCover: CGFloat = 22
    static let smallCoverCorner: CGFloat = 6
    static let largeCover: CGFloat = 72
    static let largeCoverCorner: CGFloat = 14

    /// The cover's side in `presentation`: the large one only in the open player.
    static func coverSize(for presentation: IslandPresentation) -> CGFloat {
        presentation == .expanded ? largeCover : smallCover
    }

    /// The cover's side in `layout`: the large one only on the open music page. On
    /// the Claude page it is the small one in the left wing, and where no cover is
    /// drawn (Claude's wings, hidden) it stays small too, so it always grows from
    /// the wing.
    static func coverSize(for layout: IslandLayout) -> CGFloat {
        layout.presentation == .expanded && layout.page == .music ? largeCover : smallCover
    }

    // MARK: The open player
    //
    // Below the notch row it stacks, top to bottom: `expandedTopGap`, the cover
    // row (the large cover, with the titles and the controls centred on it),
    // `expandedRowSpacing`, the progress row and `expandedBottomPadding`. The
    // body is the island minus its ears.

    /// From the body's left, right and bottom edges to the visible content: the
    /// cover's and the left time label's left edge, the ⏭ glyph's and the right
    /// time label's right edge, the time labels' digits at the bottom.
    static let expandedInset: CGFloat = 20
    /// Between the notch row and the cover row.
    static let expandedTopGap: CGFloat = 8
    /// Between the cover row and the progress row.
    static let expandedRowSpacing: CGFloat = 10
    /// The progress row: tall enough to grab the bar with the pointer.
    static let progressRowHeight: CGFloat = 14
    /// The empty band under the time labels' digits inside that row. The bottom
    /// padding takes it back, so the digits sit at the inset and not the row.
    static let progressRowDigitGap: CGFloat = 3
    static var expandedBottomPadding: CGFloat { expandedInset - progressRowDigitGap }
    /// What the open player adds below the notch row.
    static var expandedExtraHeight: CGFloat {
        expandedTopGap + largeCover + expandedRowSpacing + progressRowHeight + expandedBottomPadding
    }

    /// The time labels' font size, and the room they keep (a hair over "10:00" at
    /// that size), so the bar does not jump when a track passes ten minutes.
    static let timeLabelFontSize: CGFloat = 10.5
    static let timeLabelMinWidth: CGFloat = 32
    /// The side of a control's round hit area.
    static let controlHitSize: CGFloat = 34
    /// The empty margin between the ⏭ glyph and its hit area's edge. The controls
    /// reach this far past the inset, so the glyph, not the hit area, sits on it.
    static let controlGlyphInset: CGFloat = 6.5

    /// The concave ears where the island meets the top of the screen. Compact
    /// ears fit in `wingExtra`, so the wings stay as wide as the notch is tall.
    static func earRadius(for presentation: IslandPresentation) -> CGFloat {
        presentation == .expanded ? 14 : wingExtra
    }

    static func bottomRadius(for presentation: IslandPresentation) -> CGFloat {
        switch presentation {
        case .hidden: return 8
        case .compact: return 10
        case .peek: return 16
        case .expanded: return 26
        }
    }

    // MARK: The Claude page
    //
    // Below the notch row it stacks, top to bottom: `claudeTopGap`, the session rows
    // (at most `claudeMaxRows`; the list scrolls past that), the strip «Os teus
    // agentes» when the user has agents of their own, and `claudeBottomPadding`. It
    // is as wide as the open player: switching pages only moves the height.

    static let claudeTopGap: CGFloat = 8
    static let claudeRowHeight: CGFloat = 34
    static let claudeMaxRows = 4
    /// The strip «Os teus agentes»: a gap over it, its caption, then two rows of
    /// chips, each with `agentChipSpacing` above it.
    static let agentsStripGap: CGFloat = 10
    static let agentsCaptionHeight: CGFloat = 14
    static let agentChipHeight: CGFloat = 20
    static let agentChipSpacing: CGFloat = 4
    static let agentChipRows = 2
    static var agentsStripHeight: CGFloat {
        agentsStripGap + agentsCaptionHeight + CGFloat(agentChipRows) * (agentChipSpacing + agentChipHeight)
    }
    static let claudeBottomPadding: CGFloat = 12

    /// What the Claude page adds below the notch row.
    static func claudeExtraHeight(rows: Int, hasAgentsStrip: Bool) -> CGFloat {
        claudeTopGap + CGFloat(min(max(rows, 0), claudeMaxRows)) * claudeRowHeight
            + (hasAgentsStrip ? agentsStripHeight : 0) + claudeBottomPadding
    }

    /// The island's size for what it shows: the presentation's, but the Claude page
    /// is as tall as its rows and strip.
    static func size(for layout: IslandLayout, notch: CGSize) -> CGSize {
        let size = size(for: layout.presentation, notch: notch)
        guard layout.presentation == .expanded, layout.page == .claude else { return size }
        return CGSize(width: size.width,
                      height: notch.height + claudeExtraHeight(rows: layout.claudeRows,
                                                               hasAgentsStrip: layout.hasAgentsStrip))
    }

    /// Every size the island can take: each presentation's, and the Claude page's
    /// smallest and largest. The canvas and the springs' room are made from them.
    static func allSizes(notch: CGSize) -> [CGSize] {
        let width = size(for: .expanded, notch: notch).width
        let claude = [(1, false), (claudeMaxRows, true)].map { rows, strip in
            CGSize(width: width, height: notch.height + claudeExtraHeight(rows: rows, hasAgentsStrip: strip))
        }
        return IslandPresentation.allCases.map { size(for: $0, notch: notch) } + claude
    }

    static func size(for presentation: IslandPresentation, notch: CGSize) -> CGSize {
        let compactWidth = notch.width + 2 * (notch.height + wingExtra)
        switch presentation {
        case .hidden:
            return CGSize(width: max(0, notch.width - 2 * hiddenInset), height: notch.height)
        case .compact:
            return CGSize(width: compactWidth, height: notch.height)
        case .peek:
            return CGSize(width: max(compactWidth, peekMinWidth), height: notch.height + peekExtraHeight)
        case .expanded:
            return CGSize(width: max(notch.width + expandedExtraWidth, expandedMinWidth),
                          height: notch.height + expandedExtraHeight)
        }
    }
}

// MARK: - The panel's canvas and window

/// The panel draws the island in a SwiftUI view of one fixed size, the canvas, and
/// only moves that view inside a window that is as small as the shape: SwiftUI never
/// sees its container change, so the island, drawn at the top centre of the canvas,
/// grows and shrinks from the notch whatever the window does around it.
extension NotchGeometry {
    /// Room for every size the island takes (the largest is the Claude page with
    /// every row and the agents' strip) plus the springs' overshoot, centred on the
    /// notch and glued to the top of the screen. Not held inside the screen: on a real
    /// notch it never reaches an edge, and holding it would take the island off the notch.
    var canvas: CGRect {
        let slack = IslandMotion.overshootSlack(notch: notchRect.size)
        let sizes = IslandMetrics.allSizes(notch: notchRect.size)
        let width = (sizes.map(\.width).max() ?? 0) + 2 * slack.width
        let height = (sizes.map(\.height).max() ?? 0) + slack.height
        return CGRect(x: notchRect.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }

    /// The window while the island moves from `current` (the window now) to
    /// `target`: both, plus the overshoot past the target, cut to the screen. Calling
    /// it again with its own answer changes nothing, so quick changes never pile up.
    func windowFrame(current: CGRect, target: CGRect) -> CGRect {
        let slack = IslandMotion.overshootSlack(notch: notchRect.size)
        let room = CGRect(x: target.minX - slack.width, y: target.minY - slack.height,
                          width: target.width + 2 * slack.width, height: target.height + slack.height)
        let frame = current.union(room).intersection(screenFrame)
        return frame.isNull || frame.isEmpty ? target : frame
    }

    /// Where the canvas-sized view goes inside a window at `window` (both in screen
    /// coordinates), so the canvas stays put on the screen.
    static func hostOrigin(canvas: CGRect, window: CGRect) -> CGPoint {
        CGPoint(x: canvas.minX - window.minX, y: canvas.minY - window.minY)
    }
}

// MARK: - The real screen (AppKit, not pure)

extension NotchGeometry {
    /// The notch of the built-in screen, or `nil` when there is none to draw on:
    /// another Mac, the lid closed or the built-in screen switched off (it then
    /// leaves `NSScreen.screens`), or a display mode that hides the notch.
    @MainActor
    static func current() -> NotchGeometry? {
        for screen in NSScreen.screens where screen.isBuiltIn {
            if let geometry = NotchGeometry(screen: screen) { return geometry }
        }
        return nil
    }

    @MainActor
    init?(screen: NSScreen) {
        self.init(screenFrame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                  leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
    }
}

private extension NSScreen {
    var isBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
}
