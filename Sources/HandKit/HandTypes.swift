import Foundation

// The hand mouse's public vocabulary. The Hone module turns camera frames into
// `HandLandmarks`, feeds them to `HandMouseEngine`, and performs the
// `HandAction`s it returns. Nothing here touches the camera, the cursor or the
// keyboard, so all of it runs in tests.

/// One normalized 2D point. x grows right, y grows DOWN (top-left origin), both 0…1
/// across the camera frame. The frame is already mirrored, so moving the hand to
/// your right moves x up.
public struct HandPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// 21 hand joints in MediaPipe order (Vision maps 1:1):
/// 0 wrist · 1–4 thumb CMC, MCP, IP, tip · 5–8 index MCP, PIP, DIP, tip ·
/// 9–12 middle · 13–16 ring · 17–20 pinky.
public struct HandLandmarks: Equatable, Sendable {
    public static let count = 21
    public var points: [HandPoint]
    /// `points.count` must be 21; returns nil otherwise.
    public init?(points: [HandPoint]) {
        guard points.count == Self.count else { return nil }
        self.points = points
    }
    public subscript(i: Int) -> HandPoint { points[i] }
}

/// Where a window action aims.
public enum CursorTarget: Equatable, Sendable {
    /// u, v in 0…1 across the current screen (top-left origin).
    case point(u: Double, v: Double)
    /// Ctrl lock leaves the cursor to the real mouse: aim wherever it is now.
    case realCursor
}

/// The ⌘ shortcuts of shortcut mode (Ctrl mode on Windows; ⌘ on the Mac).
public enum HandShortcut: String, Equatable, Sendable {
    case copy       // ⌘C
    case paste      // ⌘V
    case undo       // ⌘Z
    case duplicate  // ⌘D
    case enter      // Return, no modifier
}

/// What the engine asks the host to do, in order, for one frame.
public enum HandAction: Equatable, Sendable {
    /// Put the cursor at u, v (0…1 across the current screen, top-left origin).
    /// `dragging` = the left button is held (post a drag, not a move).
    case moveCursor(u: Double, v: Double, dragging: Bool)
    /// Move to the next screen; the cursor re-centres on the hand there.
    case nextScreen
    case leftClick
    case rightClick
    case leftDown
    case leftUp
    /// Vertical scroll in points. Positive = content moves down (like dragging it
    /// down with a finger on a trackpad with natural scrolling).
    case scroll(points: Double)
    case minimizeWindow(at: CursorTarget)
    case closeWindow(at: CursorTarget)
    /// Window picker (Mission Control on the Mac). The cursor stays live in it.
    case openSwitcher
    /// Click the window under the cursor in the picker.
    case pickInSwitcher
    /// Leave the picker without choosing (Esc).
    case cancelSwitcher
    case shortcut(HandShortcut)
}

/// What the HUD shows.
public enum HandMode: Equatable, Sendable {
    case noHand
    case pointing
    case slow
    case clicking
    case dragging
    case scrolling
    /// Thumbs-up: cursor frozen. `lockIn` = seconds until Ctrl lock toggles
    /// (`.infinity` when shortcut gestures are off: there is no lock to arm).
    case frozen(lockIn: Double)
    /// Hand tipped flat: cursor frozen; curl the fingers to close the window.
    case flat
    case switcher
    case shortcuts
    /// Shortcut mode latched on (thumbs-up held); the real mouse drives the cursor.
    /// `unlockIn` is set while a thumbs-up is being held to unlock.
    case shortcutsLocked(unlockIn: Double?)
}

public struct HandStatus: Equatable, Sendable {
    public var mode: HandMode = .noHand
    /// Human label of the last action (PT-PT), e.g. "Clique", "Copiar".
    public var lastAction: String?
    /// 0…1 while a hold is in progress (drag, close, switcher, lock), else nil.
    public var holdProgress: Double?
    /// The index tip left the active area on that side (top, bottom, left, right).
    public var edges: (top: Bool, bottom: Bool, left: Bool, right: Bool) = (false, false, false, false)
    public init() {}

    public static func == (a: HandStatus, b: HandStatus) -> Bool {
        a.mode == b.mode && a.lastAction == b.lastAction && a.holdProgress == b.holdProgress
            && a.edges == b.edges
    }
}

/// The active area: the part of the camera frame that maps onto the screen.
public struct HandBox: Codable, Equatable, Sendable {
    public var left, top, right, bottom: Double
    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    /// Original default: top-right quarter of the frame, padded off the edges
    /// (a right hand held beside the face, as seen in the mirrored frame).
    public static let `default` = HandBox(left: 0.50, top: 0.05, right: 0.95, bottom: 0.50)
}

/// The sideways hand that enters shortcut mode, captured by `CtrlPoseRecorder`.
public struct CtrlPose: Codable, Equatable, Sendable {
    /// Knuckles 5, 9, 13, 17 relative to the wrist, scaled by hand size (x, y pairs).
    public var shape: [Double]
    /// Match threshold (mean point distance).
    public var maxDistance: Double
    public init(shape: [Double], maxDistance: Double) {
        self.shape = shape; self.maxDistance = maxDistance
    }
}

/// The user-tunable knobs. Defaults are the original's.
public struct HandConfig: Codable, Equatable, Sendable {
    public var box: HandBox = .default
    public var ctrlPose: CtrlPose?
    /// One-Euro min cutoff (Hz). Lower = steadier but laggier.
    public var smoothing: Double = 0.8
    /// One-Euro beta. Higher = less lag on fast moves.
    public var responsiveness: Double = 6.0
    /// Pinch on/off thresholds (fingertip gap / hand size).
    public var pinchOn: Double = 0.30
    public var pinchOff: Double = 0.40
    /// Scroll speed in the original's unit: Windows wheel units per full frame height
    /// of hand movement (120 units = one notch ≈ 40 pt), so 3000 ≈ 1000 pt per frame height.
    public var scrollGain: Double = 3000
    /// Slow mode cursor speed fraction.
    public var fineSpeed: Double = 0.3
    /// Window gestures (fist = minimize, flat + curl = close, rock = switcher).
    public var windowGestures: Bool = true
    /// Shortcut mode (⌘C/⌘V/⌘Z/⌘D/Return) and Ctrl lock.
    public var shortcutGestures: Bool = true
    public init() {}
}
