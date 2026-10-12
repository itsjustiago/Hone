import SwiftUI
import AppKit
import HoneDesign

/// Live state the menu-bar panel reflects. Populated by `SleepyTool` right
/// before the panel shows so the toggle, auto-off and permissions stay fresh.
final class SleepMenuModel: ObservableObject {
    @Published var isActive = false
    @Published var autoOffText: String?
    @Published var autoOffMinutes = SleepController.autoOffMinutes
    @Published var batteryThreshold = SleepController.batteryThreshold
    /// What happens when the lid closes; the picker snaps back if a change is refused.
    @Published var sleepMode = SleepController.sleepMode
    /// Why Sleepy last turned itself off, shown while it's off (nil = it didn't).
    @Published var stopReasonText: String?
    @Published var passwordlessInstalled = PrivilegedAccess.isInstalled
    /// Honest warning when the lid-closed guarantee is gone (see `DisableSleepGuard`).
    @Published var warning: String?
    /// Mirrors `SleepyTool.showsOwnMenuBarIcon` so the detach/attach button
    /// swaps its glyph live.
    @Published var showsOwnIcon = true
    /// Watts and battery under the status text ("Bateria 64 % · a gastar 7,2 W").
    /// nil on a Mac without a battery: the line isn't drawn.
    @Published var powerText: String?
    /// "sessão SSH ativa" while a remote session keeps Sleepy on (nil = it's on by hand, or off).
    @Published var remoteSessionText: String?
}

/// The Sleepy panel, shown either from its own menu-bar icon or inside Hone's
/// popover. App-level rows (quit, updates, version) belong to Hone now. Reads
/// the live model and hands plain values to `MenuPanelContent`.
struct MenuPanel: View {
    @ObservedObject var model: SleepMenuModel

    var onToggleSleep: () -> Void
    var onEnablePasswordless: () -> Void
    var onChangeAutoOff: (Int) -> Void
    var onChangeBatteryThreshold: (Int) -> Void
    var onChangeSleepMode: (SleepMode) -> Void
    var onExtend: () -> Void
    var onSettings: () -> Void
    /// Non-nil when hosted inside Hone's popover: the header shows a back chevron.
    var onBack: (() -> Void)?
    var onToggleOwnIcon: () -> Void
    /// The panel is on screen: the host starts and stops the power readout.
    var onAppear: () -> Void = {}
    var onDisappear: () -> Void = {}

    var body: some View {
        MenuPanelContent(
            isActive: model.isActive,
            autoOffText: model.autoOffText,
            autoOffMinutes: model.autoOffMinutes,
            batteryThreshold: model.batteryThreshold,
            stopReasonText: model.stopReasonText,
            passwordlessInstalled: model.passwordlessInstalled,
            showsOwnIcon: model.showsOwnIcon,
            warning: model.warning,
            onBack: onBack,
            onToggleSleep: onToggleSleep,
            onEnablePasswordless: onEnablePasswordless,
            onChangeAutoOff: onChangeAutoOff,
            onChangeBatteryThreshold: onChangeBatteryThreshold,
            onSettings: onSettings,
            onToggleOwnIcon: onToggleOwnIcon,
            sleepMode: model.sleepMode,
            onChangeSleepMode: onChangeSleepMode,
            onExtend: onExtend,
            powerText: model.powerText,
            remoteSessionText: model.remoteSessionText)
            .onAppear(perform: onAppear)
            .onDisappear(perform: onDisappear)
    }
}

/// Values in, closures out, so it renders offscreen from fake data.
struct MenuPanelContent: View {
    let isActive: Bool
    let autoOffText: String?
    let autoOffMinutes: Int
    let batteryThreshold: Int
    let stopReasonText: String?
    let passwordlessInstalled: Bool
    let showsOwnIcon: Bool
    let warning: String?
    /// Offscreen renders can't draw AppKit views, which the auto-off menu is anchored to.
    var offscreen = false
    var onBack: (() -> Void)?
    var onToggleSleep: () -> Void = {}
    var onEnablePasswordless: () -> Void = {}
    var onChangeAutoOff: (Int) -> Void = { _ in }
    var onChangeBatteryThreshold: (Int) -> Void = { _ in }
    var onSettings: () -> Void = {}
    var onToggleOwnIcon: () -> Void = {}
    var sleepMode: SleepMode = .lidClosedAwake
    var onChangeSleepMode: (SleepMode) -> Void = { _ in }
    var onExtend: () -> Void = {}
    var powerText: String?
    /// Sleepy was turned on by a remote session: no deadline, the status line says which one.
    var remoteSessionText: String?

    private var tint: Color { VibeToolColor.sleepy }
    private let blobHeight: CGFloat = 50
    /// Gap between the own-icon button and the switch in the card's corner.
    private let cornerSpacing: CGFloat = 8

