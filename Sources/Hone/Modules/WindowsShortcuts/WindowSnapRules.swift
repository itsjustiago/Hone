import Foundation
import CoreGraphics

/// The geometry and the decisions behind window snapping, free of AppKit and of the
/// Accessibility API so they can be tested without a screen: which frame each layout
/// is, what state a window is in, and what a key or a green-button click should do.
///
/// Everything here is in Accessibility coordinates — origin at the top-left of the
/// primary display, y growing downwards — because that is what a window's position
/// and a `CGEvent`'s location are in. Only `screens(appKit:)` ever sees AppKit's
/// bottom-left, y-up space.
enum WindowSnap {
    /// A display, both whole and without the menu bar and the Dock. Windows are
    /// placed in `visibleFrame`; `frame` is for working out which display a window
    /// is on and which one sits next to it.
    struct Screen: Equatable {
        var frame: CGRect
        var visibleFrame: CGRect
    }

    /// Where a window can be pinned on a display.
    enum Layout: Equatable {
        case leftHalf, rightHalf, maximized
    }

    enum Key: Equatable {
        case left, right, up, down
    }

    enum Side: Equatable {
        case left, right
    }

    /// What is remembered about a window the user snapped (or maximized).
    struct Record: Equatable {
        /// The free-floating frame from before the first snap, to put back later.
        /// `nil` when the window was already snapped some other way, so there is
        /// nothing of the user's to bring back.
        var restoreFrame: CGRect?
        /// The layout last applied, and the frame the app really ended up with
        /// right after: Terminal rounds to its character grid and plenty of windows
        /// refuse to be narrower than some minimum, so the frame asked for is not
        /// the frame to recognise the window by.
        var layout: Layout
        var appliedFrame: CGRect
    }

    enum Action: Equatable {
        /// Move the window to `frame` and remember it as `layout`. `saveRestore`:
        /// the window was free until now, so its current frame is worth keeping.
        case apply(Layout, CGRect, saveRestore: Bool)
        /// Put the window back at this frame and forget the record.
        case restore(CGRect)
        case minimize
        /// A window that can be moved, but this key has nothing to do with it now.
        /// The key is still swallowed, so ⌥← without a neighbour doesn't also jump
        /// a word in whatever text the app has focused.
        case none
    }

    // MARK: - Screens

