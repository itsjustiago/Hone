import AppKit
import CoreGraphics

/// Remembers which window the user was in, and in what order before that.
///
/// Stacking order looks like recency and isn't. An app's other windows sit above
/// everything else the moment that app is in front, so with three Firefox windows
/// open, ⌥-Tab from Firefox landed on *another Firefox window* rather than the
/// window the user had actually just come from — the "third one" problem. Palettes,
/// windows raised by a notification and anything on another Space skew it further.
///
/// So the switcher keeps its own most-recently-used list, fed from three places:
/// the window it focuses itself, the front window of any app the user activates by
/// other means (a click, ⌘-Tab, the Dock), and the window in front when the
/// switcher is summoned. Anything never seen falls back to stacking order, which
/// is the best guess available and is also how the list is seeded at launch.
@MainActor
final class AltTabWindowOrder {
    /// Most recently used first.
    private var order: [CGWindowID] = []
    private var observer: NSObjectProtocol?

    /// An activation is reported the moment the app comes forward, which can be a
    /// hair before its window is actually on top — so the front window is read one
    /// beat later rather than racing it.
    private let settleDelay: TimeInterval = 0.08

    func start() {
        guard observer == nil else { return }
        order = AltTabWindowLister.windowIDsInStackingOrder()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + self.settleDelay) { [weak self] in
                    guard let id = AltTabWindowLister.frontWindowID(ofApplication: pid) else { return }
                    self?.touch(id)
                }
            }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        order = []
    }

    /// This window is the one in use now.
    func touch(_ id: CGWindowID) {
        guard id != 0 else { return }
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// Whatever is in front right now is, by definition, the window being used —
    /// worth re-checking as the switcher opens so the top of the list is right even
    /// if an activation went unseen.
    func noteFrontWindow() {
        // Asked of the front *app* rather than of the raw stacking order, whose
        // top window can belong to some agent's panel the user never chose.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let id = AltTabWindowLister.frontWindowID(ofApplication: pid)
        else { return }
        touch(id)
    }

    /// Position in the list, most recent first. A window never seen sorts after
    /// every one that has been, keeping its stacking order among its own kind.
    func rank(of id: CGWindowID) -> Int {
        order.firstIndex(of: id) ?? Int.max
    }
}
