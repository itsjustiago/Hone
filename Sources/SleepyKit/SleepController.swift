import AppKit
import Foundation
import IOKit.pwr_mgt

/// Núcleo do Sleepy: impede o Mac de dormir, incluindo com a tampa fechada.
///
/// São precisos **quatro** mecanismos, e cobrem coisas diferentes:
///
/// 1. `pmset -a disablesleep` — sobrevive ao lid-close sem precisar de ecrã
///    externo nem corrente, mas exige admin (prompt, ou a regra sudoers de
///    [[PrivilegedAccess]]).
/// 2. IOKit `PreventUserIdleDisplaySleep` (= `caffeinate -d`) — mantém o ecrã
///    aceso de tampa aberta, na corrente e em bateria. Evita também o bloqueio
///    automático (o macOS bloqueia quando o ecrã se apaga). De tampa fechada o
///    painel interno pode apagar-se na mesma, por hardware/firmware (IOPMLib:
///    "a user closing a portable's lid"); aí quem segura o Mac é o nº 1.
/// 3. IOKit `PreventUserIdleSystemSleep` (= `caffeinate -i`) — trava o sleep
///    por inatividade. Funciona em bateria. Não trava os ciclos de manutenção.
/// 4. IOKit `PreventSystemSleep` (= `caffeinate -s`) — trava o sistema de
///    dormir de forma mais forte, incluindo os `Maintenance Sleep` /
///    `Sleep Service Back to Sleep`. Só é respeitado na corrente (num portátil,
///    em bateria é ignorado — daí precisarmos também do nº 3). É a assertion
///    que o NoSleep usa.
///
/// Segurar (2) + (3) + (4) é o equivalente a `caffeinate -d -i -s`: cobre
/// bateria e corrente. O estado é persistido: um crash, um rebuild ou o auto-updater
/// relançam a app, e sem isso a proteção caía em silêncio a meio de uma tarefa
/// longa. Para não deixar o Mac acordado por esquecimento, há auto-desligar ao
/// fim de `autoOffMinutes` (default 8h) — e, se a tampa estiver fechada (sem
/// ecrã externo) nessa altura, mandamos o Mac dormir logo, que é o que a tampa
/// fechada quer dizer.
///
/// Desliga-se também sozinho por segurança — bateria no limite escolhido, ou o
/// Mac a aquecer de tampa fechada ([[PowerGuards]]) — e diz porquê (`lastStop`
/// no painel, notificação do sistema).
///
/// O `disablesleep` é confirmado de forma contínua (`verifySleepDisabled`, o
/// macOS pode repô-lo a 0 por fora) e, se o Hone morrer, um watchdog destacado
/// larga-o ([[CrashWatchdog]]).
///
/// Tampa fechada sem ecrã externo: o `disablesleep` deixa o painel interno
/// aceso dentro da tampa. Aí largamos a assertion de ecrã e apagamos painel e
/// teclado ([[LidDisplay]]); ao abrir a tampa ou ligar um externo, repomos.
final class SleepController {
    static let shared = SleepController()

    private(set) var isActive = false

    /// Chamado quando o estado muda sem ser por clique (restore, auto-off).
    var onStateChange: (() -> Void)?

    /// Aviso honesto quando o `SleepDisabled` caiu e a tampa fechada já não é
    /// garantida (ver [[DisableSleepGuard]]). O Sleepy continua ligado: as
    /// assertions seguram o Mac de tampa aberta.
    private(set) var lidWarning: String?

    /// As três assertions IOKit que seguramos em conjunto (ecrã, bateria, corrente).
    static let assertionTypes = [
        kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionTypePreventUserIdleSystemSleep,
        kIOPMAssertionTypePreventSystemSleep,
    ]
    /// Por tipo, para recriar só a que faltar.
    private var assertionIDs: [String: IOPMAssertionID] = [:]
    /// Tampa fechada sem ecrã externo: sem a assertion de ecrã e com o painel
    /// apagado. Só o `lidStateChanged` mexe nisto (e os testes).
    var lidDimmed = false
    private let lidMonitor = LidMonitor()
    private var autoOffTimer: Timer?
    /// O prompt de admin do auto-desligar foi recusado: as tentativas seguintes
    /// são só em silêncio, para não o repetir a cada 15s.
    private var autoOffPromptDeclined = false