    var body: some View {
        VStack(spacing: VibeSpacing.cardGap) {
            heroCard

            if let warning { WarningStrip(text: warning) }

            // Só o modo "fica acordado" usa o pmset disablesleep.
            if sleepMode.usesDisableSleep, !passwordlessInstalled {
                VibeNoticeStrip("Ligar sem password", color: VibeColor.warning,
                                actionTitle: "Ativar…", action: onEnablePasswordless)
                    .help("Instala uma regra restrita para não pedir password a cada toggle.")
            }

            VStack(alignment: .leading, spacing: 0) {
                modeRow
                autoOffRow
                batteryRow
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
                VibeStatusLine(isActive ? awakeLine : "Sleep normal",
                               color: isActive ? tint : VibeColor.dotOff)
                Text(statusLine)
                    .font(VibeFont.body)
                    .foregroundStyle(VibeColor.text3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let powerText {
                    Text(powerText)
                        .font(VibeFont.caption)
                        .foregroundStyle(VibeColor.text3)
                        .lineLimit(1)
                        .monospacedDigit()
                }
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

    private var awakeLine: String {
        sleepMode.usesDisableSleep ? "Mac e ecrã acordados" : "Ecrã acordado"
    }

    private var statusLine: String {
        if !isActive { return stopReasonText ?? "O Mac dorme normalmente." }
        if let remoteSessionText { return "Acordado — \(remoteSessionText)" }
        if let autoOffText { return autoOffText }
        return sleepMode.usesDisableSleep
            ? "O ecrã não se apaga. De tampa fechada, o Mac continua acordado."
            : "O ecrã não se apaga. Ao fechar a tampa, o Mac dorme."
    }

    // MARK: - Picker rows

    /// O que acontece com a tampa fechada: o Mac fica acordado (pmset) ou dorme.
    private var modeRow: some View {
        pickerRow(symbol: "laptopcomputer", title: "Tampa fechada",
                  selection: sleepMode, onChange: onChangeSleepMode, options: Self.modeChoices)
    }

    /// A duração é a definição que se mexe com frequência, por isso vive aqui e
    /// não dentro das Definições — o "Iniciar no login" ficou lá, é de uma vez só.
    /// Com prazo a correr, o "+1 h" adia-o sem abrir o picker.
    private var autoOffRow: some View {
        pickerRow(symbol: "timer", title: "Desligar sozinho",
                  selection: autoOffMinutes, onChange: onChangeAutoOff, options: Self.autoOffChoices) {
            if isActive, autoOffMinutes > 0, remoteSessionText == nil {
                Button("+1 h", action: onExtend)
                    .buttonStyle(VibeButtonStyle())
                    .controlSize(.small)
                    .help("Adia o desligar sozinho em 1 hora")
                    .accessibilityLabel("Mais 1 hora")
            }
        }
    }

    /// O limite de bateria a que o Sleepy se desliga sozinho, ao lado da duração.
    private var batteryRow: some View {
        pickerRow(symbol: "battery.25percent", title: "Bateria mínima",
                  selection: batteryThreshold, onChange: onChangeBatteryThreshold, options: Self.batteryChoices)
    }

    private func pickerRow<Value: Hashable, Accessory: View>(
        symbol: String, title: String, selection: Value,
        onChange: @escaping (Value) -> Void,
        options: [VibeMenuPicker<Value>.Option],
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(VibeColor.text3)
            Text(title)
                .font(VibeFont.body)
                .foregroundStyle(VibeColor.text2)
            Spacer(minLength: 8)
            accessory()
            VibeMenuPicker(title,
                           selection: Binding(get: { selection }, set: { onChange($0) }),
                           options: options,
                           offscreen: offscreen)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 36)
    }

    private static let modeChoices = SleepMode.allCases.map {
        VibeMenuPicker<SleepMode>.Option($0, title: $0.title, label: $0.short)
    }

    private static let autoOffChoices = SleepController.autoOffOptions.map {
        VibeMenuPicker<Int>.Option($0.minutes, title: $0.title, label: $0.short)
    }

    private static let batteryChoices = SleepController.batteryOptions.map {
        VibeMenuPicker<Int>.Option($0.percent, title: $0.title, label: $0.short)
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
                             batteryThreshold: Int = 20,
                             stopReasonText: String? = nil,
                             displayOnly: Bool = false,
                             powerText: String? = nil,
                             remoteSessionText: String? = nil,
                             back: (() -> Void)? = nil) -> AnyView {
        AnyView(MenuPanelContent(
            isActive: isActive,
            autoOffText: isActive && remoteSessionText == nil ? "Desliga sozinho às 23:40" : nil,
            autoOffMinutes: 60,
            batteryThreshold: batteryThreshold,
            stopReasonText: stopReasonText,
            passwordlessInstalled: passwordlessInstalled,
            showsOwnIcon: true,
            warning: warning,
            offscreen: true,
            onBack: back,
            sleepMode: displayOnly ? .displayOnly : .lidClosedAwake,
            powerText: powerText,
            remoteSessionText: remoteSessionText))
    }

    /// The tool's page in Settings, with the stored values.
    @MainActor
    public static func settings() -> AnyView {
        AnyView(SleepySettingsView(model: SettingsModel()))
    }
}
