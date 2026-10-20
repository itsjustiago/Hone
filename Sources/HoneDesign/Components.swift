import AppKit
import SwiftUI

// Building blocks of the Hone look. All plain SwiftUI shapes and text — no
// native switches, materials or AppKit views — so `ImageRenderer` previews
// draw them exactly as they appear on screen.

// MARK: - Card

public struct VibeCardModifier: ViewModifier {
    var padding: CGFloat

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(VibeColor.card, in: RoundedRectangle(cornerRadius: VibeRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VibeRadius.card, style: .continuous)
                    .strokeBorder(VibeColor.cardBorder, lineWidth: 0.5)
            )
    }
}

public extension View {
    /// Near-black card with a hairline border and continuous corners.
    func vibeCard(padding: CGFloat = VibeSpacing.cardPadding) -> some View {
        modifier(VibeCardModifier(padding: padding))
    }
}

// MARK: - Dot

/// The small round status dot used before titles and in status lines.
public struct VibeDot: View {
    let color: Color
    let size: CGFloat

    public init(_ color: Color, size: CGFloat = VibeMetrics.dot) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

// MARK: - Switch

/// Hone's switch: a capsule (`VibeMetrics.toggle`) in the tool's colour with a
/// white knob on every track. `isPaused` keeps it on but visibly held back.
public struct VibeToggleStyle: ToggleStyle {
    let tint: Color
    let isPaused: Bool

    public init(tint: Color, isPaused: Bool = false) {
        self.tint = tint
        self.isPaused = isPaused
    }

    public func makeBody(configuration: Configuration) -> some View {
        VibeSwitch(isOn: configuration.isOn, tint: tint, isPaused: isPaused) {
            configuration.isOn.toggle()
        }
        // The label isn't drawn; callers set `.accessibilityLabel` on the Toggle.
    }
}

private struct VibeSwitch: View {
    let isOn: Bool
    let tint: Color
    let isPaused: Bool
    let toggle: () -> Void
    @State private var hovering = false

    private var size: CGSize { VibeMetrics.toggle }
    private var knob: CGFloat { size.height - 4 }

    private var trackColor: Color {
        guard isOn else { return hovering ? VibeColor.track.vibeMix(over: .white, amount: 0.94) : VibeColor.track }
        return isPaused ? tint.opacity(0.45) : tint
    }

    var body: some View {
        Button(action: { withAnimation(VibeMotion.standard) { toggle() } }) {
            Capsule(style: .continuous)
                .fill(trackColor)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(VibeColor.text1)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(VibePressStyle())
        .onHover { hovering = $0 }
        .animation(VibeMotion.quick, value: hovering)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(Text(isOn ? (isPaused ? "Em pausa" : "Ligado") : "Desligado"))
    }
}

// MARK: - Slider

/// Hone's slider: a thin track filled in the tool's colour up to a white knob
/// (the switch's knob). Plain shapes and a drag gesture rather than the native
/// slider, so it looks the same everywhere and renders offscreen.
/// Pressing the track moves the knob there; pressing the knob grabs it where it
/// is, so a click on it moves nothing. With a `defaultValue` the track marks it,
/// the knob sticks to it when dragged close, and a double-click on the knob
/// goes back to it.
public struct VibeSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double?
    let label: String
    let tint: Color
    let onEditingChanged: (Bool) -> Void
    let onDoubleClickThumb: (() -> Void)?

    @State private var dragging = false
    @State private var press: VibeSliderPress.Kind?
    /// The press has moved at some point (a knob brought back to where it was grabbed still follows).
    @State private var pressMoved = false
    @State private var clicks = VibeSliderPress()

    /// Keys and VoiceOver move it in steps of 5 % (of the value, e.g. 0.05).
    static let step = 0.05
    /// Dragged within this share of the range, the knob sticks to `defaultValue`
    /// (±3 % on a 0…200 % slider).
    static let snapFraction = 0.015
    private let knob: CGFloat = 16
    private let track: CGFloat = 5

