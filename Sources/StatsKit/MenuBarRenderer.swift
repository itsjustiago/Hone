import AppKit

/// How alarming a value looks when "colour by load" is on.
enum LoadTone: Hashable {
    case normal, warning, critical

    /// CPU, GPU and fans: orange from 60 %, red from 85 %.
    static func forLoad(_ fraction: Double) -> LoadTone {
        fraction >= 0.85 ? .critical : fraction >= 0.60 ? .warning : .normal
    }

    /// Chip temperature in °C: orange from 85, red from 95.
    static func forTemperature(_ celsius: Double) -> LoadTone {
        celsius >= 95 ? .critical : celsius >= 85 ? .warning : .normal
    }

    /// Memory follows the system's own pressure level instead of the used share.
    static func forPressure(_ pressure: MemoryPressure) -> LoadTone {
        switch pressure {
        case .normal: return .normal
        case .warning: return .warning
        case .critical: return .critical
        }
    }
}

/// Everything that determines what the menu bar image looks like. Two equal
/// specs draw the same pixels, so it doubles as the cache key and as the test
/// for "did anything visible change".
struct MenuBarSpec: Hashable {
    struct Item: Hashable {
        var metric: Metric
        var text: String
        var tone: LoadTone
        /// Second line of the network readout: `text` is the upload (top line),
        /// this the download (bottom line). Nil for every other metric.
        var secondary: String? = nil
    }

    var items: [Item]
    var showLabels: Bool
    var colorize: Bool

    /// Monochrome (system-tinted) unless "colour by load" is on *and* something
    /// is actually in alert.
    var isTemplate: Bool { !(colorize && items.contains { $0.tone != .normal }) }

    var accessibilityText: String {
        guard !items.isEmpty else { return "Stats" }
        return items.map { item in
            switch item.metric {
            case .fan: return "\(item.metric.spokenName) \(item.text) rpm"
            case .network: return "\(item.metric.spokenName), envio \(item.text), receção \(item.secondary ?? "–")"
            default: return "\(item.metric.spokenName) \(item.text)"
            }
        }.joined(separator: ", ")
    }
}

/// Draws the menu bar item: small mini widgets side by side, label above value
/// (or, without labels, a small glyph before the value); the network one is two
/// lines of throughput, up and down. Template
/// (system-tinted) unless something is in alert with "colour by load" on.
enum MenuBarRenderer {
    static let spacing: CGFloat = 6
    private static let glyphGap: CGFloat = 2
    private static let labelAlpha: CGFloat = 0.70

