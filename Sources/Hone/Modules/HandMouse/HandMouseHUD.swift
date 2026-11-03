import AppKit
import SwiftUI
import HandKit
import HoneDesign

// What the hand mouse shows on screen: a pill with the mode and the last gesture,
// and, when asked for or while calibrating, a small camera view with the hand's
// skeleton and the active area. The panel never takes focus and lets every click
// through, like the ⌘Q card (`QuitHoldHUD`).

// MARK: - Mode look

extension HandMode {
    /// PT-PT label; the part after " · " is a hint and reads quieter.
    var label: String {
        switch self {
        case .noHand: return "Sem mão"
        case .pointing: return "A apontar"
        case .slow: return "Modo lento"
        case .clicking: return "A clicar"
        case .dragging: return "A arrastar"
        case .scrolling: return "Scroll"
        case .frozen(let lockIn):
            // `.infinity` = shortcut gestures are off: there is no lock to arm.
            guard lockIn.isFinite else { return "Congelado" }
            return "Congelado · fixa atalhos em \(max(1, Int(lockIn.rounded(.up))))s"
        case .flat: return "Mão deitada · fecha os dedos para fechar"
        case .switcher: return "Seletor de janelas · mão aberta escolhe"
        case .shortcuts: return "Atalhos"
        case .shortcutsLocked(let unlockIn):
            guard let unlockIn, unlockIn.isFinite else { return "Atalhos fixos" }
            return "Atalhos fixos · solta em \(max(1, Int(unlockIn.rounded(.up))))s"
        }
    }

    var color: Color {
        switch self {
        case .noHand: return VibeColor.dotOff
        case .pointing: return VibeColor.success
        case .slow: return VibePalette.teal
        case .clicking: return VibePalette.blue
        case .dragging: return VibePalette.purple
        case .scrolling: return VibePalette.orange
        case .frozen: return VibePalette.yellow
        case .flat: return VibeColor.danger
        case .switcher: return VibePalette.lilac
        case .shortcuts, .shortcutsLocked: return VibePalette.pink
        }
    }
}

// MARK: - Model

/// A line that replaces the mode for a moment ("Sem mão há 2 min", a camera error).
struct HandHUDMessage: Equatable {
    var text: String
    var isError: Bool
}

/// What a calibration shows: the instruction, the points collected and the box so far.
struct HandHUDCalibration: Equatable {
    var title: String
    var detail: String
    /// 0…1 while a countdown or a recording runs.
    var progress: Double?
    var samples: [HandPoint] = []
    var box: HandBox?
}

/// Everything the HUD draws. The controller writes it; the view only reads.
@MainActor
@Observable
final class HandHUDModel {
    var status = HandStatus()
    /// The last gesture, for a moment after it happens.
    var recentAction: String?
    var message: HandHUDMessage?
    var calibration: HandHUDCalibration?
    var watchOnly = false
    var showPill = true
    var showPreview = false
    var preview: CGImage?
    var landmarks: HandLandmarks?
    /// The active area in use.
    var box = HandBox.default
}

// MARK: - Panel

@MainActor
final class HandMouseHUD {
    let model = HandHUDModel()
    private var panel: NSPanel?
    private var screenFrame: NSRect?

    /// Room for the largest preview and the pill; the panel is transparent and
    /// click-through, so what is empty costs nothing. The content hugs the bottom.
    private static let size = CGSize(width: 460, height: 420)
    private static let bottomGap: CGFloat = 20

    func show() {
        if panel == nil {
            let hosting = NSHostingView(rootView: HandMouseHUDView(model: model))
            hosting.sizingOptions = []

            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
            panel.isFloatingPanel = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.contentView = hosting
            panel.setContentSize(Self.size)
            self.panel = panel
            screenFrame = nil
            followCursor()
        }
        panel?.orderFrontRegardless() // never makeKey: the panel must not take focus
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        model.preview = nil
        model.landmarks = nil
    }

    /// Esc, heard only while `listenForEscape(true)`: the panel can't take focus, so
    /// the key comes from monitors (local for Hone's own windows, global for the rest).
    var onEscape: (() -> Void)?
    private var escapeMonitors: [Any] = []

    func listenForEscape(_ on: Bool) {
        for monitor in escapeMonitors { NSEvent.removeMonitor(monitor) }
        escapeMonitors = []
        guard on else { return }
        let esc: UInt16 = 53
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == esc else { return event }
            MainActor.assumeIsolated { self?.onEscape?() }
            return nil
        }) { escapeMonitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == esc else { return }
            MainActor.assumeIsolated { self?.onEscape?() }
        }) { escapeMonitors.append(global) }
    }

    /// Bottom-centre of the screen the pointer is on; moves when the pointer
    /// crosses to another screen (the next-screen gesture).
    func followCursor() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame, frame != screenFrame else { return }
        screenFrame = frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2,
                                     y: frame.minY + Self.bottomGap))
    }
}

// MARK: - View

struct HandMouseHUDView: View {
    let model: HandHUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let tint = VibeToolColor.handMouse