    /// Porque é que o Sleepy se desligou sozinho, e quando. Só em memória: vive
    /// até o utilizador voltar a ligar (`enable()`).
    private(set) var lastStop: (reason: StopReason, at: Date)?

    // Bateria e temperatura (ver [[PowerGuards]]). Só enquanto o Sleepy está ligado.
    private let powerWatcher = PowerWatcher()
    private var batteryGuard = BatteryGuard(threshold: SleepController.batteryThreshold)
    private var thermalGuard = ThermalGuard()
    private var thermalRecheckTimer: Timer?

    // Verificação contínua do SleepDisabled (ver "Verificação contínua").
    /// Fila serial para o `pmset -g` e o `sudo -n` do verificador: nunca no main.
    private static let pmsetQueue = DispatchQueue(label: "sleepy.pmset", qos: .utility)
    private var verifyInFlight = false
    private var verifyKickoffTimer: Timer?
    private var verifyTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var disableSleepGuard = DisableSleepGuard()
    /// Única exceção ao "só no main": o verificador (fila `sleepy.pmset`) só pode
    /// repor o disablesleep enquanto isto for true. Sem isto, um `disable()` a
    /// meio de uma verificação podia ser desfeito logo a seguir, e o Mac ficava
    /// acordado sem o Sleepy o saber.
    private let restoreLock = NSLock()
    private var restoreAllowed = false

    private let activeKey = "sleepActive"
    private let activeSinceKey = "activeSince"
    private static let autoOffKey = "autoOffMinutes"
    private static let legacyAutoOffKey = "autoOffHours"

    /// Minutos até desligar sozinho. 0 = nunca. Antes disto a preferência era em
    /// horas — migra-se na primeira leitura para não perder a escolha do utilizador.
    static var autoOffMinutes: Int {
        get {
            let d = SleepyDefaults.store
            if let minutes = d.object(forKey: autoOffKey) as? Int { return minutes }
            if let hours = d.object(forKey: legacyAutoOffKey) as? Int {
                d.set(hours * 60, forKey: autoOffKey)
                return hours * 60
            }
            return 8 * 60
        }
        set {
            SleepyDefaults.store.set(newValue, forKey: autoOffKey)
            shared.scheduleAutoOff()
        }
    }

    /// As escolhas de auto-desligar, partilhadas pelo menu e pelas definições.
    /// `short` é a versão compacta, para a linha estreita do menu.
    struct AutoOffOption: Identifiable, Hashable {
        let minutes: Int
        let title: String
        let short: String
        var id: Int { minutes }
    }

    static let autoOffOptions: [AutoOffOption] = [
        .init(minutes: 10, title: "10 minutos", short: "10 min"),
        .init(minutes: 20, title: "20 minutos", short: "20 min"),
        .init(minutes: 30, title: "30 minutos", short: "30 min"),
        .init(minutes: 60, title: "1 hora", short: "1 h"),
        .init(minutes: 120, title: "2 horas", short: "2 h"),
        .init(minutes: 240, title: "4 horas", short: "4 h"),
        .init(minutes: 480, title: "8 horas", short: "8 h"),
        .init(minutes: 720, title: "12 horas", short: "12 h"),
        .init(minutes: 0, title: "Nunca", short: "Nunca"),
    ]

    private static let batteryThresholdKey = "batteryThreshold"

    /// Percentagem de bateria a que o Sleepy se desliga (só em bateria). 0 = nunca.
    static var batteryThreshold: Int {
        get { SleepyDefaults.store.object(forKey: batteryThresholdKey) as? Int ?? 20 }
        set {
            SleepyDefaults.store.set(newValue, forKey: batteryThresholdKey)
            // Com o Sleepy ligado e a bateria já abaixo do novo limite, desliga já.
            shared.checkPowerGuards(reason: "limiar")
        }
    }

    /// As escolhas de limite de bateria, partilhadas pelo menu e pelas definições.
    struct BatteryOption: Identifiable, Hashable {
        let percent: Int
        let title: String
        let short: String
        var id: Int { percent }
    }

    static let batteryOptions: [BatteryOption] = [
        .init(percent: 0, title: "Nunca", short: "Nunca"),
        .init(percent: 10, title: "10 %", short: "10 %"),
        .init(percent: 15, title: "15 %", short: "15 %"),
        .init(percent: 20, title: "20 %", short: "20 %"),
        .init(percent: 25, title: "25 %", short: "25 %"),
        .init(percent: 30, title: "30 %", short: "30 %"),
        .init(percent: 40, title: "40 %", short: "40 %"),
        .init(percent: 50, title: "50 %", short: "50 %"),
    ]

