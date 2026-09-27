import SwiftUI
import AppKit
import ScreenCaptureKit

// MARK: - Screen freeze

struct FrozenScreen {
    let image: NSImage
    let frame: CGRect
    let scale: CGFloat
}

/// Captures a still of the display under the cursor via ScreenCaptureKit, so the
/// selection + annotation happen over a frozen image (nothing shifts underneath).
enum ScreenFreezer {
    static func capture(completion: @escaping (FrozenScreen?) -> Void) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen,
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            completion(nil); return
        }
        // Extract Sendable value types up front — don't capture the NSScreen.
        let displayID = CGDirectDisplayID(num.uint32Value)
        let scale = screen.backingScaleFactor
        let frame = screen.frame

        Task {
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    await MainActor.run { completion(nil) }; return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = Int(frame.width * scale)
                config.height = Int(frame.height * scale)
                config.showsCursor = false
                let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let image = NSImage(cgImage: cg, size: frame.size)
                await MainActor.run { completion(FrozenScreen(image: image, frame: frame, scale: scale)) }
            } catch {
                NSLog("Screenly: screen freeze failed: \(error.localizedDescription)")
                await MainActor.run { completion(nil) }
            }
        }
    }
}

// MARK: - Shared selection state (view ↔ controller)

final class SelectionState: ObservableObject {
    @Published var rect: CGRect?
}

/// Borderless panel that can still become key so it receives Esc / ⌘-shortcuts.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Controller

/// Drives the region capture: freeze → selection + annotation overlay → export.
@MainActor
final class SelectionOverlayController: NSObject {
    private let store: CaptureStore
    private let preview = CapturePreview()
    private let fallback: (CaptureMode) -> Void

    private(set) var panel: OverlayPanel?
    private var keyMonitor: Any?
    private var frozen: FrozenScreen?
    private var isPreparing = false
    private let selection = SelectionState()
    private let model = AnnotationModel()

    /// `fallback` runs a plain non-editor capture if the freeze isn't available.
    init(store: CaptureStore, fallback: @escaping (CaptureMode) -> Void) {
        self.store = store
        self.fallback = fallback
    }

    func begin() {
        // A previous overlay may still exist: re-front it if it's really on screen,
        // tear it down if it was hidden behind our back — never ignore the request.
        if reclaimExistingSession() { return }
        // Guard against re-entrancy *synchronously*: the freeze below is async, and
        // `panel` isn't set until it returns. Without this, hammering the hotkey
        // while the freeze runs would spin up a second overlay that gets orphaned
        // at shield level — blocking clicks and swallowing the next capture.
        guard !isPreparing else { return }
        isPreparing = true

        var settled = false
        let finish: (FrozenScreen?) -> Void = { [weak self] frozen in
            guard let self, self.isPreparing, !settled else { return }
            settled = true
            self.isPreparing = false
            if let frozen { self.present(frozen) } else { self.fallback(.region) }
        }
        ScreenFreezer.capture { finish($0) }
        // Safety net: if ScreenCaptureKit never calls back, don't wedge forever —
        // fall back to the native picker so a capture still happens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { finish(nil) }
    }

