import AppKit
import CoreGraphics

/// One screen the island is drawn on, and the geometry it has there: the physical
/// notch, or a virtual one on a screen with none.
struct IslandScreen: Equatable, Identifiable {
    let id: CGDirectDisplayID
    let geometry: NotchGeometry
}

/// Which screens get an island. The choice is pure (`plan`, over `Info`, what
/// matters of each screen) so it can be tested without a display; `current` and
/// `infos` read the real ones.
enum IslandScreens {
    /// What matters of one screen, in global AppKit coordinates.
    struct Info: Equatable {
        let id: CGDirectDisplayID
        let frame: CGRect
        let visibleFrame: CGRect
        let safeAreaTop: CGFloat
        let leftArea: CGRect?
        let rightArea: CGRect?
        let isBuiltIn: Bool
        /// `NSStatusBar.system.thickness`: the menu bar's height when the screen
        /// does not say.
        let statusBarThickness: CGFloat

        /// Nothing above this is a menu bar: the Dock at the top of the screen
        /// takes room from `visibleFrame` too.
        static let tallestMenuBar: CGFloat = 48

        /// The menu bar's height: what the visible frame leaves out of the top. A
        /// hidden menu bar leaves nothing (and so does a screen with none), and a
        /// Dock at the top leaves too much: the status bar's thickness then.
        var menuBarHeight: CGFloat {
            let bar = frame.maxY - visibleFrame.maxY
            return bar > 0 && bar <= Self.tallestMenuBar ? bar : statusBarThickness
        }

        /// The physical notch, or `nil` when the screen has none.
        var notch: NotchGeometry? {
            NotchGeometry(screenFrame: frame, safeAreaTop: safeAreaTop, leftArea: leftArea, rightArea: rightArea)
        }

        /// The physical notch, or the virtual one on the menu bar.
        var geometry: NotchGeometry {
            notch ?? NotchGeometry(screenFrame: frame, menuBarHeight: menuBarHeight)
        }
    }

    /// The screens that get an island, in the order given. `.notch`: the built-in
    /// screen with a notch, if it is there (with the lid closed it is not in the
    /// list). `.all`: every screen, each with its notch or a virtual one.
    static func plan(_ screens: [Info], choice: IslandScreenChoice) -> [IslandScreen] {
        switch choice {
        case .notch:
            for screen in screens where screen.isBuiltIn {
                if let notch = screen.notch { return [IslandScreen(id: screen.id, geometry: notch)] }
            }
            return []
        case .all:
            return screens.map { IslandScreen(id: $0.id, geometry: $0.geometry) }
        }
    }

    /// What to do to the islands on screen to match a new plan, by display id.
    struct Changes: Equatable {
        /// In the plan and not on screen: a new island, in the plan's order.
        var added: [IslandScreen] = []
        /// On screen and not in the plan: its island closes, in the order they were.
        var removed: [CGDirectDisplayID] = []
        /// In both with another geometry (resolution, arrangement, menu bar): the
        /// island moves, in the plan's order.
        var moved: [IslandScreen] = []

        var isEmpty: Bool { added.isEmpty && removed.isEmpty && moved.isEmpty }
    }

    /// From the islands on `current` to those of `plan`. A screen in both with the
    /// same geometry is left alone.
    static func changes(from current: [IslandScreen], to plan: [IslandScreen]) -> Changes {
        let before = Dictionary(current.map { ($0.id, $0.geometry) }, uniquingKeysWith: { first, _ in first })
        let after = Set(plan.map(\.id))
        var changes = Changes()
        changes.removed = current.map(\.id).filter { !after.contains($0) }
        for screen in plan {
            switch before[screen.id] {
            case nil: changes.added.append(screen)
            case let geometry? where geometry != screen.geometry: changes.moved.append(screen)
            default: break
            }
        }
        return changes
    }

    /// The settings' line on how many screens show the island now.
    static func statusText(count: Int, choice: IslandScreenChoice) -> String {
        switch count {
        case 0: return choice == .notch ? "Sem ecrã com notch" : "Sem ecrãs"
        case 1: return "À vista em 1 ecrã"
        default: return "À vista em \(count) ecrãs"
        }
    }

    // MARK: The real screens (AppKit, not pure)

    @MainActor
    static func infos() -> [Info] {
        NSScreen.screens.compactMap { Info(screen: $0) }
    }

    /// `plan` over the screens that are connected now.
    @MainActor
    static func current(choice: IslandScreenChoice) -> [IslandScreen] {
        plan(infos(), choice: choice)
    }
}

extension IslandScreens.Info {
    @MainActor
    init?(screen: NSScreen) {
        guard let id = screen.displayID else { return nil }
        self.init(id: id, frame: screen.frame, visibleFrame: screen.visibleFrame,
                  safeAreaTop: screen.safeAreaInsets.top,
                  leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea,
                  isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                  statusBarThickness: NSStatusBar.system.thickness)
    }
}

extension NSScreen {
    /// The Core Graphics id of this screen's display.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}