    /// An AppKit rectangle (y up from the bottom of the primary display) as an AX one
    /// (y down from the top of it).
    static func axRect(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The displays as `NSScreen` reports them, converted. `NSScreen.screens` lists
    /// the primary display first, and its height is what both spaces pivot on.
    static func screens(appKit: [(frame: CGRect, visibleFrame: CGRect)]) -> [Screen] {
        guard let primary = appKit.first else { return [] }
        let top = primary.frame.maxY
        return appKit.map {
            Screen(frame: axRect($0.frame, primaryMaxY: top),
                   visibleFrame: axRect($0.visibleFrame, primaryMaxY: top))
        }
    }

    // MARK: - Layouts

    /// The frame of a layout. The left half gets `floor(width / 2)` and the right one
    /// the rest, so an odd width leaves neither a gap nor an overlap.
    static func frame(of layout: Layout, on screen: Screen) -> CGRect {
        let visible = screen.visibleFrame
        let leftWidth = (visible.width / 2).rounded(.down)
        switch layout {
        case .maximized:
            return visible
        case .leftHalf:
            return CGRect(x: visible.minX, y: visible.minY, width: leftWidth, height: visible.height)
        case .rightHalf:
            return CGRect(x: visible.minX + leftWidth, y: visible.minY,
                          width: visible.width - leftWidth, height: visible.height)
        }
    }

    /// Where a window goes when it is put back without a frame of its own to return
    /// to: two thirds of the usable area each way, in the middle.
    static func fallbackFrame(on screen: Screen) -> CGRect {
        let visible = screen.visibleFrame
        let size = CGSize(width: (visible.width * 2 / 3).rounded(.down),
                          height: (visible.height * 2 / 3).rounded(.down))
        return centered(size, in: visible)
    }

    private static func centered(_ size: CGSize, in rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX + (rect.width - size.width) / 2).rounded(.down),
               y: (rect.minY + (rect.height - size.height) / 2).rounded(.down),
               width: size.width, height: size.height)
    }

    /// The frame to restore on `screen`. A saved frame that is mostly on this
    /// display is used as it was. Otherwise — another display, or one that has been
    /// unplugged since, which leaves the frame off every screen — the window keeps
    /// its size (capped to what fits) and lands in the middle instead of half off
    /// the edge or on a tiny screen at a size it can't hold.
    static func restoreFrame(saved: CGRect?, on screen: Screen) -> CGRect {
        guard let saved, saved.width > 0, saved.height > 0 else { return fallbackFrame(on: screen) }
        if area(saved.intersection(screen.frame)) * 2 >= area(saved) { return saved }
        let visible = screen.visibleFrame
        return centered(CGSize(width: min(saved.width, visible.width),
                               height: min(saved.height, visible.height)), in: visible)
    }

    // MARK: - Finding things

    /// The display a window belongs to: the one it overlaps the most, or when it is
    /// off every display the nearest one. `nil` only when there are no screens.
    static func screenIndex(of frame: CGRect, in screens: [Screen]) -> Int? {
        guard !screens.isEmpty else { return nil }
        var best = 0
        var bestArea: CGFloat = 0
        for (index, screen) in screens.enumerated() {
            let overlap = area(frame.intersection(screen.frame))
            if overlap > bestArea {
                best = index
                bestArea = overlap
            }
        }
        if bestArea > 0 { return best }

        var nearest = 0
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for (index, screen) in screens.enumerated() {
            let distance = distance(frame, screen.frame)
            if distance < nearestDistance {
                nearest = index
                nearestDistance = distance
            }
        }
        return nearest
    }

    /// The display next to `index` on that side: wholly on that side (a pixel of slack
    /// for rounding) and facing it at least a little vertically, so a screen above
    /// or below is never a neighbour. The closest one wins; between equals, the one
    /// facing it the most.
    static func neighbor(of index: Int, toThe side: Side, in screens: [Screen]) -> Int? {
        guard screens.indices.contains(index) else { return nil }
        let current = screens[index].frame
        var best: (index: Int, gap: CGFloat, overlap: CGFloat)?
        for (i, screen) in screens.enumerated() where i != index {
            let other = screen.frame
            let gap: CGFloat
            switch side {
            case .left:
                guard other.maxX <= current.minX + 1 else { continue }
                gap = current.minX - other.maxX
            case .right:
                guard other.minX >= current.maxX - 1 else { continue }
                gap = other.minX - current.maxX
            }
            let overlap = min(other.maxY, current.maxY) - max(other.minY, current.minY)
            guard overlap > 0 else { continue }
            if let b = best, gap > b.gap || (gap == b.gap && overlap <= b.overlap) { continue }
            best = (i, gap, overlap)
        }
        return best?.index
    }

    /// How far a recorded frame can be off the frame read back, per edge.
    static let readbackTolerance: CGFloat = 2
    /// How far a window can be off a layout's ideal frame, per edge, and still count
    /// as being in it (a few points of rounding or a resize the app half took).
    static let layoutTolerance: CGFloat = 6

    /// The layout a window is in on `screen`, or `nil` when it is free. The record
    /// goes first — a window whose frame is where the app left it after our last
    /// move is in that layout, whatever size the app really accepted — and then the
    /// frame is compared with each ideal one, the maximized one first (it contains
    /// the halves' edges).
    static func layout(of frame: CGRect, record: Record?, on screen: Screen) -> Layout? {
        if let record, matches(frame, record.appliedFrame, tolerance: readbackTolerance) {
            return record.layout
        }
        for layout in [Layout.maximized, .leftHalf, .rightHalf]
        where matches(frame, Self.frame(of: layout, on: screen), tolerance: layoutTolerance) {
            return layout
        }
        return nil
    }

    // MARK: - Decisions

    /// What an arrow should do to a window that is at `windowFrame`.
    ///
    /// ←/→ pin it to that side; pressed again they hand it to the next display
    /// (landing on its opposite half, as on Windows), and the opposite key undoes a
    /// half. ↑ maximizes. ↓ brings a snapped window back and minimizes a free one.
    static func action(for key: Key, windowFrame: CGRect, record: Record?, screens: [Screen]) -> Action {
        guard let index = screenIndex(of: windowFrame, in: screens) else { return .none }
        let screen = screens[index]
        let state = layout(of: windowFrame, record: record, on: screen)

        switch key {
        case .left, .right:
            let side: Side = key == .left ? .left : .right
            let own: Layout = side == .left ? .leftHalf : .rightHalf
            let opposite: Layout = side == .left ? .rightHalf : .leftHalf

            guard let state else {
                return .apply(own, frame(of: own, on: screen), saveRestore: true)
            }
            if state == own {
                guard let next = neighbor(of: index, toThe: side, in: screens) else { return .none }
                return .apply(opposite, frame(of: opposite, on: screens[next]), saveRestore: false)
            }
            if state == opposite, let saved = record?.restoreFrame {
                return .restore(restoreFrame(saved: saved, on: screen))
            }
            return .apply(own, frame(of: own, on: screen), saveRestore: false)

        case .up:
            if state == .maximized { return .none }
            return .apply(.maximized, frame(of: .maximized, on: screen), saveRestore: state == nil)

        case .down:
            guard state != nil else { return .minimize }
            return .restore(restoreFrame(saved: record?.restoreFrame, on: screen))
        }
    }

    /// What a click on the green button should do: maximize, or — on a window that
    /// already is — put it back. Never minimizes, unlike ↓.
    static func greenButtonAction(windowFrame: CGRect, record: Record?, screens: [Screen]) -> Action {
        guard let index = screenIndex(of: windowFrame, in: screens) else { return .none }
        let screen = screens[index]
        let state = layout(of: windowFrame, record: record, on: screen)
        if state == .maximized {
            return .restore(restoreFrame(saved: record?.restoreFrame, on: screen))
        }
        return .apply(.maximized, frame(of: .maximized, on: screen), saveRestore: state == nil)
    }

    // MARK: - Traffic lights

    /// Whether a point is where a window's close/minimize/zoom buttons live: the top
    /// left corner of its frame. Checked before any Accessibility query so a click
    /// anywhere else costs nothing.
    static func isInTrafficLightZone(_ point: CGPoint, windowBounds: CGRect) -> Bool {
        let dx = point.x - windowBounds.minX
        let dy = point.y - windowBounds.minY
        return dx >= 0 && dx <= 100 && dy >= 0 && dy <= 60
    }

    // MARK: - Helpers

    private static func matches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    /// `CGRect.null` (no overlap) has a zero size, so this is 0 for it.
    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    /// The gap between two rectangles; 0 when they touch or overlap.
    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, a.minX - b.maxX, b.minX - a.maxX)
        let dy = max(0, a.minY - b.maxY, b.minY - a.maxY)
        return hypot(dx, dy)
    }
}
