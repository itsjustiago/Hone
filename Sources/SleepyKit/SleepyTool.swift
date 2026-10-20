import AppKit
import Combine
import SwiftUI

/// Sleepy packaged as a tool a host app (Hone) can embed.
///
/// Holds what the standalone app's `AppDelegate` used to do — restoring the
/// sleep block on launch, keeping the menu model and icon in sync, releasing
/// everything on quit — but owns no status item, window or app lifecycle. The
/// host decides where the panel and settings are shown, and never sees
/// `NSApp.terminate` / `setActivationPolicy` from here.
@MainActor
public final class SleepyTool {
    private let menuModel = SleepMenuModel()
    private let settingsModel = SettingsModel()

    /// Legacy key from the standalone app's `MenuBarIcon`, kept so the user's
    /// "show in menu bar" choice carries over.
    private static let showIconKey = "showMenuBarIcon"

    public private(set) var isRunning = false

    /// Refreshes the watts line while the panel is on screen, never otherwise.
    private var powerTimer: Timer?
    private var powerReadInFlight = false
    /// The last watts line read, shown at once when the panel opens (the IORegistry
    /// read never runs on the main thread); the fresh one replaces it a moment later.
    private var lastPowerText: String?
    private var cancellables = Set<AnyCancellable>()
    private static let powerQueue = DispatchQueue(label: "sleepy.power", qos: .utility)
    private static let powerInterval: TimeInterval = 2

    /// Refreshes the countdown next to the icon while there is one to show.
    private var countdownTimer: Timer?
    /// The countdown the host was last told about, so a tick only notifies on a change.
    private var lastCountdownText: String?
    private static let countdownInterval: TimeInterval = 15

    /// Called whenever `menuBarImage` changes (sleep block on/off).
    public var onMenuBarImageChange: (() -> Void)?

