import SwiftUI

// Settings pages and the onboarding: a quiet label over a near-black card of
// rows, in the same family as the popover. Shared by Hone's own pages and the
// Kits' pages so every tool's settings read as one. Plain SwiftUI, like the
// rest of this module, apart from the native pickers and sliders a page adds.

// MARK: - Tokens

public extension VibeColor {
    /// Divider between rows inside a card. `cardBorder` nearly vanishes at 1pt.
    static let rowDivider = Color(vibeHex: 0x1F2024)
    /// Edge of a selected pill or row, and of buttons sitting on a card.
    static let selectedBorder = Color(vibeHex: 0x2E3035)
}

public extension VibeFont {
    /// Title of a settings page.
    static let pageTitle = Font.system(size: 17, weight: .bold)
    /// Small label over a card ("Barra de menus").
    static let settingsSection = Font.system(size: 12, weight: .semibold)
    /// Row title.
    static let settingsRow = Font.system(size: 13)
    /// Row subtitle and notes.
    static let settingsDetail = Font.system(size: 11.5)
}

public extension VibeRadius {
    /// Cards on settings pages: flatter than the popover's, they hold wide rows.
    static let settingsCard: CGFloat = 14
}

// MARK: - Section & card

/// A section label with its card underneath.
public struct VibeSettingsSection<Content: View>: View {
    let title: String
    let content: Content

    public init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(VibeFont.settingsSection)
                .foregroundStyle(VibeColor.text3)
                .padding(.leading, 6)
                .accessibilityAddTraits(.isHeader)
            VibeSettingsCard { content }
        }
    }
}

/// The card: rows stacked flush, with continuous corners.
public struct VibeSettingsCard<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: VibeRadius.settingsCard, style: .continuous)
        VStack(spacing: 0) { content }
            .background(VibeColor.card, in: shape)
            .overlay(shape.strokeBorder(VibeColor.cardBorder, lineWidth: 0.5))
    }
}

/// Divider between rows, inset to line up with the row text.
public struct VibeRowDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(VibeColor.rowDivider)
            .frame(height: 1)
            .padding(.leading, 14)
            .accessibilityHidden(true)
    }
}

// MARK: - Rows

/// Title (+ optional subtitle) on the left, any control on the right.
public struct VibeSettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing

    public init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(VibeFont.settingsRow)
                    .foregroundStyle(VibeColor.text1)
                if let subtitle {
                    Text(subtitle)
                        .font(VibeFont.settingsDetail)
                        .foregroundStyle(VibeColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// A row with Hone's switch in the tool's colour.
public struct VibeToggleRow: View {
    let title: String
    let subtitle: String?
    let tint: Color
    @Binding var isOn: Bool

    public init(title: String, subtitle: String? = nil, tint: Color, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self._isOn = isOn
    }

    public var body: some View {
        VibeSettingsRow(title: title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(VibeToggleStyle(tint: tint))
                .accessibilityLabel(title)
        }
    }
}

// MARK: - Page header & banner

/// What a page header says about the tool right now (e.g. "Ativo no Hone ·
/// agora: sleep normal"), under the title with a coloured dot.
public struct VibeHeaderStatus {
    let text: String
    let color: Color

    public init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }
}

/// Top of a settings page: the tool's mascot, its name and what it does, with
/// the on/off switch (or a button) at the right. The home's hero card, as a page.
public struct VibePageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let color: Color
    let mood: Blob.Mood
    let symbol: String?
    let status: VibeHeaderStatus?
    let trailing: Trailing

    private let blobHeight: CGFloat = 42

    /// - Parameters:
    ///   - symbol: an SF Symbol drawn in place of the mascot, for a tweak that
    ///     belongs to Hone rather than being an app of its own.
    ///   - status: a live line under the title, for tools whose switch alone
    ///     doesn't say whether they are doing anything.
    public init(title: String, subtitle: String, color: Color, mood: Blob.Mood = .awake,
                symbol: String? = nil, status: VibeHeaderStatus? = nil,
                @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.color = color
        self.mood = mood
        self.symbol = symbol
        self.status = status
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            mark
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(VibeFont.pageTitle)
                    .foregroundStyle(VibeColor.text1)
                if let status {
                    VibeStatusLine(status.text, color: status.color, wraps: true)
                }
                Text(subtitle)
                    .font(VibeFont.body)
                    .foregroundStyle(VibeColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .vibeCard(padding: VibeSpacing.cardPadding)
        .accessibilityElement(children: .contain)
    }
}

private extension VibePageHeader {
    @ViewBuilder
    var mark: some View {
        if let symbol {
            let on = mood != .asleep
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(on ? color : VibeColor.text4)
                .frame(width: 46, height: 46)
                .background(on ? color.vibeMix(over: VibeColor.card, amount: 0.16) : VibeColor.inset, in: Circle())
                .accessibilityHidden(true)
        } else {
            Blob(color: color, mood: mood, height: blobHeight, glow: mood == .awake)
        }
    }
}

public extension VibePageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, color: Color, mood: Blob.Mood = .awake) {
        self.init(title: title, subtitle: subtitle, color: color, mood: mood) { EmptyView() }
    }
}

