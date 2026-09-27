import CoreGraphics

// MARK: - Drag state

/// Which resize handle a press landed on.
enum SelectionHandle: Equatable, CaseIterable {
    case tl, tr, bl, br, t, b, l, r
}

/// What a press on the selection overlay is doing. Deciding this once at the
/// start of a drag — and keeping it in a reference-typed `DragSession` — avoids
/// the classic SwiftUI trap of writing `@State` and reading it back in the same
/// gesture event (which returns the stale value and drops the first frame).
enum SelectionDrag: Equatable {
    case none
    case newSelection
    case move
    case resize(SelectionHandle)
    case draw
    case text
    case ignore
}

/// Mutable, reference-typed scratch space for the in-flight drag. Held as
/// `@State` in the view; because it's a class, writes are visible immediately.
final class DragSession {
    var mode: SelectionDrag = .none
    var anchor: CGRect = .zero          // move/resize: the selection rect at drag start
    var previousSelection: CGRect?      // newSelection: what to restore if it was just a click

    func reset() {
        mode = .none
        anchor = .zero
        previousSelection = nil
    }
}

// MARK: - Pure geometry

/// Stateless geometry for the region selection: hit-testing, resizing, clamping.
/// Kept free of SwiftUI/AppKit so it can be unit-tested directly.
enum SelectionGeometry {
    /// The eight resize-handle positions for a rect (corners then edge midpoints).
    static func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
         CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
    }

    /// Which handle (if any) is within `tolerance` points of `p`. Corners win over
    /// edges so the diagonal handles stay reachable on small selections.
    static func handle(at p: CGPoint, of r: CGRect, tolerance: CGFloat) -> SelectionHandle? {
        func near(_ pt: CGPoint) -> Bool { abs(p.x - pt.x) <= tolerance && abs(p.y - pt.y) <= tolerance }
        if near(CGPoint(x: r.minX, y: r.minY)) { return .tl }
        if near(CGPoint(x: r.maxX, y: r.minY)) { return .tr }
        if near(CGPoint(x: r.minX, y: r.maxY)) { return .bl }
        if near(CGPoint(x: r.maxX, y: r.maxY)) { return .br }
        if near(CGPoint(x: r.midX, y: r.minY)) { return .t }
        if near(CGPoint(x: r.midX, y: r.maxY)) { return .b }
        if near(CGPoint(x: r.minX, y: r.midY)) { return .l }
        if near(CGPoint(x: r.maxX, y: r.midY)) { return .r }
        return nil
    }

    /// Decide what a press at `p` should start, given the current selection and tool.
    static func dragIntent(at p: CGPoint, selection: CGRect?, tool: AnnotationTool,
                           handleTolerance: CGFloat, moveInset: CGFloat) -> SelectionDrag {
        guard let r = selection, r.width > 0 || r.height > 0 else { return .newSelection }
        switch tool {
        case .select:
            if let h = handle(at: p, of: r, tolerance: handleTolerance) { return .resize(h) }
            if r.insetBy(dx: -moveInset, dy: -moveInset).contains(p) { return .move }
            return .newSelection
        case .text:
            return .text
        default:
            // Drawing tools only act inside the current selection.
            if r.insetBy(dx: -2, dy: -2).contains(p) { return .draw }
            return .ignore
        }
    }

    /// Resize `r` by dragging `handle` by `t`, keeping it within `bounds`.
    /// `standardized` handles the drag crossing the opposite edge (flip).
    static func resize(_ r: CGRect, handle: SelectionHandle, by t: CGSize, in bounds: CGSize) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .tl: minX += t.width; minY += t.height
        case .tr: maxX += t.width; minY += t.height
        case .bl: minX += t.width; maxY += t.height
        case .br: maxX += t.width; maxY += t.height
        case .t:  minY += t.height
        case .b:  maxY += t.height
        case .l:  minX += t.width
        case .r:  maxX += t.width
        }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).standardized
        return clampRect(rect, in: bounds)
    }

    static func normalized(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func clampPoint(_ p: CGPoint, in bounds: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    /// Where to centre the floating region toolbar (of `toolbarSize`) for a
    /// selection so the **whole toolbar stays within `bounds`** (with `margin` from
    /// every edge). Prefers sitting a `gap` below the selection, flips above when it
    /// wouldn't fit, and pins just inside the bottom edge as a last resort. If the
    /// toolbar is larger than the space on an axis, it's centred on that axis.
    static func toolbarCenter(selection r: CGRect, bounds: CGSize, toolbarSize size: CGSize,
                              margin: CGFloat = 16, gap: CGFloat = 14) -> CGPoint {
        let w = size.width, h = size.height

        let centerBelow = r.maxY + gap + h / 2
        let centerAbove = r.minY - gap - h / 2
        var y: CGFloat
        if centerBelow + h / 2 + margin <= bounds.height {
            y = centerBelow                        // fits below the selection
        } else if centerAbove - h / 2 - margin >= 0 {
            y = centerAbove                         // else flip above
        } else {
            y = bounds.height - h / 2 - margin      // else pin to the bottom edge
        }
        let minY = h / 2 + margin, maxY = bounds.height - h / 2 - margin
        y = maxY >= minY ? min(max(y, minY), maxY) : bounds.height / 2

        let minX = w / 2 + margin, maxX = bounds.width - w / 2 - margin
        let x = maxX >= minX ? min(max(r.midX, minX), maxX) : bounds.width / 2

        return CGPoint(x: x, y: y)
    }

    /// Keep a rect inside `bounds` by sliding it (size preserved). Used while moving.
    static func clampRect(_ r: CGRect, in bounds: CGSize) -> CGRect {
        var rect = r
        if rect.width > bounds.width { rect.size.width = bounds.width }
        if rect.height > bounds.height { rect.size.height = bounds.height }
        if rect.minX < 0 { rect.origin.x = 0 }
        if rect.minY < 0 { rect.origin.y = 0 }
        if rect.maxX > bounds.width { rect.origin.x = bounds.width - rect.width }
        if rect.maxY > bounds.height { rect.origin.y = bounds.height - rect.height }
        return rect
    }
}
