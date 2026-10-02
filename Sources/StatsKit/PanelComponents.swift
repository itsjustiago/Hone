import SwiftUI

/// Sparkline over a fixed 0…1 scale. Samples enter from the right, so a short
/// history sits at the right edge instead of stretching across the width.
struct SparklineShape: Shape {
    var values: [Double]
    var capacity: Int
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / CGFloat(max(1, capacity - 1))
        let first = capacity - values.count
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: rect.minX + step * CGFloat(first + i),
                    y: rect.maxY - rect.height * CGFloat(clamp01(values[i])))
        }
        path.move(to: point(0))
        for i in 1..<values.count { path.addLine(to: point(i)) }
        if closed {
            path.addLine(to: CGPoint(x: point(values.count - 1).x, y: rect.maxY))
            path.addLine(to: CGPoint(x: point(0).x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

struct Sparkline: View {
    var values: [Double]
    var capacity: Int = SystemMonitor.historyLength
    var lineWidth: CGFloat = 1.5
    /// Tooltip, e.g. "Últimos 60 s".
    var help: String?

    var body: some View {
        ZStack {
            SparklineShape(values: values, capacity: capacity, closed: true)
                .fill(LinearGradient(colors: [Brand.tint.opacity(0.28), Brand.tint.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
            SparklineShape(values: values, capacity: capacity, closed: false)
                .stroke(Brand.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .background(alignment: .bottom) {
            Rectangle().fill(.primary.opacity(0.10)).frame(height: 0.5)
        }
        .drawingGroup(opaque: false)
        .help(help ?? "")
        .accessibilityHidden(true)
    }
}

/// Press feedback for the metric tiles: a slight, quick shrink (not with Reduce Motion).
struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressScale(isPressed: configuration.isPressed) { configuration.label }
    }

    private struct PressScale<Content: View>: View {
        let isPressed: Bool
        @ViewBuilder var content: Content
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            content
                .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPressed)
        }
    }
}

/// Selectable summary of one metric: big value and a mini sparkline.
struct MetricTile: View {
    let title: String
    let value: String
    /// Small unit after the value (fans: "rpm").
    var unit: String? = nil
    var help: String? = nil
    let values: [Double]
    var historyHelp: String? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(Brand.tintText) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: unit == nil ? 17 : 14, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let unit {
                        Text(unit).font(.system(size: 8.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Sparkline(values: values, lineWidth: 1, help: historyHelp)
                    .frame(height: 14)
                    .padding(.top, 3)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Brand.tint.opacity(0.28) : .primary.opacity(0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(TilePressStyle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: selected)
        .help(help ?? "")
        .accessibilityLabel("\(title), \(value)\(unit.map { " " + $0 } ?? "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(Brand.tint.opacity(0.10)) }
        return AnyShapeStyle(.primary.opacity(hovering ? 0.07 : 0.04))
    }
}

/// Label on the left, value on the right; fixed height so rows never shift.
struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12).monospacedDigit())
        }
        .font(.system(size: 12))
        .frame(height: 17)
        .accessibilityElement(children: .combine)
    }
}

/// Small caption over a value, for the user / system / idle triple.
struct StatColumn: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct SectionCaption: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// Thin vertical bars, one per core, centred (never wider than 14 pt each).
struct CoreBars: View {
    let values: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(Brand.tint).frame(height: max(2, 26 * clamp01(value)))
                }
                .frame(maxWidth: 14)
                .frame(height: 26)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Carga por núcleo")
        .accessibilityValue(values.map(Format.percent).joined(separator: ", "))
    }
}

/// Horizontal progress bar, 0…1.
struct FractionBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(Brand.tint).frame(width: max(3, proxy.size.width * clamp01(fraction)))
            }
        }
        .frame(height: 4)
    }
}

struct PressurePill: View {
    let pressure: MemoryPressure

    var body: some View {
        Text(pressure.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .accessibilityLabel("Pressão da memória \(pressure.title)")
    }

    // Darker text in light mode, where the system colours are too pale on a tint.
    private var color: Color {
        switch pressure {
        case .normal:
            return Color(light: NSColor(srgbRed: 0, green: 0.40, blue: 0.15, alpha: 1), dark: .systemGreen)
        case .warning:
            return Color(light: NSColor(srgbRed: 0.60, green: 0.27, blue: 0, alpha: 1), dark: .systemOrange)
        case .critical:
            return Color(light: NSColor(srgbRed: 0.72, green: 0.06, blue: 0.08, alpha: 1), dark: .systemRed)
        }
    }
}

/// "Processos principais": always `rowCount` rows, so the panel (and its
/// popover) never changes height. Rows from an earlier reading show dimmed
/// until a fresh one arrives; with none yet, "A medir…".
struct ProcessList: View {
    let metric: Metric
    let rows: [ProcessRow]
    let isFresh: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionCaption(title: "Processos principais").padding(.bottom, 3)
            ForEach(0..<TopProcessesModel.rowCount, id: \.self) { index in
                let row = index < rows.count ? rows[index] : nil
                HStack(spacing: 8) {
                    Text(row?.name ?? "A medir…")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(nameStyle(row))
                        .help(row?.name ?? "")
                    Spacer(minLength: 8)
                    Text(value(for: row))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .frame(height: 17)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func nameStyle(_ row: ProcessRow?) -> AnyShapeStyle {
        if row == nil { return AnyShapeStyle(.tertiary) }
        return isFresh ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private func value(for row: ProcessRow?) -> String {
        guard let row else { return "" }
        return metric == .cpu ? Format.percentValue(row.cpu) : Format.bytes(row.memoryBytes)
    }
}