    public init() {
        menuModel.showsOwnIcon = showsOwnMenuBarIcon
        // The panel and Settings show the same Low Power Mode toggle and rule state:
        // whatever changes in Settings reaches the panel straight away (the other
        // way round, `refreshMenuModel()` refreshes the Settings model).
        settingsModel.$lowPowerWhenLidClosed
            .sink { [menuModel] in menuModel.lowPowerWhenLidClosed = $0 }
            .store(in: &cancellables)
        settingsModel.$lowPowerRuleAllowed
            .sink { [menuModel] in menuModel.lowPowerRuleAllowed = $0 }
            .store(in: &cancellables)
        // A cor e a contagem mudam o desenho do ícone, e a contagem também o timer.
        settingsModel.onIconChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshMenuModel()
                self?.onMenuBarImageChange?()
            }
        }
    }

    // MARK: - Lifecycle

    /// What `applicationDidFinishLaunching` used to do. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        SleepController.shared.toolRunning = true
        SleepController.shared.onStateChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshMenuModel()
                self?.onMenuBarImageChange?()
            }
        }
        // "Mais 1 h" no aviso de 5 min antes do auto-desligar (já chega no main).
        // Só para a sessão que mandou o aviso.
        Notifier.shared.onAction = { action, userInfo in
            if action == Notifier.extendActionID { SleepController.shared.extendSession(fromNotification: userInfo) }
        }
        Notifier.shared.activate()
        SleepController.shared.restoreOnLaunch()
    }

    /// What `applicationWillTerminate` used to do: hand sleep back to the
    /// system so the Mac is never left stuck awake. Idempotent.
    ///
    /// If turning the block off fails (no passwordless access and the admin
    /// prompt was cancelled), the Mac is still kept awake — so the tool stays
    /// running and visible instead of pretending it stopped.
    public func stop() {
        guard isRunning else { return }
        SleepController.shared.disable()
        guard !SleepController.shared.isActive else {
            refreshMenuModel()
            onMenuBarImageChange?()
            return
        }
        SleepController.shared.onStateChange = nil
        Notifier.shared.onAction = nil
        isRunning = false
        SleepController.shared.toolRunning = false
        stopPowerReadout()
        stopCountdownTimer()
        SleepController.shared.stopRemoteMonitor()
        // O LPM e o som repostos pelo `disable()` ainda podem estar na fila.
        LidExtras.flush()
        refreshMenuModel()
        onMenuBarImageChange?()
    }

    /// Like `stop()`, but leaves the sleep block armed and its state persisted
    /// for whoever runs Sleepy next: Hone relaunching (rebuild/update) or the
    /// old app taking over. Idempotent. Never prompts.
    public func stopKeepingState() {
        guard isRunning else { return }
        SleepController.shared.onStateChange = nil
        Notifier.shared.onAction = nil
        SleepController.shared.suspend()
        isRunning = false
        SleepController.shared.toolRunning = false
        stopPowerReadout()
        stopCountdownTimer()
        LidExtras.flush()
        refreshMenuModel()
        onMenuBarImageChange?()
    }

    /// The host is about to quit the standalone Sleepy, which turns the block
    /// off on its way out. Remember that it was on so the next `start()`
    /// re-arms it (silently, when passwordless access is installed).
    public func legacyTwinWillQuit() {
        SleepController.shared.stashForHandoff()
    }

    // MARK: - Menu bar

    /// Sun while sleep is blocked, moon otherwise. Template (adapts to the menu bar's
    /// appearance) unless an accent colour is on and Sleepy is running; then the
    /// sun is painted in it. Both symbols sit centred in the same box, so the
    /// status item (and the popover pointing at it) doesn't move on a toggle. The
    /// optional countdown goes to the right of that box.
    public var menuBarImage: NSImage {
        let active = SleepController.shared.isActive
        let countdown = countdownText()
        let image = MenuBarIcon.image(
            symbol: Self.symbolImage(active ? Self.awakeSymbol : Self.asleepSymbol),
            box: Self.menuBarImageSize,
            accent: MenuBarIcon.accentColor(MenuBarIconSettings.accent, isActive: active),
            countdown: countdown)
        let remaining = countdown.map { ", desliga dentro de \($0)" } ?? ""
        image.accessibilityDescription = "Sleepy — \(liveStatus)\(remaining)"
        return image
    }

    private static let awakeSymbol = "sun.max.fill"
    private static let asleepSymbol = "moon.zzz"

    private static func symbolImage(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    /// The larger of the two symbols, in both dimensions.
    private static let menuBarImageSize: NSSize = {
        let sizes = [awakeSymbol, asleepSymbol].map { symbolImage($0).size }
        return NSSize(width: (sizes.map(\.width).max() ?? 18).rounded(.up),
                      height: (sizes.map(\.height).max() ?? 18).rounded(.up))
    }()

    /// Se está a impedir o sleep agora. O switch do Hone só diz se a
    /// ferramenta está ativa; o cabeçalho usa isto para o estado real.
    /// Muda junto com `onMenuBarImageChange`.
    public var isKeepingAwake: Bool { SleepController.shared.isActive }

    /// O estado real numa expressão curta, em minúsculas: "sleep normal",
    /// "Mac e ecrã acordados" ou "ecrã acordado".
    public var liveStatus: String {
        guard SleepController.shared.isActive else { return "sleep normal" }
        return SleepController.shared.activeMode == .lidClosedAwake ? "Mac e ecrã acordados" : "ecrã acordado"
    }

    /// Whether the user wants Sleepy under its own menu-bar icon. Stored under
    /// the standalone app's key (absent = first run = shown).
    public var showsOwnMenuBarIcon: Bool {
        get { SleepyDefaults.store.object(forKey: Self.showIconKey) as? Bool ?? true }
        set {
            SleepyDefaults.store.set(newValue, forKey: Self.showIconKey)
            menuModel.showsOwnIcon = newValue
            syncCountdownTimer()
        }
    }

    // MARK: - Panel

    /// Mirror the live system state into the panel's model before it shows.
    /// `reassert()` first: it re-checks `SleepDisabled` off the main thread and,
    /// if the block dropped behind our back, fires `onStateChange` (wired in
    /// `start()`) once it knows, which also updates the icon and the warning.
    public func panelWillShow() {
        SleepController.shared.reassert()
        refreshMenuModel()
        // `sudo -n -l` off the main thread, and only with the toggle on.
        settingsModel.refreshLowPowerRule()
        // The last reading is there on the first frame; the fresh one comes from
        // `startPowerReadout()` (started here too, as `onAppear` is not reliable
        // inside an NSPopover), off the main thread.
        menuModel.powerText = lastPowerText
        startPowerReadout()
    }

    /// The host closed the panel (popover or own menu): stop the watts readout.
    /// SwiftUI's `onDisappear` is not reliable inside an `NSPopover`. Idempotent.
    public func panelDidClose() {
        stopPowerReadout()
    }

    public func makeMenuPanel(back: (() -> Void)?,
                              dismiss: @escaping () -> Void,
                              openSettings: @escaping () -> Void,
                              toggleOwnIcon: @escaping () -> Void) -> AnyView {
        AnyView(MenuPanel(
            model: menuModel,
            onToggleSleep: { [weak self] in self?.toggleSleep() },
            onEnablePasswordless: { [weak self] in
                _ = PrivilegedAccess.install()
                self?.refreshMenuModel()
            },
            onChangeAutoOff: { [weak self] minutes in
                SleepController.autoOffMinutes = minutes
                self?.refreshMenuModel()
            },
            onChangeBatteryThreshold: { [weak self] percent in
                SleepController.batteryThreshold = percent
                self?.refreshMenuModel()
            },
            onChangeSleepMode: { [weak self] mode in
                // Recusada (prompt de admin cancelado), o modelo volta ao modo
                // guardado e o picker recua.
                SleepController.shared.setSleepMode(mode)
                self?.refreshMenuModel()
            },
            onChangeLowPower: { [weak self] on in
                LidExtras.lowPowerWhenLidClosed = on
                // Syncs the Settings model (and so its toggle); then the sudoers
                // check, which only matters with the toggle on.
                self?.refreshMenuModel()
                self?.settingsModel.refreshLowPowerRule()
            },
            onUpdateRule: { [weak self] in
                // Admin prompt, like `onEnablePasswordless`; it re-checks the rule.
                self?.settingsModel.updateRule()
                self?.refreshMenuModel()
            },
            onChangeWaitForClaude: { [weak self] on in
                // Turning it on may turn Sleepy on (admin prompt). Refused, nothing is
                // armed and no callback fires: resync so the switch snaps back.
                SleepController.shared.setWaitForClaude(on)
                self?.refreshMenuModel()
                self?.onMenuBarImageChange?()
            },
            onExtend: { SleepController.shared.extendSession() },
            onSettings: { dismiss(); openSettings() },
            onBack: back,
            onToggleOwnIcon: toggleOwnIcon,
            onAppear: { [weak self] in self?.startPowerReadout() },
            onDisappear: { [weak self] in self?.stopPowerReadout() }))
    }

    // MARK: - Settings

    public func makeSettingsView() -> AnyView {
        AnyView(SleepySettingsView(model: settingsModel))
    }

    // MARK: - Power readout

    /// Every 2 s while the panel is visible. Idempotent, so a repeated
    /// `onAppear` doesn't stack timers.
    private func startPowerReadout() {
        guard powerTimer == nil else { return }
        let timer = Timer(timeInterval: Self.powerInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePowerReadout() }
        }
        timer.tolerance = 0.5
        // .common to keep ticking while a menu/popover is tracking.
        RunLoop.main.add(timer, forMode: .common)
        powerTimer = timer
        updatePowerReadout()
    }

    private func stopPowerReadout() {
        powerTimer?.invalidate()
        powerTimer = nil
    }

    /// The IORegistry read happens off the main thread; a result that arrives
    /// after the panel closed is dropped.
    private func updatePowerReadout() {
        guard !powerReadInFlight else { return }
        powerReadInFlight = true
        Self.powerQueue.async { [weak self] in
            let text = PowerReadout.currentText()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.powerReadInFlight = false
                    // Cached even if the panel closed meanwhile; only shown while it's open.
                    self.lastPowerText = text
                    if self.powerTimer != nil, self.menuModel.powerText != text { self.menuModel.powerText = text }
                }
            }
        }
    }

    // MARK: - Countdown

    /// O que o ícone mostra ao lado do símbolo: só com a opção ligada e um prazo
    /// (`autoOffDate` é nil com o Sleepy desligado e sem prazo).
    private func countdownText() -> String? {
        guard MenuBarIconSettings.showsCountdown else { return nil }
        return MenuBarIcon.countdownText(until: SleepController.shared.autoOffDate, now: Date())
    }

    /// Liga ou desliga o timer da contagem conforme haja algo para contar e alguém
    /// a ver o ícone, e acerta já o texto (um prazo novo ou a opção desligada não
    /// esperam pelo próximo tick). Idempotente, para chamar em qualquer mudança.
    private func syncCountdownTimer() {
        let wanted = isRunning && SleepController.shared.isActive && MenuBarIconSettings.showsCountdown
            && showsOwnMenuBarIcon && SleepController.shared.autoOffDate != nil
        if wanted {
            if countdownTimer == nil {
                let timer = Timer(timeInterval: Self.countdownInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshCountdownImage() }
                }
                timer.tolerance = 5
                // .common to keep ticking while a menu/popover is tracking.
                RunLoop.main.add(timer, forMode: .common)
                countdownTimer = timer
            }
        } else {
            stopCountdownTimer()
        }
        refreshCountdownImage()
    }

    private func stopCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// Quase todos os ticks (15 s) caem no mesmo minuto: só avisa o host se o texto mudou.
    private func refreshCountdownImage() {
        let text = countdownText()
        guard text != lastCountdownText else { return }
        lastCountdownText = text
        onMenuBarImageChange?()
    }

    // MARK: - Private

    private func refreshMenuModel() {
        menuModel.isActive = SleepController.shared.isActive
        menuModel.autoOffText = autoOffText()
        menuModel.autoOffMinutes = SleepController.autoOffMinutes
        menuModel.batteryThreshold = SleepController.batteryThreshold
        // O modo em uso: numa sessão do gatilho remoto pode não ser o guardado.
        menuModel.sleepMode = SleepController.shared.activeMode
        menuModel.remoteSessionText = SleepController.shared.remoteSessionLabel
        menuModel.waitForClaude = SleepController.shared.isActive && SleepController.shared.waitsForClaude
        menuModel.claudeWaitText = SleepController.shared.claudeWaitText
        menuModel.stopReasonText = stopReasonText()
        menuModel.passwordlessInstalled = PrivilegedAccess.isInstalled
        menuModel.warning = SleepController.shared.lidWarning
        menuModel.showsOwnIcon = showsOwnMenuBarIcon
        settingsModel.refresh()
        syncCountdownTimer()
    }

    private func autoOffText() -> String? {
        guard let off = SleepController.shared.autoOffDate else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        // Prazo passado com o Sleepy ainda ligado = o auto-desligar falhou.
        if off <= Date() { return "Não desligou às \(fmt.string(from: off)) — desliga à mão" }
        return "Desliga sozinho às \(fmt.string(from: off))"
    }

    /// Com o Sleepy desligado sozinho, o motivo e a hora para a linha de estado.
    private func stopReasonText() -> String? {
        guard !SleepController.shared.isActive, let stop = SleepController.shared.lastStop else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "Desligou-se às \(fmt.string(from: stop.at)) — \(stop.reason.panelReason)."
    }

    private func toggleSleep() {
        if SleepController.shared.isActive {
            SleepController.shared.disable()
        } else {
            SleepController.shared.enable()
        }
        // A cancelled admin prompt changes nothing and fires no callback —
        // resync so the switch snaps back.
        refreshMenuModel()
        onMenuBarImageChange?()
    }
}
