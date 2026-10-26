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

    /// `islandFrame(size:)` for what the island shows.
    func islandFrame(for presentation: IslandPresentation) -> CGRect {
        islandFrame(size: IslandMetrics.size(for: presentation, notch: notchRect.size))
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
    static let expandedExtraHeight: CGFloat = 112

    /// The cover beside the notch (compact, peek) and in the open player.
    static let smallCover: CGFloat = 22
    static let smallCoverCorner: CGFloat = 6
    static let largeCover: CGFloat = 72
    static let largeCoverCorner: CGFloat = 14
    /// Space between the open player's content and the island's sides, past the ears.
    static let expandedPadding: CGFloat = 14

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
    /// Room for every presentation plus the springs' overshoot, centred on the notch
    /// and glued to the top of the screen. Not held inside the screen: on a real notch
    /// it never reaches an edge, and holding it would take the island off the notch.
    var canvas: CGRect {
        let slack = IslandMotion.overshootSlack(notch: notchRect.size)
        let sizes = IslandPresentation.allCases.map { IslandMetrics.size(for: $0, notch: notchRect.size) }
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