/// A card for something on a page that needs attention: a coloured dot, what is
/// wrong, a line of detail and the button that fixes it.
public struct VibeBanner: View {
    let color: Color
    let title: String
    let detail: String
    let actionTitle: String?
    let stacked: Bool
    let action: () -> Void

    /// Without an `actionTitle` the banner only informs. `stacked` puts the
    /// button under the text instead of beside it, for narrow places (the menu
    /// panel) where a long detail would wrap into a thin column.
    public init(color: Color, title: String, detail: String, actionTitle: String? = nil,
                stacked: Bool = false, action: @escaping () -> Void = {}) {
        self.color = color
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.stacked = stacked
        self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: VibeRadius.settingsCard, style: .continuous)
        HStack(alignment: stacked ? .top : .center, spacing: 10) {
            VibeDot(color, size: 7)
                .padding(.top, stacked ? 5 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(VibeFont.settingsRow.weight(.semibold))
                    .foregroundStyle(VibeColor.text1)
                Text(detail)
                    .font(VibeFont.settingsDetail)
                    .foregroundStyle(VibeColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
                if stacked, let actionTitle {
                    Button(actionTitle, action: action)
                        .buttonStyle(VibeButtonStyle())
                        .controlSize(.small)
                        .padding(.top, 8)
                }
            }
            Spacer(minLength: 8)
            if !stacked, let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(VibeButtonStyle())
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VibeColor.card, in: shape)
        .overlay(shape.strokeBorder(color.vibeMix(over: VibeColor.card, amount: 0.3), lineWidth: 1))
    }
}

// MARK: - Button

/// Buttons on settings pages: a small outlined capsule on the dark surface.
/// `prominent` fills it with `tint` for the one action that matters on a page;
/// a destructive role reads in red.
public struct VibeButtonStyle: ButtonStyle {
    let prominent: Bool
    let tint: Color

    public init(prominent: Bool = false, tint: Color = VibeColor.text1) {
        self.prominent = prominent
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        VibeButtonBody(label: configuration.label, role: configuration.role,
                       pressed: configuration.isPressed, prominent: prominent, tint: tint)
    }
}

private struct VibeButtonBody<Label: View>: View {
    let label: Label
    let role: ButtonRole?
    let pressed: Bool
    let prominent: Bool
    let tint: Color

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false

    private var small: Bool { controlSize == .small || controlSize == .mini }
    private var lit: Bool { hovering && isEnabled }

    var body: some View {
        label
            .font(.system(size: small ? 12 : 13, weight: .semibold))
            .foregroundStyle(textColor)
            .padding(.horizontal, small ? 12 : 16)
            .padding(.vertical, small ? 5 : 7)
            .background(fill, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(border, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(pressed ? 0.97 : 1)
            .onHover { hovering = $0 }
            .animation(VibeMotion.quick, value: hovering)
            .animation(VibeMotion.quick, value: pressed)
    }

    private var textColor: Color {
        if prominent { return tint.vibeInk }
        if role == .destructive { return VibeColor.danger }
        return lit ? VibeColor.text1 : VibeColor.text2
    }

    private var fill: Color {
        if prominent { return lit ? tint.vibeMix(over: .white, amount: 0.9) : tint }
        return lit ? VibeColor.control.vibeMix(over: .white, amount: 0.94) : VibeColor.control
    }

    private var border: Color {
        if prominent { return .clear }
        if role == .destructive { return VibeColor.danger.vibeMix(over: VibeColor.card, amount: 0.3) }
        return VibeColor.selectedBorder
    }
}
