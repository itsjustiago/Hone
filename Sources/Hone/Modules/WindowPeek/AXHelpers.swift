import ApplicationServices
import CoreGraphics
import AppKit

/// An application currently hovered in the Dock, resolved to a running process.
struct DockedApp: Equatable {
    let pid: pid_t
    let name: String
    /// The Dock icon's frame in CoreGraphics screen coordinates (top-left origin).
    /// Not fixed for the life of a hover: the Dock keeps moving the icon while it
    /// slides up out of auto-hide, and again as it magnifies under the pointer.
    var iconFrame: CGRect
}

/// A single window belonging to an app.
struct WindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let ownerPID: pid_t
    /// Window frame in CoreGraphics screen coordinates (top-left origin).
    let bounds: CGRect
    var thumbnail: CGImage?
    var isMinimized: Bool = false

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.bounds == rhs.bounds
            && lhs.isMinimized == rhs.isMinimized
    }
}

/// Small typed wrappers over the C Accessibility API.
enum AX {
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    static func url(_ element: AXUIElement, _ attribute: String) -> URL? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return ref as? URL
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        if let value = ref as? Bool { return value }
        if let number = ref as? NSNumber { return number.boolValue }
        return nil
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let array = ref as? [AXUIElement]
        else { return [] }
        return array
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValue(element, attribute) else { return nil }
        var out = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &out) ? out : nil
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValue(element, attribute) else { return nil }
        var out = CGSize.zero
        return AXValueGetValue(value, .cgSize, &out) ? out : nil
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    @discardableResult
    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFBoolean) == .success
    }
}

extension AX {
    /// An app's windows, with a deadline and an answer to "did it just not reply?".
    ///
    /// The AX API talks to the target app and waits for it to answer, which a busy
    /// or wedged app can drag out for over a second — long enough to hold up
    /// anything on a keystroke's critical path. `timeout` caps that wait, and
    /// `stalled` tells apart an app with no windows from one that never replied,
    /// so the caller can stop asking it.
    static func windows(ofApplication pid: pid_t, timeout: Float) -> (windows: [AXUIElement], stalled: Bool) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var ref: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &ref)
        return (ref as? [AXUIElement] ?? [], status == .cannotComplete)
    }

    /// The live AX element behind a listed window, so it can be raised or closed.
    ///
    /// Matched by exact title when the window has one — unique enough in practice —
    /// and otherwise by the nearest top-left corner, which is all an untitled
    /// window gives us to go on.
    static func window(for info: WindowInfo) -> AXUIElement? {
        // Generous next to the switcher's own deadline — raising or closing is worth
        // waiting a moment for — but still a deadline, so a wedged app can't hang
        // the pointer or the key release that asked for it.
        let windows = self.windows(ofApplication: info.ownerPID, timeout: 0.25).windows
        if !info.title.isEmpty {
            for window in windows where string(window, "AXTitle") == info.title {
                return window
            }
        }
        var best: AXUIElement?
        var bestDistance = Double.greatestFiniteMagnitude
        for window in windows {
            guard let position = point(window, "AXPosition") else { continue }
            let distance = hypot(position.x - info.bounds.minX, position.y - info.bounds.minY)
            if distance < bestDistance {
                bestDistance = distance
                best = window
            }
        }
        return best
    }
}

/// Whether an `AXSubrole` is a palette / panel rather than a real, switchable
/// window. Used to filter minimized windows: a minimized window keeps a valid
/// subrole (often `AXStandardWindow`, but some apps report `AXDialog`), and all of
/// those are worth showing — only floating auxiliary panels are not.
func isAuxiliarySubrole(_ subrole: String?) -> Bool {
    switch subrole {
    case "AXFloatingWindow", "AXSystemFloatingWindow", "AXUnknown": return true
    default: return false
    }
}

/// Converts a bottom-left-origin AppKit point (e.g. `NSEvent.mouseLocation`) to
/// the top-left-origin coordinate space used by CoreGraphics and the AX API.
@MainActor
func flipToCGCoords(_ point: CGPoint) -> CGPoint {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: point.x, y: primaryHeight - point.y)
}