    /// - Parameters:
    ///   - range: what the ends stand for (0…1 unless given).
    ///   - defaultValue: marked on the track, magnetic, and where a double-click
    ///     on the knob goes back to. `nil`: none of that.
    ///   - label: what the slider sets, for VoiceOver ("Volume do Spotify").
    ///   - tint: the filled part; pass a grey while the thing it sets is off.
    ///   - onEditingChanged: `true` when a drag starts, `false` when it ends.
    ///   - onDoubleClickThumb: what a double-click on the knob does instead of
    ///     setting `defaultValue` through the binding.
    public init(value: Binding<Double>, in range: ClosedRange<Double> = 0...1, defaultValue: Double? = nil,
                label: String, tint: Color,
                onEditingChanged: @escaping (Bool) -> Void = { _ in },
                onDoubleClickThumb: (() -> Void)? = nil) {
        self._value = value
        self.range = range
        self.defaultValue = defaultValue
        self.label = label
        self.tint = tint
        self.onEditingChanged = onEditingChanged
        self.onDoubleClickThumb = onDoubleClickThumb
    }

    /// Where `value` sits along `range`, 0…1.
    static func fraction(_ value: Double, in range: ClosedRange<Double> = 0...1) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, value.isFinite else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    /// The value for a pointer `x` points from the track's left edge: the knob's
    /// centre follows the pointer, and its travel is the width less one knob.
    static func value(atX x: CGFloat, width: CGFloat, knob: CGFloat, in range: ClosedRange<Double> = 0...1) -> Double {
        let travel = max(width - knob, 1)
        let fraction = Double(min(max((x - knob / 2) / travel, 0), 1))
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }

    /// Where the knob's centre is for `value`, from the track's left edge.
    static func knobCenter(for value: Double, width: CGFloat, knob: CGFloat,
                           in range: ClosedRange<Double> = 0...1) -> CGFloat {
        knob / 2 + CGFloat(fraction(value, in: range)) * max(width - knob, 1)
    }

    /// `value`, pulled onto `target` within `snapFraction` of the range.
    static func snapped(_ value: Double, to target: Double?, in range: ClosedRange<Double> = 0...1) -> Double {
        guard let target else { return value }
        let span = range.upperBound - range.lowerBound
        return abs(value - target) <= span * snapFraction ? target : value
    }

    /// What a press of `kind`, now at `x`, sets — `nil` for nothing: a knob
    /// that hasn't moved yet (so a click, or the first half of a double-click,
    /// never nudges it) and a double-click (which resets instead).
    static func value(for kind: VibeSliderPress.Kind, atX x: CGFloat, moved: Bool, width: CGFloat, knob: CGFloat,
                      in range: ClosedRange<Double> = 0...1, defaultValue: Double? = nil) -> Double? {
        let pointer: CGFloat
        switch kind {
        case .track: pointer = x
        case .knob(let grab):
            guard moved else { return nil }
            pointer = x - grab
        case .doubleClick: return nil
        }
        return snapped(value(atX: pointer, width: width, knob: knob, in: range), to: defaultValue, in: range)
    }

    private var resets: Bool { defaultValue != nil || onDoubleClickThumb != nil }

