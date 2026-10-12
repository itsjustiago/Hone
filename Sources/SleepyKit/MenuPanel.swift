import SwiftUI
import AppKit
import HoneDesign

/// Live state the menu-bar panel reflects. Populated by `SleepyTool` right
/// before the panel shows so the toggle, auto-off and permissions stay fresh.
final class SleepMenuModel: ObservableObject {
    @Published var isActive = false
    @Published var autoOffText: String?
    @Published var autoOffMinutes = SleepController.autoOffMinutes
    @Published var passwordlessInstalled = PrivilegedAccess.isInstalled
    /// Honest warning when the lid-closed guarantee is gone (see `DisableSleepGuard`).
    @Published var warning: String?
    /// Mirrors `SleepyTool.showsOwnMenuBarIcon` so the detach/attach button
    /// swaps its glyph live.
    @Published var showsOwnIcon = true
}

/// The Sleepy panel, shown either from its own menu-bar icon or inside Hone's
/// popover. App-level rows (quit, updates, version) belong to Hone now. Reads
/// the live model and hands plain values to `MenuPanelContent`.
struct MenuPanel: View {
    @ObservedObject var model: SleepMenuModel

    var onToggleSleep: () -> Void
    var onEnablePasswordless: () -> Void
    var onChangeAutoOff: (Int) -> Void
    var onSettings: () -> Void
    /// Non-nil when hosted inside Hone's popover: the header shows a back chevron.
    var onBack: (() -> Void)?
    var onToggleOwnIcon: () -> Void

    var body: some View {
        MenuPanelContent(
            isActive: model.isActive,
            autoOffText: model.autoOffText,
            autoOffMinutes: model.autoOffMinutes,
            passwordlessInstalled: model.passwordlessInstalled,
            showsOwnIcon: model.showsOwnIcon,
            warning: model.warning,
            onBack: onBack,
            onToggleSleep: onToggleSleep,
            onEnablePasswordless: onEnablePasswordless,
            onChangeAutoOff: onChangeAutoOff,
            onSettings: onSettings,
            onToggleOwnIcon: onToggleOwnIcon)
    }
}

/// Values in, closures out, so it renders offscreen from fake data.
struct MenuPanelContent: View {
    let isActive: Bool
    let autoOffText: String?
    let autoOffMinutes: Int
    let passwordlessInstalled: Bool
    let showsOwnIcon: Bool
    let warning: String?
    /// Offscreen renders can't draw AppKit views, which the auto-off menu is anchored to.
    var offscreen = false
    var onBack: (() -> Void)?
    var onToggleSleep: () -> Void = {}
    var onEnablePasswordless: () -> Void = {}
    var onChangeAutoOff: (Int) -> Void = { _ in }
    var onSettings: () -> Void = {}
    var onToggleOwnIcon: () -> Void = {}

    private var tint: Color { VibeToolColor.sleepy }
    private let blobHeight: CGFloat = 50
    /// Gap between the own-icon button and the switch in the card's corner.
    private let cornerSpacing: CGFloat = 8

    var body: some View {
        VStack(spacing: VibeSpacing.cardGap) {
            heroCard

            if let warning { WarningStrip(text: warning) }

            if !passwordlessInstalled {
                VibeNoticeStrip("Ligar sem password", color: VibeColor.warning,
                                actionTitle: "Ativar…", action: onEnablePasswordless)
                    .help("Instala uma regra restrita para não pedir password a cada toggle.")
            }

            VStack(alignment: .leading, spacing: 0) {
                autoOffRow
                VibeMenuRow("Definições…", systemImage: "gearshape", action: onSettings)
            }
            .vibeMenuCard()
        }
        .vibePanelLayout()
        .vibePanelBackground()
        // Keep controls (the auto-off menu) fully coloured even when the popover
        // window isn't key.
        .environment(\.controlActiveState, .active)
    }

    // MARK: - Hero

