import Foundation
import CoreGraphics

/// The decisions behind Windows Shortcuts, kept free of AppKit so they can be
/// tested without a keyboard: which keys and modifiers count, which apps are left
/// alone, and which events the tap has to listen to.
enum WindowShortcutRules {
    // Virtual key codes (`Carbon/Events.h`, ANSI). Keycodes, not the characters on
    // the event: with Key Swap the physical ⌃X reaches the tap carrying the control
    // character, not "x". The ⌘[ / ⌘] pair assumes a layout where [ and ] are bare
    // keys (U.S. International – PC, the one this is built for); on layouts that
    // need ⌥ for them macOS moves ⌘[ to another key, and that is accepted.
    static let keyX: Int64 = 0x07
    static let keyC: Int64 = 0x08
    static let keyV: Int64 = 0x09
    static let keyQ: Int64 = 0x0C
    static let keyTab: Int64 = 0x30
    static let keyReturn: Int64 = 0x24
    static let keyF2: Int64 = 0x78
    static let keyLeftBracket: Int64 = 0x21
    static let keyRightBracket: Int64 = 0x1E

    static let finderBundleID = "com.apple.finder"

    /// ⌘ down and none of ⌃ ⌥ ⇧ (caps lock, fn and numpad are ignored). ⌃⌘Q locks
    /// the screen and ⇧⌘Q logs out: those are never ours.
    static func isPlainCommand(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate)
            && !flags.contains(.maskShift)
    }

    /// None of ⌘ ⌃ ⌥ ⇧ (fn may be down: the F keys carry `.maskSecondaryFn`).
    static func hasNoModifiers(_ flags: CGEventFlags) -> Bool {
        !flags.contains(.maskCommand)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate)
            && !flags.contains(.maskShift)
    }

    /// Whether hold-to-quit applies to this app. An unknown app counts as "yes";
    /// one on the exceptions list keeps the plain ⌘Q. The Finder has no Quit, so a
    /// "hold to quit" card there would promise something that never happens.
    static func holdToQuitApplies(bundleID: String?, exceptions: [String]) -> Bool {
        guard let bundleID else { return true }
        return bundleID != finderBundleID && !exceptions.contains(bundleID)
    }

    enum NavDirection { case back, forward }

    /// Apps that already understand the side buttons, or where ⌘[ means something
    /// else (indent): the click goes through as it is.
    static let passThroughBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.apple.dt.Xcode",
        "com.parallels.desktop.console",
        "com.vmware.fusion",
        "com.utmapp.UTM",
        "org.virtualbox.app.VirtualBoxVM",
        "com.apple.ScreenSharing",
        "com.microsoft.rdc.macos",
    ]

    /// `mouseEventButtonNumber` 3 is back and 4 is forward; anything else is not
    /// ours. Also `nil` in apps that handle the buttons themselves (the list above
    /// and Firefox, whatever its channel).
    static func navigation(button: Int64, bundleID: String?) -> NavDirection? {
        if let bundleID,
           passThroughBundleIDs.contains(bundleID) || bundleID.hasPrefix("org.mozilla.") {
            return nil
        }
        switch button {
        case 3: return .back
        case 4: return .forward
        default: return nil
        }
    }

    /// The Accessibility role of a field you type into. Search and secure fields
    /// are `AXTextField` with a subrole, so they are covered too.
    static func isTextInput(role: String?) -> Bool {
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox": return true
        default: return false
        }
    }

    /// What the tap has to listen to for the switches that are on. All off means 0:
    /// no tap at all.
    static func eventMask(finderCutPaste: Bool, f2Rename: Bool,
                          mouseButtons: Bool, holdToQuit: Bool) -> CGEventMask {
        func bit(_ type: CGEventType) -> CGEventMask { 1 << type.rawValue }

        var mask: CGEventMask = 0
        if finderCutPaste || f2Rename || holdToQuit {
            mask |= bit(.keyDown) | bit(.keyUp)
        }
        // Only hold-to-quit follows the modifiers (⌘ released ends the hold).
        if holdToQuit {
            mask |= bit(.flagsChanged)
        }
        if mouseButtons {
            mask |= bit(.otherMouseDown) | bit(.otherMouseUp)
        }
        return mask
    }
}

/// The Finder's "cut": ⌘X is turned into ⌘C, and the next ⌘V moves the files
/// instead of copying them — if nothing else was copied in between.
struct FinderCutTracker {
    /// How long the Finder has to put the files on the pasteboard after ⌘X.
    static let copyWindow: TimeInterval = 1.0

    enum Phase: Equatable {
        case idle
        case copying(baseline: Int, since: TimeInterval)
        case cut(changeCount: Int)
    }

    private(set) var phase: Phase = .idle

    /// ⌘X in the Finder, already turned into ⌘C: wait for the pasteboard to change.
    /// A new ⌘X replaces the previous one.
    mutating func cut(changeCount: Int, at now: TimeInterval) {
        phase = .copying(baseline: changeCount, since: now)
    }

    /// Settle the copy: a changed pasteboard inside the window arms the cut. Once
    /// the window has passed the change can't be told apart from some other copy,
    /// so the cut is dropped.
    mutating func observe(changeCount: Int, at now: TimeInterval) {
        guard case let .copying(baseline, since) = phase else { return }
        if now - since > Self.copyWindow {
            phase = .idle
        } else if changeCount != baseline {
            phase = .cut(changeCount: changeCount)
        }
    }

    /// ⌘V in the Finder: `true` turns it into a move. Settles first, so it works
    /// even if no timer ran. A cut is spent by the first paste; if something else
    /// was copied since, that paste is a normal one.
    mutating func paste(changeCount: Int, at now: TimeInterval) -> Bool {
        observe(changeCount: changeCount, at: now)
        switch phase {
        case let .cut(cut):
            phase = .idle
            return cut == changeCount
        case .copying, .idle:
            return false
        }
    }
}

/// Holding ⌘Q versus tapping it.
struct QuitHold {
    static let duration: TimeInterval = 0.6

    enum Phase: Equatable {
        case idle
        case holding(since: TimeInterval)
        case fired
    }

    private(set) var phase: Phase = .idle

    /// Q went down (with a plain ⌘, in an app that isn't excluded). A fresh press
    /// from idle starts the hold and returns `true` (show the HUD, schedule the
    /// check). Anything else changes nothing and returns `false`.
    mutating func press(isRepeat: Bool, at now: TimeInterval) -> Bool {
        guard phase == .idle, !isRepeat else { return false }
        phase = .holding(since: now)
        return true
    }

    /// Q came up or ⌘ was let go. Returns `true` when that cancelled a hold still
    /// in progress (hide the HUD).
    mutating func release() -> Bool {
        let wasHolding: Bool
        if case .holding = phase { wasHolding = true } else { wasHolding = false }
        phase = .idle
        return wasHolding
    }

    /// The timer check: held for long enough → fire, once. A timer left over from
    /// an earlier tap can't fire a new one, because `since` is the current tap's.
    mutating func shouldQuit(at now: TimeInterval) -> Bool {
        guard case let .holding(since) = phase, now - since >= Self.duration - 0.01 else { return false }
        phase = .fired
        return true
    }

    /// Swallow Q (repeats and the key-up) for as long as this isn't idle.
    var isActive: Bool { phase != .idle }
}
