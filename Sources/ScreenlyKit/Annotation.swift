import SwiftUI

// MARK: - Tools

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, ellipse, line, freehand, highlighter, text
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .freehand: return "scribble.variable"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        }
    }

    var label: String {
        switch self {
        case .select: return "Selecionar"
        case .arrow: return "Seta"
        case .rectangle: return "Retângulo"
        case .ellipse: return "Círculo"
        case .line: return "Linha"
        case .freehand: return "Caneta"
        case .highlighter: return "Marcador"
        case .text: return "Texto"
        }
    }

    var isDrawing: Bool { self != .select }
}

// MARK: - Shape

/// One annotation. `points` holds the defining geometry: two points for
/// rect/ellipse/line/arrow, one for text, many for freehand/highlighter.
struct AnnotationShape: Identifiable, Equatable {
    let id = UUID()
    var tool: AnnotationTool
    var colorHex: String
    var lineWidth: CGFloat
    var points: [CGPoint]
    var text: String = ""
    var filled: Bool = false   // solid fill for rect/ellipse (covering content)

    var color: Color { Color(hex: colorHex) }

    var a: CGPoint { points.first ?? .zero }
    var b: CGPoint { points.last ?? .zero }

    var boundingRect: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Padded box for hit-testing / selection outline.
    var hitBox: CGRect {
        let pad = max(10, lineWidth + 6)
        if tool == .text {
            let fontSize = max(12, lineWidth * 3)
            let w = max(CGFloat(text.count) * fontSize * 0.6, 20)
            return CGRect(x: a.x - 4, y: a.y - 4, width: w + 8, height: fontSize + 10)
        }
        return boundingRect.insetBy(dx: -pad, dy: -pad)
    }

    mutating func translate(by d: CGSize) {
        points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
    }
}

// MARK: - Model

/// Holds the annotation state for one capture: the shapes, the active tool,
/// colour and width, plus selection and a simple undo stack.
final class AnnotationModel: ObservableObject {
    @Published var shapes: [AnnotationShape] = []
    @Published var live: AnnotationShape?          // shape being drawn right now
    @Published var tool: AnnotationTool = .arrow
    @Published var colorHex: String = "#FF3B30"    // red
    @Published var lineWidth: CGFloat = 6
    @Published var filled: Bool = false            // fill new rectangles / ellipses
    @Published var selectedID: UUID?
    @Published var editingTextID: UUID?
    /// True while the screen eyedropper is up. The region overlay drops its dimming
    /// and toolbar meanwhile, so the sampler reads the screen's real colours instead
    /// of our darkened composite.
    @Published var isSampling: Bool = false

    private var undoStack: [[AnnotationShape]] = []

    var canUndo: Bool { !undoStack.isEmpty }

    // MARK: Drawing lifecycle (driven by the drag gesture)

    func beginDraw(at p: CGPoint) {
        guard tool.isDrawing, tool != .text else { return }
        let fill = filled && (tool == .rectangle || tool == .ellipse)
        live = AnnotationShape(tool: tool, colorHex: colorHex, lineWidth: lineWidth,
                               points: [p, p], filled: fill)
    }

    func updateDraw(to p: CGPoint) {
        guard var s = live else { return }
        if s.tool == .freehand || s.tool == .highlighter {
            s.points.append(p)
        } else {
            s.points = [s.points.first ?? p, p]
        }
        live = s
    }

    func endDraw() {
        guard let s = live else { return }
        live = nil
        // Ignore accidental taps that produced no real shape.
        if s.tool != .text, s.boundingRect.width < 3, s.boundingRect.height < 3 { return }
        pushUndo()
        shapes.append(s)
    }

    // MARK: Text

    func addText(at p: CGPoint) {
        pushUndo()
        let s = AnnotationShape(tool: .text, colorHex: colorHex, lineWidth: lineWidth, points: [p], text: "")
        shapes.append(s)
        selectedID = s.id
        editingTextID = s.id
    }

    func setText(_ text: String, for id: UUID) {
        guard let idx = shapes.firstIndex(where: { $0.id == id }) else { return }
        shapes[idx].text = text
    }

