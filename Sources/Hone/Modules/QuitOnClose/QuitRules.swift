import CoreGraphics
import Foundation

// The decisions behind Quit on Close, kept free of any system call so every one of
// them can be tested. `WindowCensus` asks the system; this file only judges.
//
// One rule runs through all of it: **quit on proof, never on silence.** An app
// that didn't answer, an AX list that came back empty because the app doesn't
// expose its windows, a window that is merely minimized, hidden or on another
// Space — none of that is an app without windows, and quitting it is not
// something a timer can take back (Steam took the running game down with it).

/// What the AX API says about one window, reduced to what the decision needs.
struct WindowFact: Equatable {
    var subrole: String?
    var isMinimized: Bool
}

/// The AX answer to "what are your windows?". A reply that isn't a clean list is
/// `failed` — never an empty list, which is the one answer that has to mean "none".
enum WindowListing: Equatable {
    case answered([WindowFact])
    case failed
}

/// What one look at an app found. Only `.empty` can lead to a quit.
enum WindowVerdict: Equatable {
    enum Evidence: Equatable {
        /// An ordinary window in the AX list.
        case accessibility
        /// A window drawn on screen that the AX list doesn't count: apps that
        /// expose their windows as `AXUnknown`, or not at all.
        case screen
    }

    enum Doubt: Equatable {
        /// The AX query failed, so nothing is known about the app's windows.
        case noAnswer
        /// ⌘H: the windows are off screen on purpose.
        case hidden
        /// A GUI app it started is still running — a launcher with its game.
        case activeChild
    }

    case windowed(Evidence)
    case empty
    case doubtful(Doubt)
}

enum QuitRules {
    /// Apps that are never quit, whatever the lists say: not a preference, a floor
    /// under them. The Finder is expected to run without windows and the desktop
    /// breaks without it; Steam carries on happily with its window minimized or
    /// closed, and quitting it ends the game it launched.
    static let neverQuit: Set<String> = [
        "com.apple.finder",
        "com.valvesoftware.steam",
    ]

    // MARK: - What counts as a window

    /// Whether this window keeps its app in use.
    ///
    /// Minimized windows count — an app with a window in the Dock has not been
    /// closed — and so does anything with a subrole we don't know. Floating
    /// palettes don't keep an app alive on their own. `AXUnknown` is the odd one:
    /// apps draw invisible helpers as that, so while it is open it proves nothing,
    /// but one in the Dock is certainly a window somebody minimized.
    static func countsAsWindow(_ window: WindowFact) -> Bool {
        guard isAuxiliarySubrole(window.subrole) else { return true }
        return window.subrole == "AXUnknown" && window.isMinimized
    }

    // MARK: - The verdict

    /// Weighs the evidence, cheapest first. `visibleOnScreen`, `isHidden` and
    /// `hasActiveChild` only run when the AX list had nothing — and `visibleOnScreen`
    /// is `nil` when the system couldn't be asked, which is doubt, not "no".
    static func verdict(listing: WindowListing,
                        visibleOnScreen: () -> Bool?,
                        isHidden: () -> Bool,
                        hasActiveChild: () -> Bool) -> WindowVerdict {
        guard case .answered(let windows) = listing else { return .doubtful(.noAnswer) }
        if windows.contains(where: countsAsWindow) { return .windowed(.accessibility) }
        guard let visible = visibleOnScreen() else { return .doubtful(.noAnswer) }
        if visible { return .windowed(.screen) }
        if isHidden() { return .doubtful(.hidden) }
        if hasActiveChild() { return .doubtful(.activeChild) }
        return .empty
    }

    enum Assessment: Equatable {
        case provenEmpty
        /// Not proven; the text says why, for the log.
        case keep(String)
    }

