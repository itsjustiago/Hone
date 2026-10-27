import AppKit
import SwiftUI

/// What the island's view draws. The controller fills it; the panel sets
/// `layout` (the content follows it with SwiftUI) and moves `outline`.
@MainActor
@Observable
final class IslandViewModel {
    /// What the island shows, from `IslandState.layout(at:)`.
    var layout = IslandLayout.empty
    var notch = CGSize(width: 185, height: 32)
    /// The shape as drawn this frame, on its way to `layout`'s.
    var outline = IslandOutline(.empty, notch: CGSize(width: 185, height: 32))
    var track: NowPlayingTrack?
    var artwork: IslandArtwork?
    var appName: String?
    /// Claude Code's sessions and the user's agents, for the Claude wings and page.
    /// `nil` without `~/.claude` or with the setting off.
    var claude: ClaudeSnapshot?

    var presentation: IslandPresentation { layout.presentation }
    /// The Claude notice on show, if the island is peeking one.
    var notice: IslandNotice? { layout.notice }
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
/// frame first (with room for the spring's overshoot) and then moves the shape;
/// once the spring is at rest it cuts the frame to the shape, unless a newer change
/// came in meanwhile.
///
/// The shape's spring is stepped here, on the display link of the window's screen,
/// one value per refresh taken at the moment that refresh shows. Left to SwiftUI it
/// was drawn whenever the main run loop woke, on the main screen's clock as well as
/// this one's, so the frames that reached the notch were unevenly spaced in time.
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
        let layout: IslandLayout
        let keepsWindow: Bool
    }
    private var lastRequest: Request?

    /// The shape on its way to the latest presentation, and how to settle once it
    /// is at rest. `nil` while the shape is still.
    private struct Flight {
        var motion: IslandOutlineMotion
        let target: CGRect
        let keepsWindow: Bool
        let generation: Int
    }
    private var flight: Flight?
    /// Steps `flight` on every refresh of the window's screen; there only while it flies.
    private var displayLink: CADisplayLink?

    /// `IslandFrameProbe` only: the window's opacity, set before it first shows, and
    /// with it a click-through panel with no haptics. `nil` in the app.
    var probeAlpha: CGFloat?

    /// Above the menu bar (24) and the status items (25), below menus (101):
    /// a menu opened from the bar still draws over the island. `IslandFullScreen`
    /// reads it too: a window at or above this level is drawn over the island anyway.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    init(actions: IslandActions) {
        self.actions = actions
    }

    /// Shows `layout` around the notch of `geometry`. With `keepsWindow` false
    /// (nothing to show: no track, no Claude session), the panel leaves the screen
    /// once it has folded away.
    func show(_ layout: IslandLayout, on geometry: NotchGeometry, keepsWindow: Bool) {
        let presentation = layout.presentation
        let request = Request(layout: layout, keepsWindow: keepsWindow)
        // A track update that changes nothing the panel draws (the position moved, the
        // cover is the same) only needs the model, which the controller already filled.
        // Bumping the generation here would cancel the pending `settle` every time, and
        // with updates closer than a spring lasts the frame would never shrink back.
        if let window, window.isVisible, self.geometry == geometry, lastRequest == request { return }
        lastRequest = request
        generation += 1
        let mine = generation
        let target = geometry.islandFrame(for: layout)

        guard let window, window.isVisible else {
            // Nothing on screen and nothing to show: stay away (no window either).
            guard keepsWindow || presentation != .hidden else { return }
            let window = self.window ?? makeWindow()
            self.window = window
            self.geometry = geometry
            // Come out of the notch: the hover zone is drawn first, at rest, so the
            // spring has something to grow from instead of showing up already open.
            land()
            withoutAnimation {
                model.notch = geometry.notchRect.size
                model.layout = .empty
                model.outline = IslandOutline(.empty, notch: geometry.notchRect.size)
            }
            place(window, frame: geometry.windowFrame(current: geometry.islandFrame(for: .empty), target: target),
                  on: geometry)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            window.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in
                guard let self, mine == self.generation else { return }
                self.animate(to: layout, settlingAt: target, keepsWindow: keepsWindow, generation: mine)
            }
            return
        }

        if self.geometry != geometry {
            // Another screen layout: jump, nothing to animate from.
            self.geometry = geometry
            land()
            withoutAnimation {
                model.notch = geometry.notchRect.size
                model.layout = layout
                model.outline = IslandOutline(layout, notch: geometry.notchRect.size)
            }
            if !keepsWindow && presentation == .hidden {
                window.orderOut(nil)
            } else {
                place(window, frame: target, on: geometry)
            }
            return
        }

        place(window, frame: geometry.windowFrame(current: window.frame, target: target), on: geometry)
        animate(to: layout, settlingAt: target, keepsWindow: keepsWindow, generation: mine)
    }

    /// Off the screen at once (no notch any more, or the tool stopped).
    func hide() {
        generation += 1
        lastRequest = nil
        land()
        window?.orderOut(nil)
        withoutAnimation {
            model.layout = .empty
            model.outline = IslandOutline(.empty, notch: model.notch)
        }
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
                                         frame: geometry.islandFrame(for: model.layout))
    }

    // MARK: Private

    /// Moves the shape to `layout`'s and cuts the window to `target` once the
    /// spring is at rest, not after a guess: cut early, the frame would clip the
    /// shape while it still moves. The content changes with SwiftUI, on the same
    /// spring, as it always has. The springs go by presentation: switching pages
    /// (expanded to expanded) moves on the opening one.
    private func animate(to layout: IslandLayout, settlingAt target: CGRect,
                         keepsWindow: Bool, generation mine: Int) {
        let presentation = layout.presentation
        let from = model.layout.presentation
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(IslandMotion.animation(from: from, to: presentation, reduceMotion: reduceMotion)) {
            model.layout = layout
        }
        // From wherever the shape is now; a change that interrupts another keeps its
        // speed, so the shape bends towards the new target instead of jumping.
        let now = CACurrentMediaTime()
        let spring = IslandMotion.shapeSpring(from: from, to: presentation, reduceMotion: reduceMotion)
        let goal = IslandOutline(layout, notch: model.notch)
        let motion = flight?.motion.retargeted(to: goal, spring: spring, at: now, keepsSpeed: !reduceMotion)
            ?? IslandOutlineMotion(from: model.outline, velocity: .zero, target: goal, spring: spring, start: now)
        flight = Flight(motion: motion, target: target, keepsWindow: keepsWindow, generation: mine)
        startDisplayLink()
        // The display link can stay away (the window left the screen mid-spring): the
        // shape lands and the frame is cut anyway, or the larger window would keep
        // taking clicks.
        DispatchQueue.main.asyncAfter(deadline: .now() + IslandMotion.settleFallback) { [weak self] in
            guard let self, mine == self.generation else { return }
            self.land()
            self.settle(at: target, keepsWindow: keepsWindow, generation: mine)
        }
        if presentation == .expanded && from != .expanded && probeAlpha == nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// Only for the latest change: `hide`, `close` and every new `show` bump the
    /// generation, so an older spring ending never touches the window.
    private func settle(at target: CGRect, keepsWindow: Bool, generation mine: Int) {
        guard mine == generation, let window, window.isVisible, let geometry else { return }
        if !keepsWindow && model.layout.presentation == .hidden {
            window.orderOut(nil)
        } else {
            place(window, frame: target, on: geometry)
        }
    }

    // MARK: The shape's spring

    /// One refresh: the outline as it will be when this frame shows, written with no
    /// SwiftUI animation. At rest, it lands on the target and the window is cut.
    fileprivate func step(_ link: CADisplayLink) {
        guard let flight else { return stopDisplayLink() }
        let time = link.targetTimestamp
        let atRest = flight.motion.isSettled(at: time)
        let outline = atRest ? flight.motion.target : flight.motion.value(at: time)
        withoutAnimation { model.outline = outline }
        guard atRest else { return }
        self.flight = nil
        stopDisplayLink()
        settle(at: flight.target, keepsWindow: flight.keepsWindow, generation: flight.generation)
    }

    /// The shape at its target at once, and no more stepping.
    private func land() {
        if let flight { withoutAnimation { model.outline = flight.motion.target } }
        flight = nil
        stopDisplayLink()
    }

    private func startDisplayLink() {
        guard displayLink == nil, let hosting else { return }
        let link = hosting.displayLink(target: IslandOutlineStepper(panel: self),
                                       selector: #selector(IslandOutlineStepper.step(_:)))
        // Every refresh the screen can make: a ProMotion screen would otherwise pick a
        // lower rate on its own.
        let top = Float(hosting.window?.screen?.maximumFramesPerSecond ?? 120)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: top, maximum: top, preferred: top)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: The window

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
        if let probeAlpha {
            window.alphaValue = probeAlpha
            window.ignoresMouseEvents = true
        }

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

/// The display link's target. A link keeps its target, so this one holds the panel
/// weakly: the link never keeps the panel alive, and stops itself if it is gone.
private final class IslandOutlineStepper: NSObject {
    weak var panel: IslandPanel?

    init(panel: IslandPanel) {
        self.panel = panel
    }

    @objc func step(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            guard let panel else { return link.invalidate() }
            panel.step(link)
        }
    }
}

private struct IslandRootView: View {
    let model: IslandViewModel
    let actions: IslandActions

    var body: some View {
        IslandView(layout: model.layout, notch: model.notch, track: model.track,
                   artwork: model.artwork, appName: model.appName, claude: model.claude,
                   actions: actions, outline: model.outline)
            .ignoresSafeArea()
    }
}
