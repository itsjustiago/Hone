import AppKit
import CoreGraphics

/// Whether an app in full screen covers the island's screen, so the island steps
/// aside until it ends. Pure, so it is tested without a window.
///
/// A native full-screen app has its own Space, and the window server already keeps
/// the island out of it (see `IslandPanel.makeWindow`). This covers what it can't:
/// borderless windows the size of the screen (games, players, Keynote) that sit in
/// the ordinary Space, and the moment before the Space change is known.
///
/// Bounds alone are not enough. On a notched screen a native full-screen window
/// stops below the notch, so its bounds equal those of a maximized window when the
/// Dock auto-hides, and the island must stay over the latter. So a window that
/// stops short of the notch only counts when the app in front says the system is in
/// full screen too.
enum IslandFullScreen {
    /// One on-screen window, from `CGWindowListCopyWindowInfo` metadata only
    /// (owner, layer, bounds, alpha — nothing the Screen Recording permission protects).
    struct Window: Equatable {
        let pid: pid_t
        let layer: Int
        /// CG global coordinates: origin at the top-left of the main screen, y down.
        let bounds: CGRect
        let alpha: Double
    }

    /// The app in front and whether it put the system in full screen (see `isFullScreen(_:)`).
    struct Frontmost: Equatable {
        let pid: pid_t
        let isFullScreen: Bool
    }

    /// Points of slack when comparing with the screen: bounds are whole points and
    /// scaled display modes may round.
    static let tolerance: CGFloat = 1

    /// Anything smaller is a helper, a shadow or a 1×1 blip, not a window in front of
    /// the full screen. Same limits as `QuitRules`.
    static let smallestSide: CGFloat = 50
    /// Fainter than this is a window fading in or out, not one that hides the screen.
    static let faintestAlpha: Double = 0.05

    /// Whether a window of another app fills `screen`. `screen` is in CG coordinates
    /// and `topInset` is the notch's height; `windows` come front to back, as the
    /// window list gives them.
    ///
    /// Only windows of other processes that are drawn (not transparent), big enough,
    /// not behind the desktop and below the island's own level count: above it the
    /// island is under them already, and nothing there is an app's full screen.
    ///
    /// - A window that holds the whole screen covers it. Above layer 0 any such
    ///   window counts (Wine puts its full-screen windows over the menu bar). At
    ///   layer 0 only the app in front on this screen decides — its front windows,
    ///   so a dialog or a sheet over its full screen still counts — and a game left
    ///   full screen behind Safari after ⌘Tab does not hide the island.
    /// - Native full screen stops below the notch: it covers only when the app in
    ///   front says it is in full screen and its front window is on this screen. With
    ///   the focus on a full-screen window on another display, a maximized window of
    ///   the same app here is just a window.
    static func covers(screen: CGRect, topInset: CGFloat, windows: [Window], ownPID: pid_t,
                       frontmost: Frontmost?, islandLevel: Int) -> Bool {
        let drawn = windows.filter {
            $0.pid != ownPID && $0.alpha > faintestAlpha && (0..<islandLevel).contains($0.layer)
                && $0.bounds.width >= smallestSide && $0.bounds.height >= smallestSide
        }
        let here = drawn.filter { !$0.bounds.intersection(screen).isEmpty }
        let whole = screen.insetBy(dx: tolerance, dy: tolerance)
        if here.contains(where: { $0.layer > 0 && $0.bounds.contains(whole) }) { return true }

        let normal = here.filter { $0.layer == 0 }
        guard let first = normal.first else { return false }
        let front = normal.prefix { $0.pid == first.pid }
        if front.contains(where: { $0.bounds.contains(whole) }) { return true }

        guard let frontmost, frontmost.isFullScreen, first.pid == frontmost.pid,
              let systemFront = drawn.first(where: { $0.layer == 0 }),
              !systemFront.bounds.intersection(screen).isEmpty
        else { return false }
        let belowNotch = CGRect(x: screen.minX, y: screen.minY + topInset,
                                width: screen.width, height: screen.height - topInset)
            .insetBy(dx: tolerance, dy: tolerance)
        return front.contains { $0.bounds.contains(belowNotch) }
    }

    /// Whether the presentation options of the app in front say full screen: native
    /// full screen, or a menu bar it hides or lets hide itself (games, Keynote).
    static func isFullScreen(_ options: NSApplication.PresentationOptions) -> Bool {
        !options.isDisjoint(with: [.fullScreen, .hideMenuBar, .autoHideMenuBar])
    }

    /// A rect from global AppKit coordinates (origin at the bottom-left of the main
    /// screen, y up) to CG ones (top-left, y down). A screen above the main one gets
    /// a negative y.
    static func cgRect(fromAppKit rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The windows of `CGWindowListCopyWindowInfo`, in the same order, skipping any
    /// entry without an owner, layer or bounds. The window name is never read.
    static func windows(from info: [[String: Any]]) -> [Window] {
        info.compactMap { entry in
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
            else { return nil }
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return Window(pid: pid, layer: layer, bounds: bounds, alpha: alpha)
        }
    }
}

// MARK: - The real system (AppKit, not pure)

extension IslandFullScreen {
    /// Whether an app in full screen covers the screen of `geometry` right now.
    /// `false` when the system won't list its windows: the island stays.
    @MainActor
    static func current(on geometry: NotchGeometry) -> Bool {
        guard let primaryHeight = NSScreen.screens.first?.frame.height,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let options = NSApp.currentSystemPresentationOptions
        let frontmost = NSWorkspace.shared.frontmostApplication.map {
            Frontmost(pid: $0.processIdentifier, isFullScreen: isFullScreen(options))
        }
        let covered = covers(
            screen: cgRect(fromAppKit: geometry.screenFrame, primaryScreenHeight: primaryHeight),
            topInset: geometry.notchRect.height,
            windows: windows(from: info),
            ownPID: ProcessInfo.processInfo.processIdentifier,
            frontmost: frontmost,
            islandLevel: IslandPanel.level.rawValue)
        // Testing by hand: `HONE_DEBUG_ISLAND=1` logs every look, to tell a miss of this
        // check from one of the window server's (native full screen, see `IslandPanel`).
        if ProcessInfo.processInfo.environment["HONE_DEBUG_ISLAND"] != nil {
            NSLog("Hone island: covered=%d options=%lu frontmost=%d",
                  covered ? 1 : 0, options.rawValue, frontmost?.pid ?? -1)
        }
        return covered
    }
}