    /// Handles a capture request that arrives while `panel` is still set. Returns
    /// true when a live overlay took the event (re-keyed so Esc/⌘C work again even
    /// if the app lost activation mid-session). A panel that is no longer visible
    /// was ordered out without `close()` — historically AppKit itself did this on
    /// app deactivation, via NSPanel's `hidesOnDeactivate` default — and used to
    /// wedge every future capture; now it's torn down so a fresh session can start.
    func reclaimExistingSession() -> Bool {
        guard let existing = panel else { return false }
        guard existing.isVisible else {
            close()
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        existing.makeKeyAndOrderFront(nil)
        return true
    }

    private func present(_ frozen: FrozenScreen) {
        self.frozen = frozen
        model.shapes = []
        model.tool = .select
        selection.rect = nil

        let panel = Self.makeShieldPanel(frame: frozen.frame)

        let view = SelectionOverlayView(
            frozen: frozen, model: model, selection: selection,
            onExport: { [weak self] rect, toClipboard in self?.export(rect, toClipboard: toClipboard) },
            onCancel: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: frozen.frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel

        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    /// The shield-level panel that hosts the frozen screen. `hidesOnDeactivate`
    /// must stay false: NSPanel's default (true) let AppKit order the overlay out
    /// on app deactivation without going through `close()`, leaving `panel` set
    /// and silently swallowing every subsequent capture until relaunch.
    static func makeShieldPanel(frame: CGRect) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: frame,
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.setFrame(frame, display: true)
        return panel
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let cmd = event.modifierFlags.contains(.command)
            // While editing a text box, let all keys reach the field (except Esc).
            if self.model.editingTextID != nil {
                if event.keyCode == 53 { self.model.endTextEditing(); return nil }  // Esc ends editing
                return event
            }
            switch event.keyCode {
            case 53: self.close(); return nil                                        // Esc
            case 51, 117:                                                            // Delete / Fwd-delete
                self.model.deleteSelected(); return nil
            default: break
            }
            if cmd, let c = event.charactersIgnoringModifiers?.lowercased() {
                switch c {
                case "z": self.model.undo(); return nil
                case "c": if let r = self.selection.rect { self.export(r, toClipboard: true) }; return nil
                case "s": if let r = self.selection.rect { self.export(r, toClipboard: false) }; return nil
                default: break
                }
            }
            return event
        }
    }

    // MARK: Export

    private func export(_ rect: CGRect, toClipboard: Bool) {
        guard let frozen, rect.width > 2, rect.height > 2,
              let cg = render(frozen: frozen, shapes: model.shapes, selection: rect) else { close(); return }
        let ext = CaptureSettings.format
        guard let data = imageData(cg, ext: ext) else { close(); return }

        var savedURL: URL?
        if toClipboard {
            if let img = NSImage(data: data) { CaptureOutput.copyToClipboard(img) }
        } else {
            savedURL = CaptureOutput.saveToFolder(data, ext: ext)
        }
        let internalURL = store.add(data: data, ext: ext, mode: .region, savedPath: savedURL?.path)
        if CaptureSettings.showPreview, let url = savedURL ?? internalURL, let img = NSImage(contentsOf: url) {
            preview.show(image: img, reveal: savedURL ?? internalURL)
        }
        close()
    }

    /// Render the frozen image + annotations and crop to the selection, at full
    /// pixel resolution. WYSIWYG: same `ShapesCanvas` as the live overlay.
    private func render(frozen: FrozenScreen, shapes: [AnnotationShape], selection: CGRect) -> CGImage? {
        let w = frozen.frame.width, h = frozen.frame.height
        let content = ZStack(alignment: .topLeading) {
            Image(nsImage: frozen.image).resizable().frame(width: w, height: h)
            ShapesCanvas(shapes: shapes).frame(width: w, height: h)
        }
        .frame(width: w, height: h)

        let renderer = ImageRenderer(content: content)
        renderer.scale = frozen.scale
        guard let full = renderer.cgImage else { return nil }
        let s = frozen.scale
        let crop = CGRect(x: selection.minX * s, y: selection.minY * s,
                          width: selection.width * s, height: selection.height * s).integral
        return full.cropping(to: crop)
    }

    private func imageData(_ cg: CGImage, ext: String) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cg)
        if ext == "jpg" { return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) }
        return rep.representation(using: .png, properties: [:])
    }

    func close() {
        ColorPanelController.shared.dismiss()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        frozen = nil
        isPreparing = false
        model.shapes = []
        selection.rect = nil
        NSCursor.arrow.set()
    }

    /// Closes any live session and the floating preview it may have left behind.
    func tearDown() {
        close()
        preview.dismiss(animated: false)
    }
}

// MARK: - View

struct SelectionOverlayView: View {
    let frozen: FrozenScreen
    @ObservedObject var model: AnnotationModel
    @ObservedObject var selection: SelectionState
    var onExport: (CGRect, Bool) -> Void
    var onCancel: () -> Void

