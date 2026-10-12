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

/// Hone's switch: a capsule (`VibeMetrics.toggle`) in the tool's colour. The knob
/// turns dark on light tracks (white, yellow) so it stays visible. `isPaused` keeps
/// it on but visibly held back.
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

    private var knobColor: Color {
        isOn && !isPaused && tint.vibeIsLight ? VibeColor.inkOnLight : VibeColor.text1
    }

    var body: some View {
        Button(action: { withAnimation(VibeMotion.standard) { toggle() } }) {
            Capsule(style: .continuous)
                .fill(trackColor)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(knobColor)
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