    /// Metric labels and the "rpm" unit share one font.
    private static let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    private static func valueFont(showLabels: Bool, weight: NSFont.Weight = .medium) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: showLabels ? 12 : 13, weight: weight)
    }

    private static func labelAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: labelFont, .kern: 0.5, .foregroundColor: color]
    }

    private static func width(of string: String, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        NSAttributedString(string: string, attributes: attributes).size().width
    }

    /// The network readout's two lines (upload above, download below), in a font
    /// small enough to stack. Identical with and without labels: the arrows say what it is.
    private static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let rateArrows = ("↑", "↓")
    private static let rateLineGap: CGFloat = 2

    private static let rateArrowWidth: CGFloat = {
        let attributes: [NSAttributedString.Key: Any] = [.font: rateFont]
        return ceil(max(width(of: rateArrows.0, attributes: attributes), width(of: rateArrows.1, attributes: attributes)))
    }()

    private static let networkWidth: CGFloat =
        rateArrowWidth + glyphGap + ceil(width(of: Metric.network.widthSample, attributes: [.font: rateFont]))

    /// 9 pt template glyph per metric (nil when no candidate symbol exists).
    private static let glyphs: [Metric: NSImage] = {
        var result: [Metric: NSImage] = [:]
        for metric in Metric.allCases {
            guard let name = metric.glyphSymbol,
                  let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) else { continue }
            result[metric] = symbol
        }
        return result
    }()

    /// Width of what precedes the value in the label-less layout.
    private static func prefixWidth(_ metric: Metric) -> CGFloat {
        if let glyph = glyphs[metric] { return ceil(glyph.size.width) + glyphGap }
        return ceil(width(of: metric.shortLabel, attributes: labelAttributes(color: .black))) + glyphGap
    }

    /// Widest value box: measured with the heaviest weight (alerts are semibold).
    private static func valueBoxWidth(_ metric: Metric, showLabels: Bool) -> CGFloat {
        ceil(width(of: metric.widthSample, attributes: [.font: valueFont(showLabels: showLabels, weight: .semibold)]))
    }

    private static func unitWidth(_ metric: Metric) -> CGFloat {
        metric.unit.map { glyphGap + ceil(width(of: $0, attributes: [.font: labelFont])) } ?? 0
    }

    /// Fixed per metric and label setting, measured with the widest text it can
    /// show, so the item never changes width from one tick to the next.
    static func widgetWidth(metric: Metric, showLabels: Bool) -> CGFloat {
        if metric == .network { return networkWidth }
        let value = valueBoxWidth(metric, showLabels: showLabels)
        if showLabels {
            return max(value, ceil(width(of: metric.shortLabel, attributes: labelAttributes(color: .black))))
        }
        return prefixWidth(metric) + value + unitWidth(metric)
    }

    /// Where each widget sits across the image, left to right, in image points.
    struct Segment: Equatable {
        var metric: Metric
        var span: ClosedRange<CGFloat>
    }

    static func segments(for spec: MenuBarSpec) -> [Segment] {
        var segments: [Segment] = []
        var x: CGFloat = 0
        for item in spec.items {
            let w = widgetWidth(metric: item.metric, showLabels: spec.showLabels)
            segments.append(Segment(metric: item.metric, span: x...(x + w)))
            x += w + spacing
        }
        return segments
    }

    /// The widget under `x` (points from the image's left edge). In the gap between
    /// two, or beyond either end, the nearest one; nil when nothing is drawn.
    static func segment(atX x: CGFloat, in spec: MenuBarSpec) -> Segment? {
        func distance(to span: ClosedRange<CGFloat>) -> CGFloat {
            x < span.lowerBound ? span.lowerBound - x : max(0, x - span.upperBound)
        }
        return segments(for: spec).min { distance(to: $0.span) < distance(to: $1.span) }
    }

    static func imageSize(for spec: MenuBarSpec, height: CGFloat) -> NSSize {
        NSSize(width: segments(for: spec).last?.span.upperBound ?? 0, height: height)
    }

    static func image(for spec: MenuBarSpec, height: CGFloat = NSStatusBar.system.thickness) -> NSImage {
        guard !spec.items.isEmpty else {
            let fallback = NSImage(systemSymbolName: "cpu", accessibilityDescription: spec.accessibilityText) ?? NSImage()
            fallback.isTemplate = true
            return fallback
        }
        let template = spec.isTemplate
        let segments = segments(for: spec)
        let image = NSImage(size: imageSize(for: spec, height: height), flipped: false) { _ in
            for (item, segment) in zip(spec.items, segments) {
                let rect = NSRect(x: segment.span.lowerBound, y: 0,
                                  width: segment.span.upperBound - segment.span.lowerBound, height: height)
                draw(item, in: rect, spec: spec, template: template)
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = spec.accessibilityText
        return image
    }

    /// Alert colours, darker in light mode for contrast on the bar.
    private static func color(for tone: LoadTone, dark: Bool) -> NSColor {
        switch tone {
        case .normal: return .labelColor
        case .warning: return dark ? .systemOrange : NSColor(srgbRed: 0.60, green: 0.27, blue: 0, alpha: 1)
        case .critical: return dark ? .systemRed : NSColor(srgbRed: 0.72, green: 0.06, blue: 0.08, alpha: 1)
        }
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    // Colours are resolved inside the drawing handler, so they follow the
    // appearance of whatever the image is drawn onto.
    private static func draw(_ item: MenuBarSpec.Item, in rect: NSRect, spec: MenuBarSpec, template: Bool) {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let valueColor: NSColor
        let labelColor: NSColor
        if template {
            // Template: only the alpha counts; the system supplies the colour.
            valueColor = NSColor.black
            labelColor = NSColor.black.withAlphaComponent(labelAlpha)
        } else {
            valueColor = color(for: item.tone, dark: dark)
            labelColor = NSColor.labelColor.withAlphaComponent(labelAlpha)
        }

        if item.metric == .network {
            drawNetwork(item, in: rect, valueColor: valueColor, labelColor: labelColor)
            return
        }

        let font = valueFont(showLabels: spec.showLabels, weight: item.tone == .critical && !template ? .semibold : .medium)
        let value = NSAttributedString(string: item.text, attributes: [.font: font, .foregroundColor: valueColor])
        let valueWidth = value.size().width
        let box = valueBoxWidth(item.metric, showLabels: spec.showLabels)

        // Baselines from cap heights, so the pair is centred on the digits
        // rather than on the font's (taller) line boxes.
        if spec.showLabels {
            let gap: CGFloat = 2
            let block = labelFont.capHeight + gap + font.capHeight
            let baseline = ((rect.height - block) / 2).rounded(.down)
            let label = NSAttributedString(string: item.metric.shortLabel, attributes: labelAttributes(color: labelColor))
            // The trailing kern adds space after the last glyph; centre without it.
            let labelWidth = label.size().width - 0.5
            label.draw(at: NSPoint(x: rect.minX + (rect.width - labelWidth) / 2,
                                   y: baseline + font.capHeight + gap + labelFont.descender))
            value.draw(at: NSPoint(x: rect.minX + (rect.width - valueWidth) / 2, y: baseline + font.descender))
            return
        }

        let baseline = ((rect.height - font.capHeight) / 2).rounded(.down)
        var x = rect.minX
        if let glyph = glyphs[item.metric] {
            let tintedGlyph = tinted(glyph, labelColor)
            let size = tintedGlyph.size
            tintedGlyph.draw(in: NSRect(x: x, y: baseline + (font.capHeight - size.height) / 2,
                                        width: size.width, height: size.height))
        } else {
            let label = NSAttributedString(string: item.metric.shortLabel, attributes: labelAttributes(color: labelColor))
            label.draw(at: NSPoint(x: x, y: baseline + labelFont.descender))
        }
        x += prefixWidth(item.metric)
        // With a unit the value hugs it (right-aligned in its fixed box).
        let valueX = item.metric.unit == nil ? x + (box - valueWidth) / 2 : x + box - valueWidth
        value.draw(at: NSPoint(x: valueX, y: baseline + font.descender))
        if let unit = item.metric.unit {
            let text = NSAttributedString(string: unit, attributes: [.font: labelFont, .foregroundColor: labelColor])
            text.draw(at: NSPoint(x: x + box + glyphGap, y: baseline + labelFont.descender))
        }
    }

    /// Upload on the top line, download below, values right-aligned so the units
    /// line up. Baselines come from cap heights, as in the labelled layout.
    private static func drawNetwork(_ item: MenuBarSpec.Item, in rect: NSRect, valueColor: NSColor, labelColor: NSColor) {
        let font = rateFont
        let block = 2 * font.capHeight + rateLineGap
        let lower = ((rect.height - block) / 2).rounded(.down)
        let lines = [(arrow: rateArrows.0, text: item.text, baseline: lower + font.capHeight + rateLineGap),
                     (arrow: rateArrows.1, text: item.secondary ?? "", baseline: lower)]
        for line in lines {
            let arrow = NSAttributedString(string: line.arrow, attributes: [.font: font, .foregroundColor: labelColor])
            arrow.draw(at: NSPoint(x: rect.minX + (rateArrowWidth - arrow.size().width) / 2, y: line.baseline + font.descender))
            let value = NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: valueColor])
            value.draw(at: NSPoint(x: rect.maxX - value.size().width, y: line.baseline + font.descender))
        }
    }
}
