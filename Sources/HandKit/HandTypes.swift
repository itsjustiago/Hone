import Foundation

// The hand mouse's public vocabulary. The Hone module turns camera frames into
// `HandLandmarks`, feeds them to `HandMouseEngine`, and performs the
// `HandAction`s it returns. Nothing here touches the camera, the cursor or the
// keyboard, so all of it runs in tests.

/// One normalized 2D point. x grows right, y grows DOWN (top-left origin), both 0…1
/// across the camera frame. The frame is already mirrored, so moving the hand to
/// your right moves x up.
public struct HandPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// 21 hand joints in MediaPipe order (Vision maps 1:1):
/// 0 wrist · 1–4 thumb CMC, MCP, IP, tip · 5–8 index MCP, PIP, DIP, tip ·
/// 9–12 middle · 13–16 ring · 17–20 pinky.
public struct HandLandmarks: Codable, Equatable, Sendable {
    public static let count = 21
    public var points: [HandPoint]
    /// Per-joint confidence 0…1 from the detector, same order as `points`; nil when unknown.
    public var confidence: [Double]?
    /// `points.count` must be 21 (and `confidence`, when given); returns nil otherwise.
    public init?(points: [HandPoint], confidence: [Double]? = nil) {
        guard points.count == Self.count, confidence == nil || confidence?.count == Self.count else { return nil }
        self.points = points
        self.confidence = confidence
    }
    public subscript(i: Int) -> HandPoint { points[i] }
}

/// Bones of the hand (pairs of joint ids), for drawing a skeleton.
public enum HandSkeleton {
    public static let bones: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (0, 5), (5, 6), (6, 7), (7, 8),
        (5, 9), (9, 10), (10, 11), (11, 12),
        (9, 13), (13, 14), (14, 15), (15, 16),
        (13, 17), (17, 18), (18, 19), (19, 20), (0, 17),
    ]
}

/// One recorded camera frame: for diagnostics recordings that tests replay.
public struct HandFrame: Codable, Equatable, Sendable {
    /// Seconds since the recording started.
    public var t: Double
    /// nil = no hand in that frame.
    public var hand: HandLandmarks?
    public init(t: Double, hand: HandLandmarks?) { self.t = t; self.hand = hand }
}

/// A screen in points, global coordinates with the origin at the primary display's
/// top-left, y down (CG space).
public struct HandRect: Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// The screens the cursor may be on and which one the active area maps to.
public struct HandDesktop: Equatable, Sendable {
    public var screens: [HandRect]
    /// Index into `screens` of the one the box maps to: the built-in display (the
    /// camera's), else the primary.
    public var home: Int
    public init(screens: [HandRect], home: Int) {
        self.screens = screens; self.home = home
    }
    /// One unit screen (0, 0, 1, 1): what the engine uses until the host says
    /// otherwise; u, v and points coincide.
    public static let single = HandDesktop(screens: [HandRect(x: 0, y: 0, width: 1, height: 1)], home: 0)
}

/// Where a window action aims.
public enum CursorTarget: Equatable, Sendable {
    /// x, y in global points (CG space: origin at the primary display's top-left, y down).
    case point(x: Double, y: Double)
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
    /// Put the cursor at x, y: global points in CG space (origin at the primary
    /// display's top-left, y down), always on one of `HandDesktop.screens`.
    /// `dragging` = the left button is held (post a drag, not a move).
    case moveCursor(x: Double, y: Double, dragging: Bool)
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
    /// How closed the click pinch is, 0 (open) … 1 (pinched). Feedback before the click fires.
    public var pinch: Double = 0
    /// Where the cursor is, in global points (CG space, like `moveCursor`), for drawing
    /// the hand around it; nil = not known.
    public var cursor: (x: Double, y: Double)?
    /// 0…1 while a hold is in progress (drag, close, switcher, lock), else nil.
    public var holdProgress: Double?
    /// The cursor is held at the edge of the screens on that side (top, bottom, left,
    /// right): the hand goes on, the cursor doesn't. Only while pointing.
    public var edges: (top: Bool, bottom: Bool, left: Bool, right: Bool) = (false, false, false, false)
    public init() {}

    public static func == (a: HandStatus, b: HandStatus) -> Bool {
        a.mode == b.mode && a.lastAction == b.lastAction && a.holdProgress == b.holdProgress
            && a.edges == b.edges && a.pinch == b.pinch && a.cursor?.x == b.cursor?.x && a.cursor?.y == b.cursor?.y
    }
}

/// The active area: the part of the camera frame that maps onto the screen.
public struct HandBox: Codable, Equatable, Sendable {
    public var left, top, right, bottom: Double
    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    /// Default: the right side of the frame, its lower half (a right hand
    /// held level with the screen, not with the camera above it, as seen mirrored).
    public static let `default` = HandBox(left: 0.50, top: 0.55, right: 0.95, bottom: 0.95)
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
    /// Pinch on/off thresholds (thumb tip to fingertip gap / hand size), with hysteresis.
    public var pinchOn: Double = 0.30
    public var pinchOff: Double = 0.40
    /// Scroll speed in the original's unit: Windows wheel units per full frame height
    /// of hand movement (120 units = one notch ≈ 40 pt), so 3000 ≈ 1000 pt per frame height.
    public var scrollGain: Double = 3000
    /// Cursor speed fraction while the hand moves slowly (precision near a target);
    /// fast moves use the full box mapping and the offset catches up.
    public var fineSpeed: Double = 0.4
    /// Window gestures (fist = minimize, flat + curl = close, rock = switcher).
    public var windowGestures: Bool = true
    /// Shortcut mode (⌘C/⌘V/⌘Z/⌘D/Return) and Ctrl lock.
    public var shortcutGestures: Bool = true
    public init() {}

    /// Tolerant: a key missing from stored JSON (a field added later) keeps its default,
    /// so an older saved config still loads with the user's calibration.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        box = try c.decodeIfPresent(HandBox.self, forKey: .box) ?? box
        ctrlPose = try c.decodeIfPresent(CtrlPose.self, forKey: .ctrlPose)
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? smoothing
        responsiveness = try c.decodeIfPresent(Double.self, forKey: .responsiveness) ?? responsiveness
        pinchOn = try c.decodeIfPresent(Double.self, forKey: .pinchOn) ?? pinchOn
        pinchOff = try c.decodeIfPresent(Double.self, forKey: .pinchOff) ?? pinchOff
        scrollGain = try c.decodeIfPresent(Double.self, forKey: .scrollGain) ?? scrollGain
        fineSpeed = try c.decodeIfPresent(Double.self, forKey: .fineSpeed) ?? fineSpeed
        windowGestures = try c.decodeIfPresent(Bool.self, forKey: .windowGestures) ?? windowGestures
        shortcutGestures = try c.decodeIfPresent(Bool.self, forKey: .shortcutGestures) ?? shortcutGestures
    }
}