    func endTextEditing() {
        // Drop empty text boxes.
        if let id = editingTextID, let s = shapes.first(where: { $0.id == id }),
           s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            shapes.removeAll { $0.id == id }
        }
        editingTextID = nil
    }

    // MARK: Selection editing

    func selectShape(at p: CGPoint) {
        selectedID = shapes.last(where: { $0.hitBox.contains(p) })?.id
    }

    func moveSelected(by d: CGSize) {
        guard let id = selectedID, let idx = shapes.firstIndex(where: { $0.id == id }) else { return }
        shapes[idx].translate(by: d)
    }

    func recolorSelected(_ hex: String) {
        guard let id = selectedID, let idx = shapes.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        shapes[idx].colorHex = hex
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        pushUndo()
        shapes.removeAll { $0.id == id }
        selectedID = nil
        editingTextID = nil
    }

    // MARK: Undo

    func pushUndo() {
        undoStack.append(shapes)
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        shapes = last
        selectedID = nil
        editingTextID = nil
    }
}

// MARK: - Shapes canvas (shared by the live overlay and the exported image)

/// Renders a set of annotation shapes. Used both in the interactive editor and,
/// via `ImageRenderer`, in the exported PNG — so what you draw is what you get.
struct ShapesCanvas: View {
    let shapes: [AnnotationShape]
    var live: AnnotationShape? = nil
    var selectedID: UUID? = nil
    var editingTextID: UUID? = nil

    var body: some View {
        Canvas { ctx, _ in
            for s in shapes where s.id != editingTextID {
                draw(s, in: &ctx)
                if s.id == selectedID { drawSelection(s, in: &ctx) }
            }
            if let live { draw(live, in: &ctx) }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ s: AnnotationShape, in ctx: inout GraphicsContext) {
        let color = s.color
        switch s.tool {
        case .rectangle:
            let path = Path(roundedRect: s.boundingRect, cornerRadius: 3)
            if s.filled { ctx.fill(path, with: .color(color)) }
            else { ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: s.lineWidth, lineJoin: .round)) }
        case .ellipse:
            let path = Path(ellipseIn: s.boundingRect)
            if s.filled { ctx.fill(path, with: .color(color)) }
            else { ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: s.lineWidth)) }
        case .line:
            var p = Path(); p.move(to: s.a); p.addLine(to: s.b)
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: s.lineWidth, lineCap: .round))
        case .arrow:
            drawArrow(from: s.a, to: s.b, color: color, width: s.lineWidth, in: &ctx)
        case .freehand:
            ctx.stroke(path(through: s.points), with: .color(color),
                       style: StrokeStyle(lineWidth: s.lineWidth, lineCap: .round, lineJoin: .round))
        case .highlighter:
            ctx.stroke(path(through: s.points), with: .color(color.opacity(0.35)),
                       style: StrokeStyle(lineWidth: s.lineWidth * 2.4, lineCap: .round, lineJoin: .round))
        case .text:
            let fontSize = max(12, s.lineWidth * 3)
            let resolved = ctx.resolve(
                Text(s.text.isEmpty ? " " : s.text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(color))
            ctx.draw(resolved, at: s.a, anchor: .topLeading)
        case .select:
            break
        }
    }

    private func drawSelection(_ s: AnnotationShape, in ctx: inout GraphicsContext) {
        let box = s.hitBox
        ctx.stroke(Path(roundedRect: box, cornerRadius: 4),
                   with: .color(.white.opacity(0.9)),
                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    private func path(through pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        return p
    }

    private func drawArrow(from a: CGPoint, to b: CGPoint, color: Color, width: CGFloat, in ctx: inout GraphicsContext) {
        var shaft = Path(); shaft.move(to: a); shaft.addLine(to: b)
        ctx.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))

        let angle = atan2(b.y - a.y, b.x - a.x)
        let head = max(14, width * 3)
        let spread = CGFloat.pi / 7
        let p1 = CGPoint(x: b.x - head * cos(angle - spread), y: b.y - head * sin(angle - spread))
        let p2 = CGPoint(x: b.x - head * cos(angle + spread), y: b.y - head * sin(angle + spread))
        var headPath = Path()
        headPath.move(to: b); headPath.addLine(to: p1)
        headPath.move(to: b); headPath.addLine(to: p2)
        ctx.stroke(headPath, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - Colour helpers

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255;  a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255;         a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// The preset annotation colours shown in the toolbar. Deliberately just the
/// essentials — anything else is one click away via the toolbar's eyedropper
/// (pick straight off the screen) or the colour wheel, which keeps the floating
/// toolbar small.
enum AnnotationPalette {
    static let colors: [String] = [
        "#FF3B30", // red
        "#34C759", // green
        "#007AFF", // blue
        "#FFFFFF", // white
        "#000000", // black
    ]
}