    /// `vouched`: the app has been seen with a real window since the Spaces last
    /// changed (see `WindowStamps`), i.e. its AX list is one that can be believed.
    static func assess(_ verdict: WindowVerdict, vouched: Bool) -> Assessment {
        switch verdict {
        case .windowed(.accessibility): return .keep("has a window")
        case .windowed(.screen): return .keep("has a window on screen that AX doesn't list")
        case .doubtful(.noAnswer): return .keep("AX gave no clean answer")
        case .doubtful(.hidden): return .keep("hidden")
        case .doubtful(.activeChild): return .keep("a GUI app it started is still running")
        case .empty: return vouched ? .provenEmpty : .keep("not seen with a window in this Space")
        }
    }

    // MARK: - Windows on screen

    /// Anything smaller is a helper, a shadow or a status blip, not a window.
    private static let smallestVisibleSide: CGFloat = 50

    /// The owners of ordinary windows currently on screen, from the dictionaries of
    /// `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`: layer 0, not transparent,
    /// big enough to be a window. Current Space only, and no screen capture — owner,
    /// layer and bounds are not what the Screen Recording permission protects.
    static func visibleWindowOwners(in windows: [[String: Any]]) -> Set<pid_t> {
        var owners = Set<pid_t>()
        for window in windows {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.05,
                  let bounds = (window[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                  bounds.width >= smallestVisibleSide, bounds.height >= smallestVisibleSide
            else { continue }
            owners.insert(pid)
        }
        return owners
    }

    // MARK: - Child processes

    /// The processes below `root`, a few levels down (a launcher often starts its
    /// game through a script) and never more than `limit`, whatever shape the tree has.
    static func descendants(of root: pid_t, maxDepth: Int = 3, limit: Int = 64,
                            children: (pid_t) -> [pid_t]) -> [pid_t] {
        var found: [pid_t] = []
        var seen: Set<pid_t> = [root]
        var frontier = [root]
        for _ in 0..<maxDepth {
            var next: [pid_t] = []
            for parent in frontier {
                for child in children(parent) where seen.insert(child).inserted {
                    found.append(child)
                    if found.count >= limit { return found }
                    next.append(child)
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return found
    }
}

/// Which apps have been **seen with a real window**, and when — in Space terms.
///
/// The AX list of an app is believable only for an app it has been seen to work
/// for. Two kinds of app answer "no windows" while being in use: those whose
/// windows AX doesn't expose at all, and — since the list only holds the windows of
/// the Spaces on screen — those with every window on another Space (full screen,
/// a second display). Requiring that the app was seen with a window *since the
/// Spaces last changed* rules both out: the first never earns a mark, and the
/// second loses it the moment the user moves away.
///
/// There is one way past a stale mark: the app itself reported a window closing
/// and its watcher knows of no other. Without that, closing a full-screen window
/// — which changes the Space as well — could never quit anything.
struct WindowStamps {
    private struct Mark {
        var epoch: Int
        var closures: Int
    }

    /// Bumped whenever the Spaces may have changed (see `QuitOnCloseController`).
    private(set) var epoch = 0
    private var marks: [pid_t: Mark] = [:]
    private var closures: [pid_t: Int] = [:]

    mutating func spaceMayHaveChanged() { epoch += 1 }

    /// The app has an ordinary window in the AX list right now.
    mutating func sawWindow(_ pid: pid_t) {
        marks[pid] = Mark(epoch: epoch, closures: closures[pid, default: 0])
    }

    /// The app announced that one of its windows is gone.
    mutating func sawClosure(_ pid: pid_t) {
        closures[pid, default: 0] += 1
    }

    /// Nothing about a process may outlive it — pids get reused.
    mutating func forget(_ pid: pid_t) {
        marks[pid] = nil
        closures[pid] = nil
    }

    /// Whether an empty AX list from this app can be believed. `knownWindows` is how
    /// many windows its watcher still thinks are alive.
    func vouches(for pid: pid_t, knownWindows: Int) -> Bool {
        guard let mark = marks[pid] else { return false }
        if mark.epoch == epoch { return true }
        return closures[pid, default: 0] > mark.closures && knownWindows == 0
    }
}
