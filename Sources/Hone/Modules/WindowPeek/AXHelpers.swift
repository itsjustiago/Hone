import ApplicationServices
import CoreGraphics
import AppKit

/// An application currently hovered in the Dock, resolved to a running process.
struct DockedApp: Equatable {
    let pid: pid_t
    let name: String
    /// The Dock icon's frame in CoreGraphics screen coordinates (top-left origin).
    let iconFrame: CGRect
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

/// Converts a bottom-left-origin AppKit point (e.g. `NSEvent.mouseLocation`) to
/// the top-left-origin coordinate space used by CoreGraphics and the AX API.
@MainActor
func flipToCGCoords(_ point: CGPoint) -> CGPoint {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: point.x, y: primaryHeight - point.y)
}
