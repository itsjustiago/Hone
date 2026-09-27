import SwiftUI
import AppKit

/// Editor window for window / full-screen captures: shows the captured image and
/// lets you annotate before copying or saving. Reuses `ShapesCanvas` + toolbar.
@MainActor
final class AnnotationEditorController: NSObject, NSWindowDelegate {
    private let store: CaptureStore
    private let preview = CapturePreview()
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var image: NSImage?
    private var displayed: CGSize = .zero
    private let model = AnnotationModel()

    init(store: CaptureStore) { self.store = store; super.init() }

    func open(image: NSImage, mode: CaptureMode) {
        close()
        self.image = image
        self.displayed = Self.displayedSize(for: image)
        model.shapes = []
        model.tool = .arrow
        model.selectedID = nil

        let view = AnnotationEditorView(
            image: image, displayed: displayed, model: model,
            onCopy: { [weak self] in self?.export(toClipboard: true) },
            onSave: { [weak self] in self?.export(toClipboard: false) },
            onCancel: { [weak self] in self?.close() })

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: displayed.width, height: displayed.height + 58),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Editar captura — Screenly"
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        w.contentView = NSHostingView(rootView: view)
        window = w

        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    // MARK: Export

    private func export(toClipboard: Bool) {
        guard let image, let cg = render(image: image, shapes: model.shapes) else { close(); return }
        let ext = CaptureSettings.format
        guard let data = imageData(cg, ext: ext) else { close(); return }

        var savedURL: URL?
        if toClipboard {
            if let img = NSImage(data: data) { CaptureOutput.copyToClipboard(img) }
        } else {
            savedURL = CaptureOutput.saveToFolder(data, ext: ext)
        }
        let internalURL = store.add(data: data, ext: ext, mode: .screen, savedPath: savedURL?.path)
        if CaptureSettings.showPreview, let url = savedURL ?? internalURL, let img = NSImage(contentsOf: url) {
            preview.show(image: img, reveal: savedURL ?? internalURL)
        }
        close()
    }

    private func render(image: NSImage, shapes: [AnnotationShape]) -> CGImage? {
        let content = ZStack(alignment: .topLeading) {
            Image(nsImage: image).resizable().frame(width: displayed.width, height: displayed.height)
            ShapesCanvas(shapes: shapes).frame(width: displayed.width, height: displayed.height)
        }
        .frame(width: displayed.width, height: displayed.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.pixelWidth(image) / displayed.width
        return renderer.cgImage
    }

    private func imageData(_ cg: CGImage, ext: String) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cg)
        if ext == "jpg" { return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.model.editingTextID != nil {
                if event.keyCode == 53 { self.model.endTextEditing(); return nil }
                return event
            }
            let cmd = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case 53: self.close(); return nil
            case 51, 117: self.model.deleteSelected(); return nil
            default: break
            }
            if cmd, let c = event.charactersIgnoringModifiers?.lowercased() {
                switch c {
                case "z": self.model.undo(); return nil
                case "c": self.export(toClipboard: true); return nil
                case "s": self.export(toClipboard: false); return nil
                default: break
                }
            }
            return event
        }
    }

    func close() {
        ColorPanelController.shared.dismiss()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.orderOut(nil)
        window?.delegate = nil
        window = nil
        image = nil
        model.shapes = []
    }

    /// Closes the editor and the floating preview it may have left behind.
    func tearDown() {
        close()
        preview.dismiss(animated: false)
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window = nil
        image = nil
    }

    // MARK: Sizing

    private static func pixelWidth(_ image: NSImage) -> CGFloat {
        CGFloat(image.representations.first?.pixelsWide ?? Int(image.size.width))
    }

    private static func displayedSize(for image: NSImage) -> CGSize {
        let pxW = CGFloat(image.representations.first?.pixelsWide ?? Int(image.size.width))
        let pxH = CGFloat(image.representations.first?.pixelsHigh ?? Int(image.size.height))
        guard pxW > 0, pxH > 0 else { return CGSize(width: 640, height: 420) }
        let maxW: CGFloat = 1000, maxH: CGFloat = 660
        let scale = min(maxW / pxW, maxH / pxH, 1)
        return CGSize(width: floor(pxW * scale), height: floor(pxH * scale))
    }
}

struct AnnotationEditorView: View {
    let image: NSImage
    let displayed: CGSize
    @ObservedObject var model: AnnotationModel
    var onCopy: () -> Void
    var onSave: () -> Void
    var onCancel: () -> Void

    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: displayed.width, height: displayed.height)

                ShapesCanvas(shapes: model.shapes, live: model.live,
                             selectedID: model.selectedID, editingTextID: model.editingTextID)
                    .frame(width: displayed.width, height: displayed.height)

                editingText

                Color.white.opacity(0.001)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { changed($0) }
                        .onEnded { ended($0) })
            }
            .frame(width: displayed.width, height: displayed.height)
            .clipped()

            AnnotationToolbar(model: model, onCopy: onCopy, onSave: onSave, onCancel: onCancel)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .frame(width: displayed.width, height: displayed.height + 58)
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

    private func changed(_ v: DragGesture.Value) {
        guard model.tool.isDrawing, model.tool != .text else { return }
        // `model.live` (reference-typed) is the source of truth for "a stroke is in
        // progress" — reliable to read back mid-gesture, unlike a local @State flag.
        if model.live == nil {
            if model.editingTextID != nil { model.endTextEditing() }
            model.beginDraw(at: v.startLocation)
        }
        model.updateDraw(to: v.location)
    }

    private func ended(_ v: DragGesture.Value) {
        if model.live != nil { model.endDraw(); return }
        switch model.tool {
        case .text: model.addText(at: v.location)
        case .select: model.selectShape(at: v.location)
        default: break
        }
    }
}