    var body: some View {
        VStack(spacing: 8) {
            if model.showPreview {
                HandPreview(model: model, width: model.calibration == nil ? 200 : 320, tint: tint)
            }
            if model.showPill {
                pill
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : VibeMotion.quick, value: model.status.mode)
    }

    private var pill: some View {
        let shape = RoundedRectangle(cornerRadius: VibeRadius.strip, style: .continuous)
        return content
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(VibeColor.card, in: shape)
            .overlay(shape.strokeBorder(VibeColor.cardBorder, lineWidth: 1))
            .overlay { if model.message == nil && model.calibration == nil { EdgeMarks(edges: model.status.edges) } }
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        if let message = model.message {
            HStack(spacing: 10) {
                VibeDot(message.isError ? VibeColor.danger : VibeColor.text3, size: 8)
                Text(message.text)
                    .font(VibeFont.action)
                    .foregroundStyle(VibeColor.text1)
                    .lineLimit(2)
            }
        } else if let calibration = model.calibration {
            HStack(spacing: 10) {
                Indicator(color: tint, progress: calibration.progress)
                VStack(alignment: .leading, spacing: 2) {
                    Text(calibration.title)
                        .font(VibeFont.action)
                        .foregroundStyle(VibeColor.text1)
                    Text(calibration.detail)
                        .font(VibeFont.caption)
                        .foregroundStyle(VibeColor.text3)
                }
            }
        } else {
            let mode = model.status.mode
            let parts = mode.label.components(separatedBy: " · ")
            HStack(spacing: 10) {
                Indicator(color: mode.color, progress: model.status.holdProgress)
                Text(parts[0])
                    .font(VibeFont.action)
                    .foregroundStyle(VibeColor.text1)
                if parts.count > 1 {
                    Text(parts.dropFirst().joined(separator: " · "))
                        .font(VibeFont.body)
                        .foregroundStyle(VibeColor.text3)
                }
                if let action = model.recentAction {
                    Text("·")
                        .foregroundStyle(VibeColor.text4)
                    Text(action)
                        .font(VibeFont.action)
                        .foregroundStyle(tint)
                }
                if model.watchOnly {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(VibeColor.text3)
                        .accessibilityLabel("Só a observar")
                }
            }
            .lineLimit(1)
        }
    }
}

/// The mode's dot, with a thin ring that fills while a hold is in progress.
private struct Indicator: View {
    let color: Color
    let progress: Double?

    var body: some View {
        ZStack {
            VibeDot(color, size: 8)
            if let progress {
                Circle()
                    .stroke(VibeColor.track, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// A red mark on each side of the pill where the index tip has left the active area.
private struct EdgeMarks: View {
    let edges: (top: Bool, bottom: Bool, left: Bool, right: Bool)

    var body: some View {
        ZStack {
            if edges.top { bar(horizontal: true).frame(maxHeight: .infinity, alignment: .top) }
            if edges.bottom { bar(horizontal: true).frame(maxHeight: .infinity, alignment: .bottom) }
            if edges.left { bar(horizontal: false).frame(maxWidth: .infinity, alignment: .leading) }
            if edges.right { bar(horizontal: false).frame(maxWidth: .infinity, alignment: .trailing) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func bar(horizontal: Bool) -> some View {
        Capsule()
            .fill(VibeColor.danger)
            .frame(width: horizontal ? nil : 2.5, height: horizontal ? 2.5 : nil)
            .padding(horizontal ? .horizontal : .vertical, horizontal ? 14 : 10)
    }
}

// MARK: - Camera view

/// The camera image (already mirrored), the hand's skeleton and the active area.
private struct HandPreview: View {
    let model: HandHUDModel
    let width: CGFloat
    let tint: Color

    /// MediaPipe's hand skeleton.
    private static let bones: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4), (0, 5), (5, 6), (6, 7), (7, 8), (5, 9), (9, 10), (10, 11),
        (11, 12), (9, 13), (13, 14), (14, 15), (15, 16), (13, 17), (0, 17), (17, 18), (18, 19), (19, 20),
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: VibeRadius.strip, style: .continuous)
        let aspect = model.preview.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 4.0 / 3.0
        ZStack {
            VibeColor.inset
            if let image = model.preview {
                Image(decorative: image, scale: 1)
                    .resizable()
            }
            Canvas { context, size in draw(context, size) }
        }
        .frame(width: width)
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(VibeColor.cardBorder, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        func point(_ p: HandPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }

        let edges = model.status.edges
        let calibrating = model.calibration != nil

        // Area in use: faint while calibrating (the new one is drawn solid), red on the
        // side(s) the index tip has crossed otherwise.
        let box = model.box
        let rect = CGRect(x: box.left * size.width, y: box.top * size.height,
                          width: (box.right - box.left) * size.width,
                          height: (box.bottom - box.top) * size.height)
        let side = StrokeStyle(lineWidth: 2, lineCap: .round)
        if calibrating {
            context.stroke(Path(rect), with: .color(tint.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        } else {
            func edge(_ from: CGPoint, _ to: CGPoint, _ hit: Bool) {
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(path, with: .color(hit ? VibeColor.danger : tint.opacity(0.7)), style: side)
            }
            edge(CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), edges.top)
            edge(CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY), edges.bottom)
            edge(CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), edges.left)
            edge(CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), edges.right)
        }

        if let calibration = model.calibration {
            for sample in calibration.samples {
                let p = point(sample)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)),
                             with: .color(tint.opacity(0.7)))
            }
            if let box = calibration.box {
                let r = CGRect(x: box.left * size.width, y: box.top * size.height,
                               width: (box.right - box.left) * size.width,
                               height: (box.bottom - box.top) * size.height)
                context.stroke(Path(r), with: .color(tint), style: StrokeStyle(lineWidth: 2))
            }
        }

        guard let hand = model.landmarks else { return }
        var skeleton = Path()
        for (a, b) in Self.bones {
            skeleton.move(to: point(hand[a]))
            skeleton.addLine(to: point(hand[b]))
        }
        context.stroke(skeleton, with: .color(.white.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        for i in 0..<HandLandmarks.count {
            let p = point(hand[i])
            let tip = i == 8
            let r: CGFloat = tip ? 4 : 2.2
            context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                         with: .color(tip ? tint : .white))
        }
    }
}