    @State private var session = DragSession()
    /// Measured size of the floating toolbar. Seeded with a close estimate of the
    /// stacked card so the very first frame is already clamped sensibly (the real
    /// size lands on the next layout pass).
    @State private var toolbarSize = CGSize(width: 360, height: 150)
    @FocusState private var textFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let bounds = geo.size
            ZStack(alignment: .topLeading) {
                Image(nsImage: frozen.image)
                    .resizable()
                    .frame(width: bounds.width, height: bounds.height)

                dimLayer(bounds)

                ShapesCanvas(shapes: model.shapes, live: model.live,
                             selectedID: model.selectedID, editingTextID: model.editingTextID)
                    .frame(width: bounds.width, height: bounds.height)
                    .mask(alignment: .topLeading) { maskRect }

                chromeLayer

                editingText

                // Gesture surface (below the toolbar so its buttons keep working).
                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { changed($0, bounds: bounds) }
                        .onEnded { ended($0, bounds: bounds) })
                    .onContinuousHover { phase in updateCursor(phase) }

                if let rect = selection.rect, rect.width > 8, rect.height > 8 {
                    toolbar(rect: rect, bounds: bounds)
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Layers

    private func dimLayer(_ bounds: CGSize) -> some View {
        Canvas { ctx, size in
            var p = Path(CGRect(origin: .zero, size: size))
            if let r = selection.rect { p.addRect(r) }
            ctx.fill(p, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
        // While the eyedropper is up, show the frozen screen untouched so the
        // sampler reads real colours rather than our darkened composite.
        .opacity(model.isSampling ? 0 : 1)
    }

    @ViewBuilder private var maskRect: some View {
        if let r = selection.rect {
            Rectangle().frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
        } else {
            Color.clear
        }
    }

    private var chromeLayer: some View {
        Canvas { ctx, _ in
            guard let r = selection.rect else { return }
            ctx.stroke(Path(r), with: .color(Brand.tint), style: StrokeStyle(lineWidth: 1.5))
            if model.tool == .select {
                for p in SelectionGeometry.handlePoints(r) {
                    let box = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                    ctx.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(.white))
                    ctx.stroke(Path(roundedRect: box, cornerRadius: 2), with: .color(Brand.tint), style: StrokeStyle(lineWidth: 1))
                }
            }
            // Dimension label
            let label = "\(Int(r.width)) × \(Int(r.height))"
            let resolved = ctx.resolve(Text(label).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(.white))
            let ls = resolved.measure(in: CGSize(width: 200, height: 40))
            let lx = min(max(r.minX, 4), r.maxX)
            let ly = max(r.minY - ls.height - 6, 4)
            let bg = CGRect(x: lx, y: ly, width: ls.width + 12, height: ls.height + 6)
            ctx.fill(Path(roundedRect: bg, cornerRadius: 5), with: .color(.black.opacity(0.6)))
            ctx.draw(resolved, at: CGPoint(x: bg.midX, y: bg.midY), anchor: .center)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var editingText: some View {
        if let id = model.editingTextID, let shape = model.shapes.first(where: { $0.id == id }) {
            let fontSize = max(12, shape.lineWidth * 3)
            TextField("Texto", text: Binding(
                get: { shape.text },
                set: { model.setText($0, for: id) }))
                .textFieldStyle(.plain)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(shape.color)
                .frame(width: 260, alignment: .leading)
                .position(x: shape.a.x + 130, y: shape.a.y + fontSize * 0.6)
                .focused($textFocused)
                .onSubmit { model.endTextEditing() }
                .onAppear { textFocused = true }
        }
    }

    /// Floats the multi-row toolbar near the selection, but **always fully on
    /// screen**: it's measured (`toolbarSize`) and its centre is clamped to the
    /// bounds with a margin. Prefers just below the selection, flips above when it
    /// wouldn't fit, and pins inside the bottom edge as a last resort.
    private func toolbar(rect: CGRect, bounds: CGSize) -> some View {
        let center = SelectionGeometry.toolbarCenter(
            selection: rect, bounds: bounds, toolbarSize: toolbarSize)
        return AnnotationToolbar(
            model: model,
            onCopy: { onExport(rect, true) },
            onSave: { onExport(rect, false) },
            onCancel: onCancel,
            elevatedColorPanel: true,
            layout: .stacked)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if size != .zero, size != toolbarSize { toolbarSize = size }
            }
            // Get out of the way of the eyedropper so any pixel is reachable.
            .opacity(model.isSampling ? 0 : 1)
            .position(x: center.x, y: center.y)
    }

    // MARK: Gesture

    /// Handles get a generous touch target; the interior needs a little slack too
    /// so a press right on the edge still grabs to move.
    private let handleTolerance: CGFloat = 14
    private let moveInset: CGFloat = 6

    private func changed(_ v: DragGesture.Value, bounds: CGSize) {
        if session.mode == .none { beginDrag(at: v.startLocation) }
        switch session.mode {
        case .newSelection:
            selection.rect = SelectionGeometry.normalized(
                from: v.startLocation, to: SelectionGeometry.clampPoint(v.location, in: bounds))
        case .move:
            selection.rect = SelectionGeometry.clampRect(
                session.anchor.offsetBy(dx: v.translation.width, dy: v.translation.height), in: bounds)
        case .resize(let h):
            selection.rect = SelectionGeometry.resize(session.anchor, handle: h, by: v.translation, in: bounds)
        case .draw:
            model.updateDraw(to: SelectionGeometry.clampPoint(v.location, in: bounds))
        case .none, .text, .ignore:
            break
        }
    }

    private func ended(_ v: DragGesture.Value, bounds: CGSize) {
        let moved = abs(v.translation.width) >= 3 || abs(v.translation.height) >= 3
        switch session.mode {
        case .draw:
            model.endDraw()
        case .text:
            if let r = selection.rect, r.contains(v.location) { model.addText(at: v.location) }
        case .move:
            // A tap (no real drag) inside the selection = pick a shape to edit.
            if moved { if let r = selection.rect { selection.rect = r.standardized } }
            else { model.selectShape(at: v.startLocation) }
        case .resize:
            if let r = selection.rect { selection.rect = r.standardized }
        case .newSelection:
            model.selectedID = nil
            // A real drag makes a new selection; a stray click keeps the old one
            // (or clears it if there was none) instead of collapsing it to nothing.
            if moved, let r = selection.rect, r.width >= 4, r.height >= 4 {
                selection.rect = r.standardized
            } else {
                selection.rect = session.previousSelection
            }
        case .none, .ignore:
            break
        }
        session.reset()
    }

    private func beginDrag(at p: CGPoint) {
        if model.editingTextID != nil { model.endTextEditing() }
        let intent = SelectionGeometry.dragIntent(
            at: p, selection: selection.rect, tool: model.tool,
            handleTolerance: handleTolerance, moveInset: moveInset)
        session.mode = intent
        switch intent {
        case .newSelection:
            session.previousSelection = selection.rect
            selection.rect = CGRect(origin: p, size: .zero)
        case .move, .resize:
            session.anchor = selection.rect ?? .zero
        case .draw:
            model.beginDraw(at: p)
        case .none, .text, .ignore:
            break
        }
    }

    // MARK: Cursor

    /// Give a visual hint of what a press will do: move hand inside the selection,
    /// resize arrows on the handles, crosshair when drawing a new region.
    private func updateCursor(_ phase: HoverPhase) {
        guard case .active(let p) = phase else { NSCursor.arrow.set(); return }
        guard let r = selection.rect, r.width > 0, r.height > 0 else {
            NSCursor.crosshair.set(); return   // no selection yet → drawing a new region
        }
        if model.tool == .select {
            if let h = SelectionGeometry.handle(at: p, of: r, tolerance: handleTolerance) {
                cursor(for: h).set()
            } else if r.insetBy(dx: -moveInset, dy: -moveInset).contains(p) {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
        } else {
            (r.insetBy(dx: -2, dy: -2).contains(p) ? NSCursor.crosshair : NSCursor.arrow).set()
        }
    }

    private func cursor(for handle: SelectionHandle) -> NSCursor {
        switch handle {
        case .l, .r: return .resizeLeftRight
        case .t, .b: return .resizeUpDown
        case .tl, .br, .tr, .bl: return .crosshair   // no public diagonal cursor
        }
    }
}
