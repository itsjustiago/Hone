import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Tampa e ecrãs num instante. Com um ecrã externo e a tampa fechada o Mac
/// está em uso (clamshell); só tampa fechada *sem* externo é "ninguém a ver".
struct LidState: Equatable {
    var lidClosed: Bool
    var externalDisplay: Bool

    var closedWithoutExternal: Bool { lidClosed && !externalDisplay }

    /// Uma leitura falhada da tampa (`nil`) nunca conta como fechada.
    static func from(clamshell: Bool?, externalDisplay: Bool) -> LidState {
        LidState(lidClosed: clamshell ?? false, externalDisplay: externalDisplay)
    }
}

/// Estabilização: uma mudança só passa depois de a leitura se manter igual
/// durante `interval`, para não reagir a uma tampa a meio de fechar.
struct LidDebounce {
    let interval: TimeInterval
    private(set) var delivered: LidState?
    private var candidate: (state: LidState, since: Date)?

    init(interval: TimeInterval) { self.interval = interval }

    var isPending: Bool { candidate != nil }

    /// Regista uma leitura. Devolve o estado a entregar quando estabilizou.
    mutating func observe(_ state: LidState, at now: Date) -> LidState? {
        if state == delivered { candidate = nil; return nil }
        if candidate?.state != state { candidate = (state, now) }
        guard let since = candidate?.since, now.timeIntervalSince(since) >= interval else { return nil }
        delivered = state
        candidate = nil
        return state
    }
}

/// Lê e segue a tampa e os ecrãs, sem `ioreg` nem outros processos.
///
/// Três fontes, todas no main: a notificação de clamshell do IOPMrootDomain
/// (imediata), a reconfiguração de ecrãs do CoreGraphics e um polling de 2s
/// como recurso (uma notificação perdida não pode deixar o painel aceso).
final class LidMonitor {
    /// `kIOPMMessageClamshellStateChange` = iokit_family_msg(sub_iokit_powermanagement, 0x100).
    /// É uma macro, por isso o Swift não a importa.
    static let clamshellStateChangeMessage: UInt32 = 0xE003_4100
    static let pollInterval: TimeInterval = 2
    static let settleInterval: TimeInterval = 2

    private var onChange: ((LidState) -> Void)?
    private var onPoll: ((LidState) -> Void)?
    private var debounce = LidDebounce(interval: LidMonitor.settleInterval)
    private var pollTimer: Timer?
    private var settleTimer: Timer?
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var displayCallbackRegistered = false

    var isRunning: Bool { onChange != nil }

    // MARK: - Leituras (puras, baratas)

    /// `AppleClamshellState` do IOPMrootDomain. `nil` se não houver tampa ou a leitura falhar.
    static func readClamshell() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return value as? Bool
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func externalDisplayConnected() -> Bool {
        onlineDisplays().contains { CGDisplayIsBuiltin($0) == 0 }
    }

    static func current() -> LidState {
        .from(clamshell: readClamshell(), externalDisplay: externalDisplayConnected())
    }

    /// Só se apaga o painel quando ninguém o pode estar a ver.
    static func shouldDim(_ state: LidState) -> Bool { state.closedWithoutExternal }

    // MARK: - Seguir mudanças

    /// `onChange` recebe cada estado estabilizado (o primeiro também, para
    /// apanhar uma tampa já fechada no arranque). `onPoll` recebe cada leitura.
    func start(onPoll: ((LidState) -> Void)? = nil, onChange: @escaping (LidState) -> Void) {
        stop()
        self.onChange = onChange
        self.onPoll = onPoll
        debounce = LidDebounce(interval: Self.settleInterval)
        startClamshellNotification()
        startDisplayCallback()

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.check(fromPoll: true)
        }
        timer.tolerance = 0.5
        // .common para continuar a correr enquanto um menu/popover está aberto.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        check(fromPoll: true)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        settleTimer?.invalidate()
        settleTimer = nil
        if notifier != 0 {
            IOObjectRelease(notifier)
            notifier = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(Self.displayCallback, Unmanaged.passUnretained(self).toOpaque())
            displayCallbackRegistered = false
        }
        onChange = nil
        onPoll = nil
    }

    private func check(fromPoll: Bool = false) {
        guard isRunning else { return }
        let state = Self.current()
        if fromPoll { onPoll?(state) }
        if let settled = debounce.observe(state, at: Date()) {
            settleTimer?.invalidate()
            settleTimer = nil
            onChange?(settled)
        } else if debounce.isPending, settleTimer == nil {
            scheduleSettleCheck()
        }
    }

    /// Volta a ler logo a seguir ao fim da janela de estabilização, em vez de
    /// esperar pelo próximo poll.
    private func scheduleSettleCheck() {
        let timer = Timer(timeInterval: Self.settleInterval + 0.1, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.settleTimer = nil
            self.check()
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    // MARK: - IOKit (tampa)

    private func startClamshellNotification() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            NSLog("Sleepy: sem notificações da tampa — fica só o polling")
            return
        }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else {
            IONotificationPortDestroy(port)
            NSLog("Sleepy: IOPMrootDomain não encontrado — fica só o polling")
            return
        }
        defer { IOObjectRelease(root) }
        let result = IOServiceAddInterestNotification(
            port, root, kIOGeneralInterest, Self.interestCallback,
            Unmanaged.passUnretained(self).toOpaque(), &notifier)
        guard result == kIOReturnSuccess else {
            IONotificationPortDestroy(port)
            notifier = 0
            NSLog("Sleepy: falha a seguir a tampa (\(result)) — fica só o polling")
            return
        }
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        notifyPort = port
    }

    private static let interestCallback: IOServiceInterestCallback = { refCon, _, messageType, _ in
        guard messageType == LidMonitor.clamshellStateChangeMessage, let refCon else { return }
        Unmanaged<LidMonitor>.fromOpaque(refCon).takeUnretainedValue().check()
    }

    // MARK: - CoreGraphics (ecrã externo)

    private func startDisplayCallback() {
        let error = CGDisplayRegisterReconfigurationCallback(Self.displayCallback, Unmanaged.passUnretained(self).toOpaque())
        displayCallbackRegistered = error == .success
    }

    private static let displayCallback: CGDisplayReconfigurationCallBack = { _, flags, refCon in
        // O início de uma reconfiguração ainda não diz nada; espera-se pelo fim.
        guard !flags.contains(.beginConfigurationFlag), let refCon else { return }
        let monitor = Unmanaged<LidMonitor>.fromOpaque(refCon).takeUnretainedValue()
        DispatchQueue.main.async { monitor.check() }
    }
}
