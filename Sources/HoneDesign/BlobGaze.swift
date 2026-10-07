import AppKit
import SwiftUI

/// Where the pointer is, in the coordinates of the root view that owns it
/// (top-left origin). Every `Blob` below that root reads it to turn its eyes.
@MainActor
@Observable
public final class PointerGaze {
    /// Name of the coordinate space a root defines and the blobs measure in.
    public static let space = "honePointerGaze"

    public private(set) var pointer: CGPoint?

    public init(pointer: CGPoint? = nil) {
        self.pointer = pointer
    }

    /// Ignores sub-point moves so a still pointer never redraws the blobs.
    func update(_ new: CGPoint?) {
        if let new, let old = pointer, hypot(new.x - old.x, new.y - old.y) < 1 { return }
        pointer = new
    }
}

/// The eye maths, apart from the views so it can be tested.
public enum BlobGaze {
    /// Body heights from the blob at which the eyes reach their full travel.
    static let saturation: CGFloat = 2.5

    /// How far the eyes slide toward `pointer`, at most `reach` on each axis.
    /// Eased so a pointer right next to the blob already turns the eyes.
    public static func shift(toward pointer: CGPoint, from center: CGPoint,
                             height: CGFloat, reach: CGSize) -> CGSize {
        let dx = pointer.x - center.x
        let dy = pointer.y - center.y
        let distance = hypot(dx, dy)
        guard distance > 0.5, height > 0 else { return .zero }
        let k = min(distance / (height * saturation), 1)
        let eased = k * (2 - k)
        return CGSize(width: quantized(dx / distance * reach.width * eased),
                      height: quantized(dy / distance * reach.height * eased))
    }

    /// Quarter-point steps: finer than the eye can show, and it stops a
    /// wobbling pointer from restarting the eye animation every tick.
    private static func quantized(_ value: CGFloat) -> CGFloat {
        (value * 4).rounded() / 4
    }
}

public extension View {
    /// Put this on the root of a window or popover: the eyes of every `Blob`
    /// inside follow the pointer, wherever it is on screen. Reads the position
    /// from the system, so no event tap and no permission.
    @MainActor
    func blobsFollowPointer() -> some View {
        modifier(FollowPointer())
    }

    /// A fixed pointer position (in this view's own coordinates) for previews.
    @MainActor
    func blobsLookAt(_ point: CGPoint) -> some View {
        coordinateSpace(.named(PointerGaze.space))
            .environment(PointerGaze(pointer: point))
    }
}

private struct FollowPointer: ViewModifier {
    @State private var gaze = PointerGaze()

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(PointerGaze.space))
            .background(PointerProbe(gaze: gaze))
            .environment(gaze)
    }
}

/// An invisible view that reads the pointer for its window while it's on
/// screen (about 30 times a second) and stops while it isn't.
private struct PointerProbe: NSViewRepresentable {
    let gaze: PointerGaze

    func makeNSView(context: Context) -> ProbeView { ProbeView(gaze: gaze) }
    func updateNSView(_ view: ProbeView, context: Context) {}
}

private final class ProbeView: NSView {
    private let gaze: PointerGaze
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(gaze: PointerGaze) {
        self.gaze = gaze
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        stop()
        guard let window else { return }
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                          NSWindow.willCloseNotification,
                                          NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private var isOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func refresh() {
        if isOnScreen { start() } else { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        tick()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isOnScreen else {
                    timer.invalidate()
                    self?.timer = nil
                    return
                }
                self.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let window else { return }
        // Works while the window isn't key, and for a pointer outside it.
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        gaze.update(CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y))
    }
}
