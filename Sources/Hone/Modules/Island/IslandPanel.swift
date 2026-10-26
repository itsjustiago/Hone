import AppKit
import SwiftUI

/// What the island's view draws. The controller fills it; the panel animates
/// `presentation`.
@MainActor
@Observable
final class IslandViewModel {
    var presentation: IslandPresentation = .hidden
    var notch = CGSize(width: 185, height: 32)
    var track: NowPlayingTrack?
    var artwork: IslandArtwork?
    var appName: String?
}

/// Never key, never main, never pushed below the menu bar: the island must not
/// take focus from the app in front, and it lives where AppKit keeps windows out.
final class IslandWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The borderless panel over the notch. Its frame is the island's frame, so
/// nothing beside the visible shape blocks a click. To change size it grows the
/// frame first (with room for the spring's overshoot) and then animates the shape;
/// once the spring is over it cuts the frame to the shape, unless a newer change
/// came in meanwhile.
///
/// The SwiftUI view never changes size: it is the geometry's `canvas`, fixed on the
/// screen around the notch, and each frame change moves it the other way inside the
/// window. So the island always grows and shrinks from the notch's centre, however
/// the window around it moves.
@MainActor
final class IslandPanel {
    let model = IslandViewModel()
    private let actions: IslandActions
    private var window: IslandWindow?
    /// The SwiftUI view, `geometry.canvas` in size for good (see `place`).
    private var hosting: NSView?
    private var geometry: NotchGeometry?
    /// Bumped on every change: a delayed resize from an older one is dropped.
    private var generation = 0

    /// What the last `show` asked for.
    private struct Request: Equatable {
        let presentation: IslandPresentation
        let keepsWindow: Bool
    }
    private var lastRequest: Request?