    private func reset() {
        if let onDoubleClickThumb {
            onDoubleClickThumb()
        } else if let defaultValue {
            value = defaultValue
        }
    }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let center = Self.knobCenter(for: value, width: width, knob: knob, in: range)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(VibeColor.track)
                    .frame(height: track)
                if let defaultValue {
                    // Taller than the track, so its ends still show once the fill passes it.
                    Capsule(style: .continuous)
                        .fill(VibeColor.text4)
                        .frame(width: 2, height: track + 6)
                        .offset(x: Self.knobCenter(for: defaultValue, width: width, knob: knob, in: range) - 1)
                        .accessibilityHidden(true)
                }
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: center, height: track)
                Circle()
                    .fill(VibeColor.text1)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .scaleEffect(dragging ? 1.08 : 1)
                    .offset(x: center - knob / 2)
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if press == nil {
                            if !dragging {
                                dragging = true
                                onEditingChanged(true)
                            }
                            let kind = clicks.began(x: drag.startLocation.x, knobCenter: center, knob: knob,
                                                    time: drag.time.timeIntervalSinceReferenceDate,
                                                    doubleClickInterval: NSEvent.doubleClickInterval,
                                                    resets: resets)
                            press = kind
                            pressMoved = false
                            if kind == .doubleClick { reset() }
                        }
                        if drag.translation != .zero { pressMoved = true }
                        guard let press,
                              let next = Self.value(for: press, atX: drag.location.x,
                                                    moved: pressMoved, width: width, knob: knob,
                                                    in: range, defaultValue: defaultValue) else { return }
                        value = next
                    }
                    .onEnded { drag in
                        clicks.ended(distance: hypot(drag.translation.width, drag.translation.height))
                        press = nil
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: VibeMetrics.toggle.height)
        .animation(VibeMotion.quick, value: dragging)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Text("\(Int((min(max(value, range.lowerBound), range.upperBound) * 100).rounded())) por cento"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + Self.step, range.upperBound)
            case .decrement: value = max(value - Self.step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

/// How a press on a `VibeSlider` reads: on the track it jumps the knob there;
/// on the knob it grabs it where it is; a second click on the knob within the
/// system's double-click interval is a reset. Pure, so it is tested without a window.
struct VibeSliderPress: Equatable {
    enum Kind: Equatable {
        case track
        /// The pointer's distance from the knob's centre when the press began:
        /// the knob keeps that offset as it follows the pointer.
        case knob(grab: CGFloat)
        case doubleClick
    }

    /// Movement up to this many points still counts as a click.
    static let clickSlop: CGFloat = 3
    /// A press this close to the knob's edge counts as on the knob.
    static let knobSlop: CGFloat = 2

    /// When the last click (a press that didn't drag) on the knob began.
    private(set) var lastKnobClick: TimeInterval?

    /// A press began at `x`. `resets`: the slider has something to reset to,
    /// otherwise a double-click is just two clicks.
    mutating func began(x: CGFloat, knobCenter: CGFloat, knob: CGFloat, time: TimeInterval,
                        doubleClickInterval: TimeInterval, resets: Bool) -> Kind {
        let grab = x - knobCenter
        guard abs(grab) <= knob / 2 + Self.knobSlop else {
            lastKnobClick = nil
            return .track
        }
        if resets, let last = lastKnobClick, time - last >= 0, time - last <= doubleClickInterval {
            lastKnobClick = nil  // a third click starts over
            return .doubleClick
        }
        lastKnobClick = time  // until it turns out to be a drag
        return .knob(grab: grab)
    }

    /// The press ended after moving `distance` points: a drag isn't half of a double-click.
    mutating func ended(distance: CGFloat) {
        if distance > Self.clickSlop { lastKnobClick = nil }
    }
}

// MARK: - Buttons

/// Gentle press feedback for custom controls (scale ~0.97).
public struct VibePressStyle: ButtonStyle {
    var scale: CGFloat

    public init(scale: CGFloat = 0.97) { self.scale = scale }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(VibeMotion.quick, value: configuration.isPressed)
    }
}

/// Text-only actions: `.strong` (semibold, light grey) for the main action and
/// `.secondary` (regular, mid grey) beside it. Both brighten on hover.
public struct VibeLinkButtonStyle: ButtonStyle {
    public enum Emphasis: Sendable { case strong, secondary }
    let emphasis: Emphasis

    public init(_ emphasis: Emphasis = .strong) { self.emphasis = emphasis }