    /// Same card as Hone's home hero: the mascot is the state, the switch sits
    /// in the corner next to the own-icon button.
    private var heroCard: some View {
        HStack(alignment: .center, spacing: 18) {
            Blob(color: tint, mood: isActive ? .awake : .asleep, height: blobHeight, glow: isActive)
                .frame(width: blobHeight * 1.3, height: blobHeight)
                .padding(.leading, 6)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    if let onBack { VibeBackButton(action: onBack).padding(.leading, -4) }
                    Text("Sleepy")
                        .font(VibeFont.title)
                        .foregroundStyle(VibeColor.text1)
                }
                // Clear of the corner buttons.
                .padding(.trailing, VibeMetrics.cornerButton + cornerSpacing + VibeMetrics.toggle.width + 8)
                VibeStatusLine(isActive ? "Mac e ecrã acordados" : "Sleep normal",
                               color: isActive ? tint : VibeColor.dotOff)
                Text(statusLine)
                    .font(VibeFont.body)
                    .foregroundStyle(VibeColor.text3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 72)
        .vibeCard(padding: VibeSpacing.cardPadding)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: cornerSpacing) {
                VibeOwnIconButton(showsOwnIcon: showsOwnIcon, action: onToggleOwnIcon)
                Toggle("Impedir sleep", isOn: Binding(
                    get: { isActive },
                    set: { on in if on != isActive { onToggleSleep() } }))
                    .toggleStyle(VibeToggleStyle(tint: tint))
                    .accessibilityLabel("Impedir sleep")
            }
            .padding(VibeSpacing.cardPadding)
        }
        .animation(VibeMotion.standard, value: isActive)
    }

    private var statusLine: String {
        if !isActive { return "O Mac dorme normalmente." }
        if let autoOffText { return autoOffText }
        return "O ecrã não se apaga. De tampa fechada, o Mac continua acordado."
    }

    // MARK: - Auto-off row

    /// A duração é a definição que se mexe com frequência, por isso vive aqui e
    /// não dentro das Definições — o "Iniciar no login" ficou lá, é de uma vez só.
    private var autoOffRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(VibeColor.text3)
            Text("Desligar sozinho")
                .font(VibeFont.body)
                .foregroundStyle(VibeColor.text2)
            Spacer(minLength: 8)
            VibeMenuPicker("Desligar sozinho",
                           selection: Binding(get: { autoOffMinutes }, set: { onChangeAutoOff($0) }),
                           options: Self.autoOffChoices,
                           offscreen: offscreen)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 36)
    }

    private static let autoOffChoices = SleepController.autoOffOptions.map {
        VibeMenuPicker<Int>.Option($0.minutes, title: $0.title, label: $0.short)
    }
}

/// A notice with no action, wrapping to as many lines as it needs. HoneDesign's
/// `VibeNoticeStrip` always has a button and clips to one line, so this wears the
/// same strip look from the same tokens.
private struct WarningStrip: View {
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: VibeRadius.strip, style: .continuous)
        HStack(alignment: .top, spacing: 8) {
            VibeDot(VibeColor.warning).padding(.top, 5)
            Text(text)
                .font(VibeFont.body)
                .foregroundStyle(VibeColor.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VibeColor.card, in: shape)
        .overlay(shape.strokeBorder(VibeColor.cardBorder, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preview fixtures

/// Entry point for Hone's offscreen preview renders (fake values, no pmset).
public enum SleepyPreview {
    @MainActor
    public static func panel(isActive: Bool, passwordlessInstalled: Bool = true,
                             warning: String? = nil,
                             back: (() -> Void)? = nil) -> AnyView {
        AnyView(MenuPanelContent(
            isActive: isActive,
            autoOffText: isActive ? "Desliga sozinho às 23:40" : nil,
            autoOffMinutes: 60,
            passwordlessInstalled: passwordlessInstalled,
            showsOwnIcon: true,
            warning: warning,
            offscreen: true,
            onBack: back))
    }

    /// The tool's page in Settings, with the stored values.
    @MainActor
    public static func settings() -> AnyView {
        AnyView(SleepySettingsView(model: SettingsModel()))
    }
}
