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
/// frame first and then animates the shape; to shrink it animates the shape and
/// then cuts the frame, unless a newer change came in meanwhile.
@MainActor
final class IslandPanel {
    let model = IslandViewModel()
    private let actions: IslandActions
    private var window: IslandWindow?
    private var geometry: NotchGeometry?
    /// Bumped on every change: a delayed resize from an older one is dropped.
    private var generation = 0

    /// What the last `show` asked for.
    private struct Request: Equatable {
        let presentation: IslandPresentation
        let keepsWindow: Bool
    }
    private var lastRequest: Request?

    /// Long enough for the spring to look settled before the frame is cut.
    static let settle: TimeInterval = 0.5

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
        // with updates closer than `settle` apart the frame would never shrink back.
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
            // Come out of the notch: start at the hover zone's size, then grow.
            withoutAnimation {
                model.notch = geometry.notchRect.size
                model.presentation = .hidden
            }
            window.setFrame(geometry.islandFrame(for: .hidden).union(target), display: false)
            window.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in
                guard let self, mine == self.generation else { return }
                self.animate(to: presentation)
                self.settle(at: target, keepsWindow: keepsWindow, generation: mine)
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
                window.setFrame(target, display: true)
            }
            return
        }

        let union = window.frame.union(target)
        if union != window.frame { window.setFrame(union, display: true) }
        animate(to: presentation)
        settle(at: target, keepsWindow: keepsWindow, generation: mine)
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

    private func animate(to presentation: IslandPresentation) {
        let opens = presentation == .expanded && model.presentation != .expanded
        withAnimation(Self.animation) { model.presentation = presentation }
        if opens { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    private func settle(at target: CGRect, keepsWindow: Bool, generation mine: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            guard let self, mine == self.generation, let window = self.window else { return }
            if !keepsWindow && self.model.presentation == .hidden {
                window.orderOut(nil)
            } else if window.frame != target {
                window.setFrame(target, display: true)
            }
        }
    }

    private static var animation: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.38, dampingFraction: 0.8)
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
        // The panel sizes the window; the view must not push its own size on it.
        hosting.sizingOptions = []
        window.contentView = hosting
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
