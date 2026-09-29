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
/// fim de `autoOffMinutes` (default 8h) — e, se a tampa estiver fechada nessa
/// altura, mandamos o Mac dormir logo, que é o que a tampa fechada quer dizer.
final class SleepController {
    static let shared = SleepController()

    private(set) var isActive = false

    /// Chamado quando o estado muda sem ser por clique (restore, auto-off).
    var onStateChange: (() -> Void)?

    /// As três assertions IOKit que seguramos em conjunto (ecrã, bateria, corrente).
    static let assertionTypes = [
        kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionTypePreventUserIdleSystemSleep,
        kIOPMAssertionTypePreventSystemSleep,
    ]
    /// Por tipo, para recriar só a que faltar.
    private var assertionIDs: [String: IOPMAssertionID] = [:]
    private var autoOffTimer: Timer?
    /// O prompt de admin do auto-desligar foi recusado: as tentativas seguintes
    /// são só em silêncio, para não o repetir a cada 15s.
    private var autoOffPromptDeclined = false

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

    private init() {}

    // MARK: - Estado real do sistema

    /// Lê o `SleepDisabled` do `pmset -g`. Não precisa de privilégios, e é a
    /// única fonte de verdade — o que julgamos ter feito pode não ter pegado.
    static func systemSleepDisabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return false }
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return fields.last == "1"
        }
        return false
    }

    // MARK: - IOKit power assertions (ecrã + idle + system sleep)

    /// Segura as três assertions (ecrã, idle, system). Sem privilégios.
    /// Idempotente: cria só as que faltam, por isso uma falha parcial não fica
    /// para sempre — a próxima chamada tenta de novo. De tampa fechada o painel
    /// pode apagar-se na mesma; o que importa aí é o Mac não dormir.
    @discardableResult
    func ensureAssertions() -> Bool {
        for type in Self.assertionTypes where assertionIDs[type] == nil {
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
        return assertionIDs.count == Self.assertionTypes.count
    }

    func releaseAssertion() {
        for id in assertionIDs.values { IOPMAssertionRelease(id) }
        assertionIDs.removeAll()
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
        activeSince = Date()
        SleepyDefaults.store.set(true, forKey: activeKey)
        scheduleAutoOff()
        onStateChange?()
    }

    func disable(allowPrompt: Bool = true) {
        guard isActive else { return }
        guard setDisableSleep(false, allowPrompt: allowPrompt) else { return }
        releaseAssertion()
        isActive = false
        clearPersisted()
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        onStateChange?()
    }

    /// Lets go of what this process holds (power assertions, auto-off timer)
    /// but leaves `pmset disablesleep` and the persisted state untouched, so
    /// whoever runs Sleepy next — Hone after a relaunch, or the old app — re-arms
    /// through `restoreOnLaunch`. Never prompts.
    func suspend() {
        releaseAssertion()
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        isActive = false
    }

    /// Confere o estado real antes de mostrar o painel. Se o `disablesleep` caiu
    /// (alguém correu `pmset`, reset do sistema), tenta repô-lo em silêncio;
    /// se não der, a proteção caiu mesmo e o estado passa a dizê-lo. Caso
    /// contrário, recria as assertions que faltem. Nunca mostra prompt.
    func reassert() {
        guard isActive else { return }
        if !Self.systemSleepDisabled() {
            _ = PrivilegedAccess.setDisableSleep(true)
            guard Self.systemSleepDisabled() else {
                NSLog("Sleepy: disablesleep caiu por fora e não deu para repor — desligado")
                releaseAssertion()
                isActive = false
                clearPersisted()
                autoOffTimer?.invalidate()
                autoOffTimer = nil
                onStateChange?()
                return
            }
        }
        if !ensureAssertions() {
            NSLog("Sleepy: falha a repor as power assertions — o ecrã ou o Mac podem adormecer")
        }
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

    /// Re-arma se a app foi relançada (crash, rebuild, auto-update) enquanto
    /// estava ligada; caso contrário faz o reset defensivo. Nunca mostra prompt
    /// no arranque — só usa o caminho sem password.
    func restoreOnLaunch() {
        restoreHandoff()
        let shouldBeActive = SleepyDefaults.store.bool(forKey: activeKey) && !autoOffExpired()

        if shouldBeActive {
            _ = PrivilegedAccess.setDisableSleep(true)
        } else {
            _ = PrivilegedAccess.setDisableSleep(false)
            clearPersisted()
        }

        // O ícone segue o que o sistema diz, não o que julgamos ter feito. Sem
        // acesso sem password não conseguimos mexer no disablesleep em silêncio,
        // e mentir sobre o estado seria pior do que mostrá-lo.
        isActive = Self.systemSleepDisabled()
        if isActive {
            if !ensureAssertions() {
                NSLog("Sleepy: falha a criar as power assertions no arranque — o ecrã ou o Mac podem adormecer")
            }
            SleepyDefaults.store.set(true, forKey: activeKey)
            if activeSince == nil { activeSince = Date() }
            scheduleAutoOff()
        } else {
            releaseAssertion()
        }
        onStateChange?()
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
    /// parede a cada 15s custa nada e não pode escorregar.
    private func scheduleAutoOff() {
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffPromptDeclined = false
        guard isActive, autoOffDate != nil else { return }
        if autoOffExpired() { autoOff(); return }
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
        guard isActive else { return }
        let closed = Self.lidClosed()
        NSLog("Sleepy: auto-desligar ao fim de \(Self.autoOffMinutes) min (tampa \(closed ? "fechada" : "aberta"))")
        // De tampa fechada não pode haver prompt de admin: era invisível e ficava
        // a bloquear a app. Só o caminho sem password.
        disable(allowPrompt: !closed && !autoOffPromptDeclined)
        guard !isActive else {
            NSLog("Sleepy: auto-desligar falhou — sem acesso sem password instalado")
            // O timer continua: tenta de novo em silêncio a cada 15s e, ao abrir
            // a tampa, pede admin uma vez. Recusado, não volta a pedir.
            if !closed { autoOffPromptDeclined = true }
            return
        }
        // Repor o disablesleep não faz o Mac adormecer sozinho: o evento de
        // lid-close já foi consumido e ele fica acordado até ao idle. De tampa
        // fechada é o comportamento que o utilizador espera, por isso pedimos
        // o sleep explicitamente (o pmset sleepnow não precisa de privilégios).
        guard closed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.sleepNow() }
    }

    // MARK: - Tampa e sleep imediato

    /// `AppleClamshellState = Yes` no IORegistry ⇒ tampa fechada.
    static func lidClosed() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-r", "-k", "AppleClamshellState", "-d", "4"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return false }
        for line in out.split(separator: "\n") where line.contains("AppleClamshellState") {
            return line.contains("Yes")
        }
        return false
    }

    private static func sleepNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { NSLog("Sleepy: pmset sleepnow falhou") }
    }
}
