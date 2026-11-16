import AppKit
import CoreGraphics

/// Whether an app in full screen covers the island's screen, so the island steps
/// aside until it ends. Pure, so it is tested without a window.
///
/// A native full-screen app has its own Space, and the window server is meant to keep
/// the island out of it (see `IslandPanel.makeWindow`), but it did not always: the
/// island showed over a film in full screen. So the Space of each screen is read too
/// (`fullScreenDisplays`): a screen whose current Space is a full-screen one is
/// covered, whatever the windows say. The window check covers the rest: borderless
/// windows the size of the screen (games, players, Keynote) that sit in the ordinary
/// Space, and the moment before the Space change is known.
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

    // MARK: Spaces

    /// The `"type"` of a full-screen Space in the window server's Space list (a desktop is 0).
    static let fullScreenSpaceType = 4
    /// The `"Display Identifier"` of the one entry the list has when the displays share
    /// their Spaces ("Displays have separate Spaces" off): a UUID otherwise, one per display.
    static let sharedSpacesIdentifier = "Main"

    /// The displays whose current Space is a full-screen one, from the window server's
    /// list of Spaces (`SLSCopyManagedDisplaySpaces`): each entry has the display's
    /// `"Display Identifier"` and a `"Current Space"` with its `"type"`. An entry
    /// missing either, or with a Space of another type, is left out.
    static func fullScreenDisplays(in spaces: [[String: Any]]) -> Set<String> {
        Set(spaces.compactMap { entry in
            guard let display = entry["Display Identifier"] as? String,
                  let current = entry["Current Space"] as? [String: Any],
                  (current["type"] as? NSNumber)?.intValue == fullScreenSpaceType
            else { return nil }
            return display
        })
    }

    /// Whether the screen of the display `displayUUID` is in a full-screen Space, given
    /// `fullScreen` (`fullScreenDisplays`) from a list of `entryCount` entries. With
    /// shared Spaces the list has the one entry, `"Main"`, for every screen: when that
    /// one is in full screen, they all are.
    static func isFullScreenSpace(displayUUID: String?, fullScreen: Set<String>, entryCount: Int) -> Bool {
        if let displayUUID, fullScreen.contains(displayUUID) { return true }
        return entryCount == 1 && fullScreen.contains(sharedSpacesIdentifier)
    }
}

/// When the controller looks at the screen on a timer (the full-screen poll).
enum IslandCoverPoll {
    /// While something can show up with no hover (`IslandState.canShowOnItsOwn`), and
    /// while the island is covered: the poll is the only way to see a full screen end
    /// without a change of Space. With only idle sessions listed and nothing covering,
    /// the island is hidden and the hover looks for itself.
    static func isNeeded(canShowOnItsOwn: Bool, covered: Bool) -> Bool {
        canShowOnItsOwn || covered
    }
}

// MARK: - The real system (AppKit, not pure)

/// The window server's list of Spaces, read from SkyLight. This is private API: there
/// is no public one for "which Space is this screen in", and the window server did not
/// keep the island out of a full-screen Space by itself. It needs no permission (it is
/// the same list Mission Control draws from, with no window contents in it). The two
/// functions are looked up once; if either is missing (a system that renamed them)
/// there are no Spaces, nothing is covered by this check, and the window check goes on.
private enum IslandSpaces {
    typealias ConnFn = @convention(c) () -> Int32
    typealias SpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let functions: (connection: ConnFn, spaces: SpacesFn)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connection = dlsym(handle, "SLSMainConnectionID"),
              let spaces = dlsym(handle, "SLSCopyManagedDisplaySpaces")
        else { return nil }
        return (unsafeBitCast(connection, to: ConnFn.self), unsafeBitCast(spaces, to: SpacesFn.self))
    }()

    /// One entry per display (or the one `"Main"` entry), empty when the list is not there.
    static func read() -> [[String: Any]] {
        guard let functions,
              let list = functions.spaces(functions.connection())?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return list
    }
}

extension IslandFullScreen {
    /// The UUID string of a display, the form `"Display Identifier"` has in the list of Spaces.
    static func displayUUID(of id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Whether an app in full screen covers each screen right now, in the same order:
    /// the window list says so (one read for all of them), or the screen's current
    /// Space is a full-screen one (one read of the Spaces). The window check says
    /// `false` for all when the system won't list its windows: the islands stay.
    @MainActor
    static func current(on screens: [IslandScreen]) -> [Bool] {
        guard !screens.isEmpty else { return [] }
        let options = NSApp.currentSystemPresentationOptions
        let frontmost = NSWorkspace.shared.frontmostApplication.map {
            Frontmost(pid: $0.processIdentifier, isFullScreen: isFullScreen(options))
        }
        var byWindows = screens.map { _ in false }
        if let primaryHeight = NSScreen.screens.first?.frame.height,
           let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] {
            let windows = windows(from: info)
            byWindows = screens.map { screen in
                covers(screen: cgRect(fromAppKit: screen.geometry.screenFrame, primaryScreenHeight: primaryHeight),
                       topInset: screen.geometry.notchRect.height,
                       windows: windows,
                       ownPID: ProcessInfo.processInfo.processIdentifier,
                       frontmost: frontmost,
                       islandLevel: IslandPanel.level.rawValue)
            }
        }
        let spaces = IslandSpaces.read()
        let fullScreen = fullScreenDisplays(in: spaces)
        let bySpace = screens.map {
            isFullScreenSpace(displayUUID: displayUUID(of: $0.id), fullScreen: fullScreen, entryCount: spaces.count)
        }
        let covered = zip(byWindows, bySpace).map { $0 || $1 }
        // Testing by hand: `HONE_DEBUG_ISLAND=1` logs every look, to tell a miss of this
        // check from one of the window server's (native full screen, see `IslandPanel`).
        if ProcessInfo.processInfo.environment["HONE_DEBUG_ISLAND"] != nil {
            func flags(_ values: [Bool]) -> String { values.map { $0 ? "1" : "0" }.joined(separator: ",") }
            NSLog("Hone island: covered=%@ windows=%@ spaces=%@ spaceEntries=%d options=%lu frontmost=%d",
                  flags(covered), flags(byWindows), flags(bySpace), spaces.count,
                  options.rawValue, frontmost?.pid ?? -1)
        }
        return covered
    }
}