    /// Porque é que o Sleepy se desligou sozinho.
    enum StopReason: Equatable {
        case autoOff
        case battery(percent: Int)
        case thermal

        /// Para a notificação: "Sleepy desligou-se — <isto>."
        var notificationReason: String {
            switch self {
            case .autoOff: return "passou o tempo escolhido"
            case .battery(let percent): return "bateria a \(percent) %"
            case .thermal: return "o Mac estava a aquecer com a tampa fechada"
            }
        }

        /// Para o painel: "Desligou-se às HH:mm — <isto>."
        var panelReason: String {
            switch self {
            case .autoOff: return "passou o tempo escolhido"
            case .battery(let percent): return "bateria a \(percent) %"
            case .thermal: return "o Mac estava a aquecer"
            }
        }
    }

    private init() {}

    // MARK: - Estado real do sistema

    /// Lê o `SleepDisabled` do `pmset -g`. Não precisa de privilégios, e é a
    /// única fonte de verdade — o que julgamos ter feito pode não ter pegado.
    /// `nil` = leitura falhada: nunca conta como "desligado", nem desarma nada.
    /// Bloqueia até o `pmset` acabar — fora do main, salvo no arranque.
    static func systemSleepDisabled() -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let out = String(data: data, encoding: .utf8) else { return nil }
        return parseSleepDisabled(out)
    }

    /// A linha `SleepDisabled  <0|1>` do `pmset -g`. `nil` se não houver a linha
    /// ou se o valor não for 0/1.
    static func parseSleepDisabled(_ pmsetOutput: String) -> Bool? {
        for line in pmsetOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.first == "SleepDisabled" else { continue }
            switch fields.dropFirst().first {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        return nil
    }

    // MARK: - IOKit power assertions (ecrã + idle + system sleep)

    /// As que devem estar seguras agora: com o painel apagado, sem a de ecrã.
    private var wantedAssertionTypes: [String] {
        guard lidDimmed else { return Self.assertionTypes }
        return Self.assertionTypes.filter { $0 != kIOPMAssertionTypePreventUserIdleDisplaySleep }
    }

    /// Segura as três assertions (ecrã, idle, system) — só idle + system com
    /// `lidDimmed`, e aí larga a de ecrã. Sem privilégios. Idempotente: cria só
    /// as que faltam, por isso uma falha parcial não fica para sempre — a
    /// próxima chamada tenta de novo.
    @discardableResult
    func ensureAssertions() -> Bool {
        if lidDimmed { releaseAssertion(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep) }
        let wanted = wantedAssertionTypes
        for type in wanted where assertionIDs[type] == nil {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Sleepy: impedir sleep" as CFString,
                &id)
            if result == kIOReturnSuccess {
                assertionIDs[type] = id
            } else {
                NSLog("Sleepy: falha a criar a assertion \(type) (\(result))")
            }
        }
        return wanted.allSatisfy { assertionIDs[$0] != nil }
    }

    func releaseAssertion() {
        for id in assertionIDs.values { IOPMAssertionRelease(id) }
        assertionIDs.removeAll()
    }

    func releaseAssertion(ofType type: String) {
        guard let id = assertionIDs.removeValue(forKey: type) else { return }
        IOPMAssertionRelease(id)
    }

    // MARK: - pmset disablesleep (lid-close)

    /// Elevado via prompt AppleScript (Touch ID/password). Usado como fallback
    /// quando o acesso sem password ([[PrivilegedAccess]]) não está instalado.
    @discardableResult
    private func setDisableSleepPrompting(_ on: Bool) -> Bool {
        let value = on ? "1" : "0"
        let script = "do shell script \"pmset -a disablesleep \(value)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            NSLog("Sleepy: pmset disablesleep=\(value) falhou: \(error)")
        }
        return error == nil
    }

    /// Sem password primeiro (sem prompt); só cai no prompt de admin se a regra
    /// sudoers não estiver instalada.
    private func setDisableSleep(_ on: Bool, allowPrompt: Bool = true) -> Bool {
        if PrivilegedAccess.setDisableSleep(on) { return true }
        guard allowPrompt else { return false }
        return setDisableSleepPrompting(on)
    }

    // MARK: - Toggle

    func enable() {
        guard !isActive else { return }
        // Sem o disablesleep não há proteção de lid-close — se o utilizador
        // cancelar o prompt de admin, não fingimos que ficou ligado.
        guard setDisableSleep(true) else { return }
        if !ensureAssertions() {
            NSLog("Sleepy: falha a criar as power assertions — o ecrã ou o Mac podem adormecer")
        }
        isActive = true
        lastStop = nil
        activeSince = Date()
        SleepyDefaults.store.set(true, forKey: activeKey)
        setRestoreAllowed(true)
        startLidMonitor()
        startVerification()
        CrashWatchdog.start()
        scheduleAutoOff()
        Notifier.shared.requestAuthorizationIfNeeded()
        onStateChange?()
    }

    func disable(allowPrompt: Bool = true) {
        guard isActive else { return }
        // Antes do pmset: uma verificação em curso não pode repor o 1 por cima.
        setRestoreAllowed(false)
        guard setDisableSleep(false, allowPrompt: allowPrompt) else {
            setRestoreAllowed(true)
            return
        }
        stopLidMonitor()
        releaseAssertion()
        stopVerification()
        CrashWatchdog.stop()
        isActive = false
        clearPersisted()
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        onStateChange?()
    }

    /// Lets go of what this process holds (power assertions, auto-off timer)
    /// but leaves `pmset disablesleep` and the persisted state untouched, so
    /// whoever runs Sleepy next — Hone after a relaunch, or the old app — re-arms
    /// through `restoreOnLaunch`. Never prompts. O watchdog de crash também
    /// fica vivo: se ninguém pegar nisto, é ele que larga o disablesleep.
    func suspend() {
        setRestoreAllowed(false)
        stopLidMonitor()
        stopVerification()
        releaseAssertion()
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        isActive = false
    }

    /// Confere o estado real quando o painel se abre, sem bloquear o main:
    /// recria as assertions que faltem (sem privilégios) e deixa o verificador
    /// ler o `SleepDisabled` em segundo plano. Nunca mostra prompt.
    func reassert() {
        guard isActive else { return }
        if !ensureAssertions() {
            NSLog("Sleepy: falha a repor as power assertions — o ecrã ou o Mac podem adormecer")
        }
        verifySleepDisabled(reason: "painel")
    }

    // MARK: - Verificação contínua do SleepDisabled

    /// O macOS 26 pode repor `SleepDisabled` a 0 por fora, e aí o Mac adormece
    /// ao fechar a tampa com o ícone a dizer "ligado". Por isso confirma-se: 5 s
    /// depois de ligar, de 30 em 30 s, ao acordar, ao fechar a tampa e ao abrir o
    /// painel. A 0, repõe-se em silêncio (só o caminho sem password); se não
    /// der, o Sleepy fica ligado — as assertions seguram o Mac de tampa aberta —
    /// e o aviso diz a verdade. Uma leitura falhada nunca desarma nada.
    func verifySleepDisabled(reason: String) {
        guard isActive, !verifyInFlight else { return }
        verifyInFlight = true
        Self.pmsetQueue.async { [self] in
            let outcome = readAndRestore()
            DispatchQueue.main.async { self.finishVerification(outcome, reason: reason) }
        }
    }

    private enum VerifyOutcome { case unreadable, ok, skipped, restored, notRestored }

    /// Corre na fila `sleepy.pmset`, nunca no main.
    private func readAndRestore() -> VerifyOutcome {
        switch Self.systemSleepDisabled() {
        case nil: return .unreadable
        case true?: return .ok
        case false?:
            restoreLock.lock()
            defer { restoreLock.unlock() }
            guard restoreAllowed else { return .skipped }
            let set = PrivilegedAccess.setDisableSleep(true)
            let after = Self.systemSleepDisabled() ?? set
            return after ? .restored : .notRestored
        }
    }

    private func setRestoreAllowed(_ allowed: Bool) {
        restoreLock.lock()
        restoreAllowed = allowed
        restoreLock.unlock()
    }

    private func finishVerification(_ outcome: VerifyOutcome, reason: String) {
        verifyInFlight = false
        guard isActive else { return }
        let now = Date()
        switch outcome {
        case .unreadable, .skipped:
            break
        case .ok:
            disableSleepGuard.recordOK(at: now)
        case .restored:
            NSLog("Sleepy: SleepDisabled caiu (\(reason)) — reposto")
            disableSleepGuard.recordRestored(at: now)
        case .notRestored:
            NSLog("Sleepy: SleepDisabled caiu (\(reason)) — não deu para repor")
            disableSleepGuard.recordFailure(at: now)
        }
        publishWarning(disableSleepGuard.warning)
    }

    private func publishWarning(_ warning: String?) {
        guard warning != lidWarning else { return }
        lidWarning = warning
        // Só quando muda: um aviso novo notifica uma vez, não a cada verificação.
        if let warning { Notifier.shared.notify(warning) }
        onStateChange?()
    }

    private func startVerification() {
        stopVerification()
        // Pouco depois de ligar: apanha um pmset que não pegou.
        let kickoff = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            self?.verifyKickoffTimer = nil
            self?.verifySleepDisabled(reason: "após ligar")
        }
        let periodic = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.verifySleepDisabled(reason: "periódica")
            self?.checkPowerGuards(reason: "periódica")
        }
        periodic.tolerance = 5
        // .common para continuar a correr enquanto um menu/popover está aberto.
        RunLoop.main.add(kickoff, forMode: .common)
        RunLoop.main.add(periodic, forMode: .common)
        verifyKickoffTimer = kickoff
        verifyTimer = periodic
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.verifySleepDisabled(reason: "ao acordar")
            self?.checkPowerGuards(reason: "ao acordar")
        }
        startPowerGuards()
    }

    private func stopVerification() {
        verifyKickoffTimer?.invalidate()
        verifyKickoffTimer = nil
        verifyTimer?.invalidate()
        verifyTimer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        disableSleepGuard = DisableSleepGuard()
        lidWarning = nil
        stopPowerGuards()
    }

    // MARK: - Hand-off from the standalone app

    private static let handoffActiveSinceKey = "hone.handoff.activeSince"
    private static let handoffAtKey = "hone.handoff.at"
    /// A hand-off not picked up within this window is stale (the old app
    /// refused to quit and was used for a while) and is ignored.
    private static let handoffTTL: TimeInterval = 120

    /// The standalone app is about to be asked to quit, and on quit it hands
    /// sleep back to the system and clears its state. Remember whether it was
    /// on (and since when, for auto-off) so `restoreHandoff` can re-arm.
    func stashForHandoff() {
        let d = SleepyDefaults.store
        guard d.bool(forKey: activeKey), !autoOffExpired() else { return }
        d.set(activeSince ?? Date(), forKey: Self.handoffActiveSinceKey)
        d.set(Date(), forKey: Self.handoffAtKey)
    }

    /// Puts a fresh hand-off back into the persisted state `restoreOnLaunch`
    /// reads. Always consumes it.
    private func restoreHandoff() {
        let d = SleepyDefaults.store
        defer {
            d.removeObject(forKey: Self.handoffActiveSinceKey)
            d.removeObject(forKey: Self.handoffAtKey)
        }
        guard let at = d.object(forKey: Self.handoffAtKey) as? Date,
              Date().timeIntervalSince(at) < Self.handoffTTL,
              let since = d.object(forKey: Self.handoffActiveSinceKey) as? Date else { return }
        d.set(true, forKey: activeKey)
        activeSince = since
    }

    // MARK: - Arranque

    /// O que o arranque faz com o estado guardado e o que o sistema diz.
    struct RestoreDecision: Equatable {
        /// O Sleepy fica ligado (assertions, monitor da tampa, auto-off).
        var active: Bool
        /// Apaga `sleepActive` e `activeSince`.
        var clearPersisted: Bool
        /// Mantém o `activeSince` guardado em vez de começar um período novo.
        var keepActiveSince: Bool
    }

    /// Decisão pura do `restoreOnLaunch`. `resetSucceeded` é o resultado do
    /// reset defensivo (só corre quando não era para ficar ligado);
    /// `systemValue` é o `SleepDisabled` lido depois, `nil` se a leitura falhou.
    static func restoreDecision(persistedActive: Bool, expired: Bool,
                                resetSucceeded: Bool, systemValue: Bool?) -> RestoreDecision {
        if persistedActive && !expired {
            // Era para estar ligado. Só uma leitura 0 confirmada diz que o rearme
            // não pegou — aí não deixa `sleepActive` pendurado. Leitura falhada:
            // confia-se na intenção e o verificador (5 s) confirma.
            if systemValue == false { return .init(active: false, clearPersisted: true, keepActiveSince: false) }
            return .init(active: true, clearPersisted: false, keepActiveSince: true)
        }
        // Não era para ficar ligado (nunca esteve, ou o prazo passou): reset defensivo.
        if resetSucceeded || systemValue == false {
            return .init(active: false, clearPersisted: true, keepActiveSince: false)
        }
        // O reset não pegou. Prazo passado e o sistema continua a 1: o período
        // original fica, para o menu dizer "não desligou às HH:mm" e o auto-off
        // voltar a tentar — apagá-lo dava um período novo inteiro.
        if persistedActive { return .init(active: true, clearPersisted: false, keepActiveSince: true) }
        // Nada guardado: o ícone segue o sistema, que é melhor do que mentir.
        if systemValue == true { return .init(active: true, clearPersisted: false, keepActiveSince: false) }
        return .init(active: false, clearPersisted: true, keepActiveSince: false)
    }

    /// Re-arma se a app foi relançada (crash, rebuild, auto-update) enquanto
    /// estava ligada; caso contrário faz o reset defensivo. Nunca mostra prompt
    /// no arranque — só usa o caminho sem password.
    func restoreOnLaunch() {
        restoreHandoff()
        // O watchdog de uma sessão anterior já não faz falta: há Hone a correr.
        CrashWatchdog.stop()
        let persistedActive = SleepyDefaults.store.bool(forKey: activeKey)
        let expired = autoOffExpired()

        var resetSucceeded = false
        if persistedActive && !expired {
            _ = PrivilegedAccess.setDisableSleep(true)
        } else {
            resetSucceeded = PrivilegedAccess.setDisableSleep(false)
        }

        // O ícone segue o que o sistema diz, não o que julgamos ter feito. Sem
        // acesso sem password não conseguimos mexer no disablesleep em silêncio,
        // e mentir sobre o estado seria pior do que mostrá-lo.
        let decision = Self.restoreDecision(
            persistedActive: persistedActive, expired: expired,
            resetSucceeded: resetSucceeded, systemValue: Self.systemSleepDisabled())
        if decision.clearPersisted { clearPersisted() }
        isActive = decision.active
        if isActive {
            if !ensureAssertions() {
                NSLog("Sleepy: falha a criar as power assertions no arranque — o ecrã ou o Mac podem adormecer")
            }
            SleepyDefaults.store.set(true, forKey: activeKey)
            if !decision.keepActiveSince || activeSince == nil { activeSince = Date() }
            // Crash a meio de uma tampa fechada: o brilho ficou a 0. De tampa
            // fechada não se repõe aqui — o monitor volta a apagar ou repõe.
            if LidDisplay.dimmedByUs, !LidMonitor.current().lidClosed { LidDisplay.restore() }
            setRestoreAllowed(true)
            startLidMonitor()
            startVerification()
            CrashWatchdog.start()
            // Por último: com o prazo passado o auto-off dispara já (em silêncio),
            // e se der certo o `disable()` desfaz tudo o que ficou acima.
            scheduleAutoOff(silent: true)
        } else {
            // Desligado não há ninguém para repor depois: repõe-se já.
            setRestoreAllowed(false)
            stopLidMonitor()
            stopVerification()
            releaseAssertion()
        }
        onStateChange?()
    }

    // MARK: - Tampa fechada (painel interno)

    private func startLidMonitor() {
        if !LidMonitor.current().lidClosed, !lidDimmed { LidDisplay.sampleTrusted() }
        lidMonitor.start(onPoll: { [weak self] state in
            // Amostra de confiança: só de tampa aberta e sem nós a escurecer.
            guard let self, !state.lidClosed, !self.lidDimmed else { return }
            LidDisplay.sampleTrusted()
        }, onChange: { [weak self] state in
            self?.lidStateChanged(state)
        })
    }

    /// Deixa de seguir a tampa e repõe painel e teclado se os apagámos (agora
    /// ou numa sessão que crashou).
    private func stopLidMonitor() {
        lidMonitor.stop()
        let wasDimmed = lidDimmed
        lidDimmed = false
        guard wasDimmed || LidDisplay.dimmedByUs else { return }
        LidDisplay.restore()
        NSLog("Sleepy: a largar a tampa — brilho do painel e do teclado repostos")
    }

    /// Único ponto de entrada das mudanças de tampa/ecrã externo (já estabilizadas).
    func lidStateChanged(_ state: LidState) {
        guard isActive else { return }
        if LidMonitor.shouldDim(state) {
            // O sleep da tampa chega uns 5–8 s depois de fechar: dá tempo de
            // confirmar o SleepDisabled e, se caiu, repô-lo.
            verifySleepDisabled(reason: "tampa fechada")
            guard !lidDimmed else { return }
            lidDimmed = true
            releaseAssertion(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep)
            LidDisplay.dim()
            NSLog("Sleepy: tampa fechada sem ecrã externo — assertion de ecrã largada, painel e teclado a 0")
            return
        }
        if lidDimmed {
            lidDimmed = false
            if !ensureAssertions() {
                NSLog("Sleepy: falha a repor a assertion de ecrã — o ecrã pode adormecer")
            }
            let reason = state.lidClosed ? "ecrã externo ligado" : "tampa aberta"
            NSLog("Sleepy: \(reason) — assertion de ecrã reposta, painel e teclado repostos")
        }
        // Também apanha um brilho que ficou a 0 de uma sessão anterior.
        if LidDisplay.dimmedByUs {
            LidDisplay.restore()
        } else if !state.lidClosed {
            LidDisplay.sampleTrusted()
        }
    }

    // MARK: - Auto-desligar

    private var activeSince: Date? {
        get { SleepyDefaults.store.object(forKey: activeSinceKey) as? Date }
        set { SleepyDefaults.store.set(newValue, forKey: activeSinceKey) }
    }

    /// Momento em que o auto-off vai disparar, para mostrar no menu.
    var autoOffDate: Date? {
        guard isActive, Self.autoOffMinutes > 0, let since = activeSince else { return nil }
        return since.addingTimeInterval(TimeInterval(Self.autoOffMinutes) * 60)
    }

    private func autoOffExpired() -> Bool {
        guard Self.autoOffMinutes > 0, let since = activeSince else { return false }
        return Date().timeIntervalSince(since) >= TimeInterval(Self.autoOffMinutes) * 60
    }

    private func clearPersisted() {
        SleepyDefaults.store.set(false, forKey: activeKey)
        SleepyDefaults.store.removeObject(forKey: activeSinceKey)
    }

    /// Verificação periódica em vez de um único timer para o prazo todo: um
    /// timer longo escorrega se a máquina chegar a dormir ou a entrar em dark
    /// wake, e o prazo passaria despercebido. Comparar contra o relógio de
    /// parede a cada 15s custa nada e não pode escorregar. Com o prazo já
    /// passado dispara logo, mas o timer fica a tentar de novo se não der.
    /// `silent`: o primeiro disparo nunca pede admin (arranque).
    private func scheduleAutoOff(silent: Bool = false) {
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffPromptDeclined = silent
        guard isActive, autoOffDate != nil else { return }
        if autoOffExpired() { autoOff() }
        guard isActive else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, self.autoOffExpired() else { return }
            self.autoOff()
        }
        timer.tolerance = 5
        // .common para continuar a correr enquanto um menu/popover está aberto.
        RunLoop.main.add(timer, forMode: .common)
        autoOffTimer = timer
    }

    private func autoOff() {
        stopAutomatically(.autoOff)
    }

    /// Desliga o Sleepy por segurança e diz porquê. Único caminho do auto-desligar,
    /// do limite de bateria e da proteção térmica.
    func stopAutomatically(_ reason: StopReason) {
        guard isActive else { return }
        // Tampa fechada com ecrã externo é um Mac em uso: há prompt (vê-se no
        // externo) e não se manda dormir.
        let closed = LidMonitor.current().closedWithoutExternal
        let lid = closed ? "fechada sem ecrã externo" : "aberta ou com ecrã externo"
        switch reason {
        case .autoOff: NSLog("Sleepy: auto-desligar ao fim de \(Self.autoOffMinutes) min (tampa \(lid))")
        case .battery(let percent): NSLog("Sleepy: a desligar com a bateria a \(percent) % (tampa \(lid))")
        case .thermal: NSLog("Sleepy: a desligar, o Mac está a aquecer (tampa \(lid))")
        }
        // Já marcado para o `disable()` publicar o motivo de uma vez; se falhar, desfaz-se.
        lastStop = (reason, Date())
        // De tampa fechada sem externo não pode haver prompt de admin: era
        // invisível e ficava a bloquear a app. Só o caminho sem password.
        disable(allowPrompt: !closed && !autoOffPromptDeclined)
        guard !isActive else {
            lastStop = nil
            NSLog("Sleepy: desligar sozinho falhou — sem acesso sem password instalado")
            // Os timers continuam: tentam de novo em silêncio (15s o auto-desligar,
            // 30s e as mudanças de bateria/temperatura o resto) e, ao abrir a
            // tampa, pede admin uma vez. Recusado, não volta a pedir.
            if !closed { autoOffPromptDeclined = true }
            return
        }
        Notifier.shared.notify("Sleepy desligou-se — \(reason.notificationReason).")
        // Repor o disablesleep não faz o Mac adormecer sozinho: o evento de
        // lid-close já foi consumido e ele fica acordado até ao idle. De tampa
        // fechada é o comportamento que o utilizador espera, por isso pedimos
        // o sleep explicitamente (o pmset sleepnow não precisa de privilégios).
        guard closed else {
            // Lote D: ação no fim
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.sleepNow() }
    }

    // MARK: - Bateria e temperatura

    /// Segue a bateria e o estado térmico enquanto o Sleepy está ligado. Chamado
    /// pelo `startVerification` (mesmo ciclo de vida: ligar, restaurar, desligar).
    private func startPowerGuards() {
        thermalGuard = ThermalGuard()
        batteryGuard = BatteryGuard(threshold: Self.batteryThreshold)
        powerWatcher.start { [weak self] in self?.checkPowerGuards(reason: "mudança") }
        // Se já está abaixo do limite ao ligar, diz-se logo — não ao fim de 30 s.
        // Adiado para depois do `enable()`/`restoreOnLaunch()` acabarem.
        DispatchQueue.main.async { [weak self] in self?.checkPowerGuards(reason: "ao ligar") }
    }

    private func stopPowerGuards() {
        powerWatcher.stop()
        thermalRecheckTimer?.invalidate()
        thermalRecheckTimer = nil
        thermalGuard = ThermalGuard()
        batteryGuard = BatteryGuard(threshold: Self.batteryThreshold)
    }

    /// Avalia o limite de bateria e a temperatura; se for caso disso, desliga
    /// sozinho. Chamado pelas notificações do sistema, pelo timer de 30 s e ao
    /// mudar o limiar. Uma leitura desconhecida nunca desliga. Só no main.
    func checkPowerGuards(reason: String) {
        guard isActive else { return }

        batteryGuard.threshold = Self.batteryThreshold
        if batteryGuard.threshold > 0 {
            let reading = PowerSource.currentBattery()
            if batteryGuard.recordRead(succeeded: reading != nil) {
                NSLog("Sleepy: sem leitura da bateria — o limite de bateria não se aplica")
            }
            if let reading, batteryGuard.shouldStop(percent: reading.percent, onBattery: reading.onBattery) {
                NSLog("Sleepy: bateria a \(reading.percent) % (\(reason))")
                stopAutomatically(.battery(percent: reading.percent))
                return
            }
        }

        let thermal = ProcessInfo.processInfo.thermalState
        // A tampa só interessa a partir de `.serious`: abaixo disso nem se lê.
        let closed = thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            && LidMonitor.current().closedWithoutExternal
        if thermalGuard.shouldStop(state: thermal, closedWithoutExternal: closed, at: Date()) {
            NSLog("Sleepy: estado térmico \(thermal.rawValue) (\(reason))")
            stopAutomatically(.thermal)
            return
        }
        updateThermalRecheck()
    }

    /// O `.serious` precisa de 30 s seguidos, e o timer de 30 s pode escorregar
    /// quase o dobro: enquanto conta, agenda-se uma reavaliação certa para o fim.
    private func updateThermalRecheck() {
        guard thermalGuard.isCounting else {
            thermalRecheckTimer?.invalidate()
            thermalRecheckTimer = nil
            return
        }
        guard thermalRecheckTimer == nil else { return }
        let timer = Timer(timeInterval: ThermalGuard.seriousHold + 0.5, repeats: false) { [weak self] _ in
            self?.thermalRecheckTimer = nil
            self?.checkPowerGuards(reason: "térmica")
        }
        RunLoop.main.add(timer, forMode: .common)
        thermalRecheckTimer = timer
    }

    // MARK: - Sleep imediato

    private static func sleepNow() {
        runPmsetInBackground(["sleepnow"])
    }

    /// `pmset` sem privilégios (`sleepnow`, `displaysleepnow`), fora do main
    /// para nunca o bloquear.
    static func runPmsetInBackground(_ arguments: [String]) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                NSLog("Sleepy: pmset \(arguments.joined(separator: " ")) falhou")
            }
        }
    }
}