    /// Above the menu bar (24) and the status items (25), below menus (101):
    /// a menu opened from the bar still draws over the island. `IslandFullScreen`
    /// reads it too: a window at or above this level is drawn over the island anyway.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    init(actions: IslandActions) {
        self.actions = actions
    }

    /// Shows `presentation` around the notch of `geometry`. With `keepsWindow`
    /// false (no track), the panel leaves the screen once it has folded away.
    func show(_ presentation: IslandPresentation, on geometry: NotchGeometry, keepsWindow: Bool) {
        let request = Request(presentation: presentation, keepsWindow: keepsWindow)
        // A track update that changes nothing the panel draws (the position moved, the
        // cover is the same) only needs the model, which the controller already filled.
        // Bumping the generation here would cancel the pending `settle` every time, and
        // with updates closer than a spring lasts the frame would never shrink back.
        if let window, window.isVisible, self.geometry == geometry, lastRequest == request { return }
        lastRequest = request
        generation += 1
        let mine = generation
        let target = geometry.islandFrame(for: presentation)

        guard let window, window.isVisible else {
            // Nothing on screen and nothing to show: stay away (no window either).
            guard keepsWindow || presentation != .hidden else { return }
            let window = self.window ?? makeWindow()
            self.window = window
            self.geometry = geometry
            // Come out of the notch: the hover zone is drawn first, at rest, so the
            // spring has something to grow from instead of showing up already open.
            withoutAnimation {
                model.notch = geometry.notchRect.size
                model.presentation = .hidden
            }
            place(window, frame: geometry.windowFrame(current: geometry.islandFrame(for: .hidden), target: target),
                  on: geometry)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            window.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in
                guard let self, mine == self.generation else { return }
                self.animate(to: presentation, settlingAt: target, keepsWindow: keepsWindow, generation: mine)
            }
            return
        }

        if self.geometry != geometry {
            // Another screen layout: jump, nothing to animate from.
            self.geometry = geometry
            withoutAnimation {
                model.notch = geometry.notchRect.size
                model.presentation = presentation
            }
            if !keepsWindow && presentation == .hidden {
                window.orderOut(nil)
            } else {
                place(window, frame: target, on: geometry)
            }
            return
        }

        place(window, frame: geometry.windowFrame(current: window.frame, target: target), on: geometry)
        animate(to: presentation, settlingAt: target, keepsWindow: keepsWindow, generation: mine)
    }

    /// Off the screen at once (no notch any more, or the tool stopped).
    func hide() {
        generation += 1
        lastRequest = nil
        window?.orderOut(nil)
        withoutAnimation { model.presentation = .hidden }
    }

    func close() {
        hide()
        window?.contentView = nil
        window?.close()
        window = nil
        hosting = nil
        geometry = nil
    }

    /// Whether the pointer is over the island as drawn now. The hover callbacks
    /// can report an exit the pointer never made when the content swaps; this is
    /// the ground truth.
    var containsMouse: Bool {
        guard let window, window.isVisible, let geometry else { return false }
        return IslandHover.pointerInside(NSEvent.mouseLocation,
                                         frame: geometry.islandFrame(for: model.presentation))
    }

    // MARK: Private

    /// Animates the shape to `presentation` and cuts the window to `target` once
    /// the spring is over, not after a guess: cut early, the frame would clip the
    /// shape while it still moves.
    private func animate(to presentation: IslandPresentation, settlingAt target: CGRect,
                         keepsWindow: Bool, generation mine: Int) {
        let from = model.presentation
        let animation = IslandMotion.animation(
            from: from, to: presentation,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        withAnimation(animation, completionCriteria: .removed) {
            model.presentation = presentation
        } completion: { [weak self] in
            self?.settle(at: target, keepsWindow: keepsWindow, generation: mine)
        }
        // A completion can stay away (the window left the screen mid-spring): the frame
        // is cut anyway, or the larger window would keep taking clicks.
        DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.settleFallback) { [weak self] in
            self?.settle(at: target, keepsWindow: keepsWindow, generation: mine)
        }
        if presentation == .expanded && from != .expanded {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// Only for the latest change: `hide`, `close` and every new `show` bump the
    /// generation, so an older spring ending never touches the window.
    private func settle(at target: CGRect, keepsWindow: Bool, generation mine: Int) {
        guard mine == generation, let window, window.isVisible, let geometry else { return }
        if !keepsWindow && model.presentation == .hidden {
            window.orderOut(nil)
        } else {
            place(window, frame: target, on: geometry)
        }
    }

    /// Sets the window's frame and moves the canvas-sized view the other way in the
    /// same step, so the island stays exactly where it is on the screen.
    private func place(_ window: NSWindow, frame: CGRect, on geometry: NotchGeometry) {
        let canvas = geometry.canvas
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if window.frame != frame { window.setFrame(frame, display: false) }
        hosting?.frame = CGRect(origin: NotchGeometry.hostOrigin(canvas: canvas, window: frame), size: canvas.size)
        window.displayIfNeeded()
        CATransaction.commit()
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    private func makeWindow() -> IslandWindow {
        let window = IslandWindow(contentRect: .zero,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered,
                                  defer: true)
        window.level = Self.level
        // No `.fullScreenAuxiliary` on purpose: without it the window server keeps a
        // `.canJoinAllSpaces` panel out of another app's full-screen Space, display by
        // display and with no flash while the Space slides in. With it the island
        // would sit on top of the video, the game or the Keynote.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        let hosting = NSHostingView(rootView: IslandRootView(model: model, actions: actions))
        // The panel sizes the window; the view must not push its own size on it, nor
        // follow the window's: `place` gives it the canvas and moves it.
        hosting.sizingOptions = []
        hosting.autoresizingMask = []
        let container = NSView()
        container.addSubview(hosting)
        window.contentView = container
        self.hosting = hosting
        return window
    }
}

private struct IslandRootView: View {
    let model: IslandViewModel
    let actions: IslandActions

    var body: some View {
        IslandView(presentation: model.presentation, notch: model.notch, track: model.track,
                   artwork: model.artwork, appName: model.appName, actions: actions)
            .ignoresSafeArea()
    }
}
