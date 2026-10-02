import SwiftUI

// Pieces of the embedded tools' menu panels (Clippy, Screenly, Sleepy, Stats):
// a header with the tool's mascot, menu rows inside cards, small section
// labels and action pills. Plain SwiftUI, like `Components.swift`, so the
// panels render offscreen exactly as on screen.

// MARK: - Panel frame

public extension View {
    /// Outer margins and the shared panel width. Top-aligned so a host that is
    /// briefly taller (popover resizing) leaves the extra space below.
    func vibePanelLayout() -> some View {
        self
            .padding(.horizontal, VibeSpacing.outer)
            .padding(.top, VibeSpacing.m)
            .padding(.bottom, VibeSpacing.outer)
            .frame(width: VibeMetrics.panelWidth, alignment: .topLeading)
    }

    /// The black canvas, painted under the popover's arrow too, in dark mode.
    func vibePanelBackground() -> some View {
        self
            .background(VibeColor.canvas.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
    }

    /// A card that holds menu rows: tight padding so row highlights sit close
    /// to the card's edge, full width.
    func vibeMenuCard() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .vibeCard(padding: 6)
    }
}

// MARK: - Header

/// Top of a tool's panel: its mascot, name and a one-line state, with small
/// corner buttons on the right. A back chevron leads when `onBack` is set.
public struct VibePanelHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let color: Color
    let mood: Blob.Mood
    let onBack: (() -> Void)?
    let trailing: Trailing

    public init(title: String, subtitle: String, color: Color, mood: Blob.Mood,
                onBack: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.color = color
        self.mood = mood
        self.onBack = onBack
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 10) {
            if let onBack { VibeBackButton(action: onBack) }
            Blob(color: color, mood: mood, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(VibeFont.title)
                    .foregroundStyle(VibeColor.text1)
                Text(subtitle)
                    .font(VibeFont.caption)
                    .foregroundStyle(VibeColor.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { trailing }
        }
        // Mascot lines up with the icons of the rows below.
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
    }
}

/// "‹" that goes back to the host's home.
public struct VibeBackButton: View {
    let action: () -> Void
    @State private var hovering = false

    public init(action: @escaping () -> Void) { self.action = action }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? VibeColor.text1 : VibeColor.text3)
                .frame(width: 22, height: 22)
                .background(hovering ? VibeColor.raised : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(VibePressStyle(scale: 0.92))
        .onHover { hovering = $0 }
        .animation(VibeMotion.quick, value: hovering)
        .help("Voltar ao Hone")
        .accessibilityLabel("Voltar ao Hone")
    }
}

/// Corner button that splits a tool out to its own menu-bar icon (↗) or
/// joins it back into Hone's (↙).
public struct VibeOwnIconButton: View {
    let showsOwnIcon: Bool
    let action: () -> Void

    public init(showsOwnIcon: Bool, action: @escaping () -> Void) {
        self.showsOwnIcon = showsOwnIcon
        self.action = action
    }

    public var body: some View {
        VibeCornerButton(
            systemName: showsOwnIcon ? "arrow.down.left" : "arrow.up.right",
            help: showsOwnIcon
                ? "Tirar o ícone próprio (continua no menu do Hone)"
                : "Separar num ícone próprio na barra de menus",
            action: action)
    }
}

// MARK: - Menu rows

private struct VibeRowHighlightedKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// True while the menu row around this view is under the pointer.
    var vibeRowHighlighted: Bool {
        get { self[VibeRowHighlightedKey.self] }
        set { self[VibeRowHighlightedKey.self] = newValue }
    }
}

/// A menu row: full width, a soft raised fill under the pointer and a slightly
/// brighter one while pressed. Labels read `vibeRowHighlighted` to brighten.
public struct VibeMenuRowStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        VibeMenuRowBody(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct VibeMenuRowBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var lit: Bool { hovering && isEnabled }

    var body: some View {
        label
            .environment(\.vibeRowHighlighted, lit)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(VibeMotion.quick, value: hovering)
            .animation(VibeMotion.quick, value: pressed)
    }

    private var fill: Color {
        guard lit else { return .clear }
        return pressed ? VibeColor.raised.vibeMix(over: .white, amount: 0.95) : VibeColor.raised
    }
}

/// Icon, title and an optional shortcut on the right, in the menu greys.
public struct VibeMenuLabel: View {
    let title: String
    let systemImage: String
    let shortcut: String

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.vibeRowHighlighted) private var highlighted

    public init(_ title: String, systemImage: String, shortcut: String = "") {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(!isEnabled ? VibeColor.text4 : highlighted ? VibeColor.text2 : VibeColor.text3)
            Text(title)
                .font(VibeFont.body)
                .foregroundStyle(!isEnabled ? VibeColor.text4 : highlighted ? VibeColor.text1 : VibeColor.text2)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !shortcut.isEmpty {
                Text(shortcut)
                    .font(VibeFont.caption)
                    .foregroundStyle(VibeColor.text4)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The common case: a labelled menu row that runs `action`.
public struct VibeMenuRow: View {
    let title: String
    let systemImage: String
    let shortcut: String
    let action: () -> Void

    public init(_ title: String, systemImage: String, shortcut: String = "", action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VibeMenuLabel(title, systemImage: systemImage, shortcut: shortcut)
        }
        .buttonStyle(VibeMenuRowStyle())
    }
}

/// Small grey label over a group of rows inside a card ("Recentes").
public struct VibeSectionLabel: View {
    let title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(VibeColor.text4)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A thin divider between groups inside a card.
public struct VibeHairline: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(VibeColor.cardBorder)
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
    }
}

// MARK: - Action pill

/// A one-tap action as a dark pill outlined in the tool's colour — the menu
/// counterpart of the home's tool pills (icon, name, shortcut).
public struct VibeActionPill: View {
    let title: String
    let systemImage: String
    let shortcut: String
    let tint: Color
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    public init(_ title: String, systemImage: String, shortcut: String = "", tint: Color,
                action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(lit ? tint : VibeColor.text3)
                    .frame(width: 16)
                Text(title)
                    .font(VibeFont.pill)
                    .foregroundStyle(lit ? VibeColor.text1 : VibeColor.text2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                if !shortcut.isEmpty {
                    Text(shortcut)
                        .font(VibeFont.caption)
                        .foregroundStyle(VibeColor.text4)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(lit ? VibeColor.raised : VibeColor.inset, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(tint.vibeMix(over: VibeColor.card, amount: lit ? 0.42 : 0.17), lineWidth: 1)
            )
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(VibePressStyle())
        .onHover { hovering = $0 }
        .animation(VibeMotion.quick, value: hovering)
    }

    private var lit: Bool { hovering && isEnabled }
}