    public func makeBody(configuration: Configuration) -> some View {
        VibeLinkLabel(label: configuration.label, emphasis: emphasis, pressed: configuration.isPressed)
    }
}

private struct VibeLinkLabel<Label: View>: View {
    let label: Label
    let emphasis: VibeLinkButtonStyle.Emphasis
    let pressed: Bool
    @State private var hovering = false

    var body: some View {
        label
            .font(emphasis == .strong ? VibeFont.action : VibeFont.actionSecondary)
            .foregroundStyle(color)
            .opacity(pressed ? 0.7 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(VibeMotion.quick, value: hovering)
    }

    private var color: Color {
        switch emphasis {
        case .strong: return hovering ? VibeColor.text1 : VibeColor.text2
        case .secondary: return hovering ? VibeColor.text2 : VibeColor.text3
        }
    }
}

/// Top-bar icon: bare glyph at rest, a soft capsule when hovered and a solid
/// one when selected.
public struct VibeBarButtonStyle: ButtonStyle {
    let isSelected: Bool

    public init(isSelected: Bool = false) { self.isSelected = isSelected }

    public func makeBody(configuration: Configuration) -> some View {
        VibeBarLabel(label: configuration.label, isSelected: isSelected, pressed: configuration.isPressed)
    }
}

private struct VibeBarLabel<Label: View>: View {
    let label: Label
    let isSelected: Bool
    let pressed: Bool
    @State private var hovering = false

    var body: some View {
        label
            .font(VibeFont.barIcon)
            .foregroundStyle(isSelected ? VibeColor.text1 : hovering ? VibeColor.text2 : VibeColor.text3)
            .frame(width: VibeMetrics.barTab.width, height: VibeMetrics.barTab.height)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? VibeColor.control : hovering ? VibeColor.card : .clear)
            )
            .contentShape(Capsule())
            .scaleEffect(pressed ? 0.94 : 1)
            .onHover { hovering = $0 }
            .animation(VibeMotion.quick, value: hovering)
            .animation(VibeMotion.quick, value: pressed)
    }
}

/// The small round button that sits in a card's corner.
public struct VibeCornerButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    public init(systemName: String, help: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hovering ? VibeColor.text2 : VibeColor.cornerIcon)
                .frame(width: VibeMetrics.cornerButton, height: VibeMetrics.cornerButton)
                .background(VibeColor.cornerFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(VibePressStyle(scale: 0.92))
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Status line & notice strip

/// "● Text" — a coloured dot with a short grey status message. One line by
/// default; `wraps` lets a longer message flow onto more, the dot staying on the first.
public struct VibeStatusLine: View {
    let color: Color
    let text: String
    let wraps: Bool

    public init(_ text: String, color: Color, wraps: Bool = false) {
        self.text = text
        self.color = color
        self.wraps = wraps
    }

    public var body: some View {
        HStack(alignment: wraps ? .firstTextBaseline : .center, spacing: 7) {
            VibeDot(color)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            Text(text)
                .font(VibeFont.body)
                .foregroundStyle(VibeColor.text3)
                .lineLimit(wraps ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: wraps)
        }
    }
}

/// A thin card for something that needs attention: dot, message, link on the
/// right (e.g. "● Atualização 1.4 disponível        Instalar").
public struct VibeNoticeStrip: View {
    let color: Color
    let text: String
    let actionTitle: String
    let action: () -> Void

    public init(_ text: String, color: Color, actionTitle: String, action: @escaping () -> Void) {
        self.text = text
        self.color = color
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 8) {
            VibeDot(color)
            Text(text)
                .font(VibeFont.body)
                .foregroundStyle(VibeColor.text2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .buttonStyle(VibeLinkButtonStyle(.strong))
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(VibeColor.card, in: RoundedRectangle(cornerRadius: VibeRadius.strip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VibeRadius.strip, style: .continuous)
                .strokeBorder(VibeColor.cardBorder, lineWidth: 0.5)
        )
    }
}
