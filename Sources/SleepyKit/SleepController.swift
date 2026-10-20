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
/// fim de `autoOffMinutes` (default 8h) ou à hora escolhida ("Até às HH:MM") — e,
/// se a tampa estiver fechada (sem ecrã externo) nessa altura, mandamos o Mac
/// dormir logo, que é o que a tampa fechada quer dizer.
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
/// teclado ([[LidDisplay]]); ao abrir a tampa ou ligar um externo, repomos. Na
/// mesma transição, e só se o utilizador o pediu, liga-se o Low Power Mode e
/// silencia-se o som ([[LidExtras]]), repostos da mesma forma.
///
/// Dois modos ([[SleepMode]]): `.lidClosedAwake` é tudo o que está acima;
/// `.displayOnly` só segura o ecrã e o idle (nº 2 e nº 3), sem `disablesleep`,
/// sem root, sem watchdog nem monitor da tampa — fechar a tampa adormece o Mac.
/// Mantém o limite de bateria e o auto-desligar.
///
/// Opcionalmente liga-se sozinho durante sessões SSH e de Partilha de Ecrã
/// ([[RemoteSessionMonitor]]) e desliga-se quando acabam — só se foi esse gatilho
/// a ligá-lo (`startedByTrigger`). Sem ninguém ao ecrã não há prompt de admin:
/// o modo da sessão é o guardado só com o sudo silencioso, senão só ecrã (um modo
/// só desta sessão, `sessionModeOverride`; o guardado não muda). Sem prazo, mas a
/// bateria e a temperatura continuam a valer, e há um teto de 12 h. Desligado à
/// mão (ou por segurança) a meio de uma sessão, o gatilho não volta a ligar até
/// ela acabar (`remoteSuppressed`).
///
/// Opcionalmente (`mouseNudgeMinutes`) mexe o rato 1 px de N em N minutos sem input,
/// para o Teams e o Slack não nos marcarem ausentes ([[MouseNudge]]).
///
/// "Até o Claude acabar" é uma espera de uso único (`waitForClaudeSince`): com
/// ela armada não há prazo, e o Sleepy desliga-se quando nenhuma sessão do
/// Claude Code está a trabalhar ([[ClaudeActivityMonitor]]). A bateria e a
/// temperatura continuam a valer, e há um teto de 12 h. Qualquer desligar a desarma.
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
    /// O prompt de admin do auto-desligar foi mostrado e o desligar falhou: as
    /// tentativas seguintes são só em silêncio, para não o repetir a cada 15s.
    private var autoOffPromptDeclined = false

    /// Porque é que o Sleepy se desligou sozinho, e quando. Só em memória: vive
    /// até o utilizador voltar a ligar (`enable()`).
    private(set) var lastStop: (reason: StopReason, at: Date)?

    /// O `SleepyTool` está a correr (`start` até `stop`/`stopKeepingState`). Parado,
    /// mudar a preferência remota só a guarda: o monitor arranca no próximo `start`.
    var toolRunning = false {
        didSet { if oldValue != toolRunning { syncMouseNudger() } }
    }

    // Sessões remotas (ver "Sessões remotas"). Só no main.
    private let remoteMonitor = RemoteSessionMonitor()
    /// O último estado estável entregue pelo monitor (ou lido no arranque).
    private(set) var remoteSessions: RemoteSessions?

    // Espera "até o Claude acabar" (ver "Até o Claude acabar"). Só no main.
    private let claudeMonitor = ClaudeActivityMonitor()
    /// A última leitura entregue pelo monitor; `nil` até à primeira.
    private(set) var claudeActivity: ClaudeActivity?

    // "Mexer o rato" (ver [[MouseNudge]]). Só no main.
    private let mouseNudger = MouseNudger()

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
    private static let autoOffUntilClockKey = "autoOffUntilClock"
    private static let autoOffUntilSetAtKey = "autoOffUntilSetAt"
    private static let autoOffExtensionKey = "autoOffExtension"
    private static let sleepModeKey = "sleepMode"
    private static let endActionKey = "endAction"
    private static let remoteKey = "stayAwakeForRemoteSessions"
    private static let startedByTriggerKey = "startedByTrigger"
    private static let sessionModeKey = "sessionModeOverride"
    private static let remoteSuppressedKey = "remoteSuppressed"
    private static let autoOffWarnedKey = "autoOffWarnedSince"
    private static let waitForClaudeKey = "waitForClaudeSince"

    /// Valor de `autoOffMinutes` para "Até às HH:MM": não é uma duração, é a hora
    /// de `autoOffUntilClock`.
    static let untilClockMinutes = -1

    /// Minutos até desligar sozinho. 0 = nunca; `untilClockMinutes` = até à hora
    /// escolhida. Antes disto a preferência era em horas — migra-se na primeira
    /// leitura para não perder a escolha do utilizador.
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
            // Re-escolher o valor já escolhido (o picker chama sempre `onChange`,
            // mesmo no item com visto) não mexe em nada: senão "Até às 18:00" com
            // "+1 h" voltava a contar de agora e o prazo saltava para amanhã.
            guard newValue != autoOffMinutes else { return }
            SleepyDefaults.store.set(newValue, forKey: autoOffKey)
            // "Até às" escolhido agora: a hora conta a partir de agora, não do
            // início de uma sessão ligada há mais tempo.
            if newValue == untilClockMinutes { autoOffUntilSetAt = Date() }
            // Duração nova = prazo novo: o "+1 h" de antes já não conta.
            shared.autoOffExtension = 0
            shared.autoOffWarned = false
            shared.scheduleAutoOff()
        }
    }

    /// A hora do "Até às", em minutos desde a meia-noite (0…1439). Omissão: 18:00.
    static var autoOffUntilClock: Int {
        get {
            guard let clock = SleepyDefaults.store.object(forKey: autoOffUntilClockKey) as? Int,
                  (0..<24 * 60).contains(clock) else { return 18 * 60 }
            return clock
        }
        set {
            SleepyDefaults.store.set(min(max(newValue, 0), 24 * 60 - 1), forKey: autoOffUntilClockKey)
            // Hora nova = prazo novo, contado a partir de agora (como ao escolher o modo).
            autoOffUntilSetAt = Date()
            shared.autoOffExtension = 0
            shared.autoOffWarned = false
            shared.scheduleAutoOff()
        }
    }

    /// Quando o utilizador escolheu "Até às" ou mudou a hora. A hora conta a
    /// partir do mais tardio disto e do início da sessão (`autoOffDate`).
    private(set) static var autoOffUntilSetAt: Date? {
        get { SleepyDefaults.store.object(forKey: autoOffUntilSetAtKey) as? Date }
        set {
            if let newValue {
                SleepyDefaults.store.set(newValue, forKey: autoOffUntilSetAtKey)
            } else {
                SleepyDefaults.store.removeObject(forKey: autoOffUntilSetAtKey)
            }
        }
    }

    /// Modo guardado. Muda-se com `setSleepMode`, que aplica a troca ao Sleepy
    /// ligado e só então a guarda.
    private(set) static var sleepMode: SleepMode {
        get { SleepMode(rawValue: SleepyDefaults.store.string(forKey: sleepModeKey) ?? "") ?? .lidClosedAwake }
        set { SleepyDefaults.store.set(newValue.rawValue, forKey: sleepModeKey) }
    }

    /// O modo em uso: o de sessão, se houver, senão o guardado. É este que manda
    /// no Sleepy ligado (assertions, disablesleep, monitor da tampa).
    var activeMode: SleepMode { sessionModeOverride ?? Self.sleepMode }

    /// O modo só desta sessão, quando o gatilho remoto não pôde usar o guardado.
    /// Em disco, para sobreviver a um relançamento; limpa-se ao desligar.
    private var sessionModeOverride: SleepMode? {
        get { SleepMode(rawValue: SleepyDefaults.store.string(forKey: Self.sessionModeKey) ?? "") }
        set {
            if let newValue {
                SleepyDefaults.store.set(newValue.rawValue, forKey: Self.sessionModeKey)
            } else {
                SleepyDefaults.store.removeObject(forKey: Self.sessionModeKey)
            }
        }
    }

    /// Foi uma sessão remota que ligou o Sleepy (e não o utilizador). Em disco,
    /// como o resto do estado ligado; limpa-se ao desligar, seja como for.
    private(set) var startedByTrigger: Bool {
        get { SleepyDefaults.store.bool(forKey: Self.startedByTriggerKey) }
        set {
            if newValue {
                SleepyDefaults.store.set(true, forKey: Self.startedByTriggerKey)
            } else {
                SleepyDefaults.store.removeObject(forKey: Self.startedByTriggerKey)
            }
        }
    }

    /// Desligado à mão (ou por bateria, temperatura, teto) com uma sessão remota
    /// ativa: o gatilho não volta a ligar até o monitor dizer que as sessões
    /// acabaram. Em disco, para um relançamento não o ligar outra vez.
    private(set) var remoteSuppressed: Bool {
        get { SleepyDefaults.store.bool(forKey: Self.remoteSuppressedKey) }
        set {
            if newValue {
                SleepyDefaults.store.set(true, forKey: Self.remoteSuppressedKey)
            } else {
                SleepyDefaults.store.removeObject(forKey: Self.remoteSuppressedKey)
            }
        }
    }

    /// Quando foi armada a espera "até o Claude acabar"; `nil` = não está. Em
    /// disco, para sobreviver a um relançamento; limpa-se ao desligar.
    private(set) var waitForClaudeSince: Date? {
        get { SleepyDefaults.store.object(forKey: Self.waitForClaudeKey) as? Date }
        set {
            if let newValue {
                SleepyDefaults.store.set(newValue, forKey: Self.waitForClaudeKey)
            } else {
                SleepyDefaults.store.removeObject(forKey: Self.waitForClaudeKey)
            }
        }
    }

    var waitsForClaude: Bool { waitForClaudeSince != nil }

    /// Ligar sozinho durante sessões SSH e de Partilha de Ecrã. Desligado por omissão.
    static var stayAwakeForRemoteSessions: Bool {
        get { SleepyDefaults.store.bool(forKey: remoteKey) }
        set {
            SleepyDefaults.store.set(newValue, forKey: remoteKey)
            shared.remotePreferenceChanged()
        }
    }

    /// O que fazer quando o Sleepy se desliga sozinho (tempo ou bateria).
    static var endAction: EndAction {
        get { EndAction(rawValue: SleepyDefaults.store.string(forKey: endActionKey) ?? "") ?? .none }
        set { SleepyDefaults.store.set(newValue.rawValue, forKey: endActionKey) }
    }

    /// As escolhas de auto-desligar, partilhadas pelo menu e pelas definições.
    /// `short` é a versão compacta, para a linha estreita do menu.
    struct AutoOffOption: Identifiable, Hashable {
        let minutes: Int
        let title: String
        let short: String
        var id: Int { minutes }
    }

    /// As durações fixas, "Até às HH:MM" (com a hora escolhida no texto) e "Nunca".
    static func autoOffOptions(untilClock: Int) -> [AutoOffOption] {
        let time = clockText(untilClock)
        return [
            .init(minutes: 10, title: "10 minutos", short: "10 min"),
            .init(minutes: 20, title: "20 minutos", short: "20 min"),
            .init(minutes: 30, title: "30 minutos", short: "30 min"),
            .init(minutes: 60, title: "1 hora", short: "1 h"),
            .init(minutes: 120, title: "2 horas", short: "2 h"),
            .init(minutes: 240, title: "4 horas", short: "4 h"),
            .init(minutes: 480, title: "8 horas", short: "8 h"),
            .init(minutes: 720, title: "12 horas", short: "12 h"),
            // Só a hora na pílula: "Até 18:00" não cabe ao lado do "+1 h" sem cortar o título da linha.
            .init(minutes: untilClockMinutes, title: "Até às \(time)", short: time),
            .init(minutes: 0, title: "Nunca", short: "Nunca"),
        ]
    }

    /// Minutos desde a meia-noite como "HH:MM" (sempre com zero à esquerda). Pura.
    static func clockText(_ clock: Int) -> String {
        let c = min(max(clock, 0), 24 * 60 - 1)
        return String(format: "%02d:%02d", c / 60, c % 60)
    }

    /// Hoje à hora `clock`, para o seletor de hora das Definições (que só mostra
    /// horas e minutos). Pura.
    static func clockDate(_ clock: Int, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let c = min(max(clock, 0), 24 * 60 - 1)
        return calendar.date(bySettingHour: c / 60, minute: c % 60, second: 0, of: now) ?? now
    }

    /// O contrário de `clockDate`: a hora e os minutos de `date`, desde a meia-noite. Pura.
    static func clockMinutes(of date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

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

    private static let mouseNudgeKey = "mouseNudgeMinutes"

    /// Minutos sem input ao fim dos quais o Sleepy mexe o rato 1 px (para o Teams e
    /// o Slack não nos porem ausentes). 0 = nunca, a omissão.
    static var mouseNudgeMinutes: Int {
        get { SleepyDefaults.store.object(forKey: mouseNudgeKey) as? Int ?? 0 }
        set {
            SleepyDefaults.store.set(newValue, forKey: mouseNudgeKey)
            shared.syncMouseNudger()
        }
    }

    /// As escolhas de "Mexer o rato", partilhadas pelas definições. Mesmo formato
    /// das de auto-desligar (`minutes`, `title`, `short`).
    static let mouseNudgeOptions: [AutoOffOption] = [
        .init(minutes: 0, title: "Nunca", short: "Nunca"),
        .init(minutes: 1, title: "1 minuto", short: "1 min"),
        .init(minutes: 2, title: "2 minutos", short: "2 min"),
        .init(minutes: 3, title: "3 minutos", short: "3 min"),
        .init(minutes: 5, title: "5 minutos", short: "5 min"),
        .init(minutes: 10, title: "10 minutos", short: "10 min"),
    ]

    /// O "Mexer o rato" só corre com a opção ligada, o Sleepy ligado e o tool a correr. Pura.
    static func mouseNudgeWanted(isActive: Bool, toolRunning: Bool, minutes: Int) -> Bool {
        isActive && toolRunning && minutes > 0
    }

    /// Liga, desliga ou muda o intervalo do "Mexer o rato" conforme o estado. Idempotente.
    func syncMouseNudger() {
        let minutes = Self.mouseNudgeMinutes
        if Self.mouseNudgeWanted(isActive: isActive, toolRunning: toolRunning, minutes: minutes) {
            mouseNudger.start(interval: TimeInterval(minutes * 60))
        } else {
            mouseNudger.stop()
        }
    }

    /// Porque é que o Sleepy se desligou sozinho.
    enum StopReason: Equatable {
        case autoOff
        case battery(percent: Int)
        /// `lidClosed`: a tampa estava fechada sem ecrã externo quando parou
        /// (o `.critical` também dispara de tampa aberta).
        case thermal(lidClosed: Bool)
        /// A sessão SSH ou de Partilha de Ecrã que o ligou terminou.
        case remoteSessionEnded
        /// A sessão do gatilho chegou ao teto (`remoteSessionCap`): pode ser uma
        /// entrada do utmpx que ficou, e o Mac não fica acordado sem fim.
        case remoteSessionCap
        /// Com a espera "até o Claude acabar": o Claude trabalhou e parou.
        case claudeFinished
        /// O Claude parou mas o monitor nunca o viu a trabalhar desde que seguiu a
        /// espera (armada com ele parado, ou retomada no arranque depois de acabar).
        case claudeIdle
        /// A espera pelo Claude chegou ao teto (`claudeWaitCap`).
        case claudeCap

        /// Para a notificação: "Sleepy desligou-se — <isto>."
        var notificationReason: String {
            switch self {
            case .autoOff: return "passou o tempo escolhido"
            case .battery(let percent): return "bateria a \(percent) %"
            case .thermal(let lidClosed):
                return lidClosed ? "o Mac estava a aquecer com a tampa fechada" : "o Mac estava a aquecer"
            case .remoteSessionEnded: return "a sessão remota terminou"
            case .remoteSessionCap: return "a sessão remota durou mais de 12 h"
            case .claudeFinished: return "o Claude acabou as tarefas"
            case .claudeIdle: return "o Claude não estava a trabalhar"
            case .claudeCap: return "passaram 12 h à espera do Claude"
            }
        }

        /// Para o painel: "Desligou-se às HH:mm — <isto>."
        var panelReason: String {
            // Mais curto que na notificação: cabe nas duas linhas do painel.
            if case .thermal = self { return "o Mac estava a aquecer" }
            return notificationReason
        }

        /// A ação escolhida para o fim só corre quando o Sleepy acaba por tempo,
        /// bateria ou o Claude acabar (um fim normal); com o Mac quente o melhor é
        /// não mexer em mais nada. `.claudeIdle` também não: o Claude nunca chegou a
        /// trabalhar, e pôr o Mac a dormir debaixo das mãos de quem está a usá-lo é pior.
        var runsEndAction: Bool {
            switch self {
            case .autoOff, .battery, .claudeFinished, .claudeCap: return true
            case .thermal, .remoteSessionEnded, .remoteSessionCap, .claudeIdle: return false
            }
        }

        /// Quem saiu da sessão remota não precisa de aviso: só o painel o diz.
        var notifies: Bool { self != .remoteSessionEnded }

        /// Pode pedir admin ao desligar. Nunca numa sessão remota: o prompt seria
        /// invisível e deixava a app à espera. Nem no fim da espera pelo Claude: chega
        /// a uma hora que ninguém escolheu, e o prompt congela o Hone até alguém responder.
        var allowsAdminPrompt: Bool { !endsTriggerSession && !endsClaudeWait }

        /// Acaba a espera "até o Claude acabar" (por ele ter parado ou pelo teto).
        var endsClaudeWait: Bool { self == .claudeFinished || self == .claudeIdle || self == .claudeCap }

        /// Acaba com uma sessão do gatilho. Se o desligar falhar, a sessão passa a
        /// normal, com prazo, em vez de ficar ligada sem fim.
        var endsTriggerSession: Bool { self == .remoteSessionEnded || self == .remoteSessionCap }

        /// Desligar por isto com uma sessão remota ativa trava o gatilho até ela
        /// acabar. O fim da sessão não: já não há sessão.
        var suppressesRemoteTrigger: Bool { self != .remoteSessionEnded }
    }

    /// Pode mostrar o prompt de admin ao desligar sozinho? Nunca de tampa fechada
    /// sem externo, nem numa sessão do gatilho (não há ninguém ao ecrã), nem depois
    /// de recusado, nem no disparo imediato do arranque (`silent`). Pura.
    static func stopAllowsPrompt(reason: StopReason, lidClosedWithoutExternal: Bool,
                                 promptDeclined: Bool, startedByTrigger: Bool, silent: Bool) -> Bool {
        !silent && !lidClosedWithoutExternal && !promptDeclined && !startedByTrigger && reason.allowsAdminPrompt
    }

    /// Depois de um desligar sozinho que falhou: só fica "recusado" se o prompt
    /// chegou a ser mostrado. Falhar em silêncio não conta. Pura.
    static func promptDeclinedAfterFailedStop(allowPrompt: Bool, wasDeclined: Bool) -> Bool {
        wasDeclined || allowPrompt
    }

    /// A ação no fim para este motivo. Pura: `nil` = nada a fazer.
    static func endCommand(action: EndAction, reason: StopReason) -> EndCommand? {
        reason.runsEndAction ? action.command : nil
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

    /// As que cada modo deve ter seguras. `.lidClosedAwake`: as três, e sem a de
    /// ecrã com o painel apagado (`lidDimmed`). `.displayOnly`: só ecrã + idle —
    /// sem `PreventSystemSleep`, para fechar a tampa adormecer mesmo na corrente.
    static func assertionTypes(for mode: SleepMode, lidDimmed: Bool) -> [String] {
        switch mode {
        case .displayOnly:
            return [kIOPMAssertionTypePreventUserIdleDisplaySleep,
                    kIOPMAssertionTypePreventUserIdleSystemSleep]
        case .lidClosedAwake:
            guard lidDimmed else { return assertionTypes }
            return assertionTypes.filter { $0 != kIOPMAssertionTypePreventUserIdleDisplaySleep }
        }
    }

    /// Segura as assertions do modo (ver `assertionTypes(for:lidDimmed:)`) e
    /// larga as que já não fazem falta (a de ecrã com `lidDimmed`, a de system
    /// ao passar a `.displayOnly`). Sem privilégios. Idempotente: cria só as que
    /// faltam, por isso uma falha parcial não fica para sempre — a próxima
    /// chamada tenta de novo. `mode` só para os testes; por omissão, o em uso.
    @discardableResult
    func ensureAssertions(mode: SleepMode? = nil) -> Bool {
        let wanted = Self.assertionTypes(for: mode ?? activeMode, lidDimmed: lidDimmed)
        for type in Array(assertionIDs.keys) where !wanted.contains(type) { releaseAssertion(ofType: type) }
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
        enable(sessionMode: nil, byTrigger: false)
    }

    /// `sessionMode`: um modo só desta sessão (nil = o guardado). `byTrigger`: foi
    /// uma sessão remota que o pediu — nunca mostra o prompt de admin. Devolve
    /// `false` se não ligou.
    @discardableResult
    private func enable(sessionMode: SleepMode?, byTrigger: Bool) -> Bool {
        guard !isActive else { return false }
        let mode = sessionMode ?? Self.sleepMode
        // Sem o disablesleep não há proteção de lid-close — se o utilizador
        // cancelar o prompt de admin, não fingimos que ficou ligado. Em
        // `.displayOnly` não há disablesleep: liga sem root e sem prompt.
        if mode.usesDisableSleep { guard setDisableSleep(true, allowPrompt: !byTrigger) else { return false } }
        sessionModeOverride = sessionMode
        startedByTrigger = byTrigger
        if !ensureAssertions() {
            NSLog("Sleepy: falha a criar as power assertions — o ecrã ou o Mac podem adormecer")
        }
        isActive = true
        lastStop = nil
        activeSince = Date()
        autoOffExtension = 0
        autoOffWarned = false
        SleepyDefaults.store.set(true, forKey: activeKey)
        startModeServices(for: mode)
        scheduleAutoOff()
        syncMouseNudger()
        Notifier.shared.requestAuthorizationIfNeeded()
        onStateChange?()
        return true
    }

    /// `suppressRemote`: com uma sessão remota ativa, o gatilho não volta a ligar
    /// até ela acabar (desligar à mão é para valer). Marca-se mesmo que o desligar
    /// falhe: a intenção era desligar.
    func disable(allowPrompt: Bool = true, suppressRemote: Bool = true) {
        guard isActive else { return }
        if suppressRemote, remoteSessions?.isActive == true, !remoteSuppressed {
            remoteSuppressed = true
            NSLog("Sleepy: desligado com uma sessão remota ativa — o gatilho fica parado até ela acabar")
        }
        // Antes do pmset: uma verificação em curso não pode repor o 1 por cima.
        setRestoreAllowed(false)
        // Em `.displayOnly` não há disablesleep para largar (nem prompt).
        if activeMode.usesDisableSleep {
            guard setDisableSleep(false, allowPrompt: allowPrompt) else {
                setRestoreAllowed(true)
                return
            }
        }
        stopLidMonitor()
        releaseAssertion()
        stopVerification()
        CrashWatchdog.stop()
        isActive = false
        syncMouseNudger()
        if startedByTrigger { NSLog("Sleepy: a desligar a sessão que o gatilho remoto tinha ligado") }
        if waitsForClaude { NSLog("Sleepy: desligado — a espera pelo Claude fica desarmada") }
        clearPersisted()
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        // O `clearPersisted` já apagou a chave: isto larga o monitor e a última leitura.
        disarmClaudeWait()
        onStateChange?()
    }

    /// O que corre enquanto o Sleepy está ligado, conforme o modo. O `disablesleep`
    /// já tem de estar posto (ou, em `.displayOnly`, não se usa). A bateria e o
    /// auto-desligar valem nos dois modos; o resto é só de `.lidClosedAwake`.
    private func startModeServices(for mode: SleepMode) {
        if mode.usesDisableSleep {
            setRestoreAllowed(true)
            startLidMonitor()
            CrashWatchdog.start()
        } else {
            // Sem monitor da tampa ninguém escurece o painel: repõe-se o que
            // ficou de uma sessão que crashou.
            setRestoreAllowed(false)
            stopLidMonitor()
        }
        startVerification()
    }

    /// Troca o modo. Com o Sleepy ligado aplica-se já: para `.lidClosedAwake`
    /// põe o `disablesleep` (pode pedir admin) e arranca watchdog, verificador e
    /// monitor da tampa; para `.displayOnly` larga-o, pára-os, larga a assertion
    /// de system e repõe o painel se estiver apagado. Se o `pmset` falhar
    /// (prompt recusado), a troca é rejeitada: devolve `false` e o modo guardado
    /// não muda — quem chama volta a ler o modelo para o picker recuar. Uma
    /// escolha do utilizador vale sempre: substitui o modo só desta sessão.
    @discardableResult
    func setSleepMode(_ mode: SleepMode) -> Bool {
        // Sem Sleepy ligado, ou já neste modo: só guarda.
        guard isActive, mode != activeMode else {
            Self.sleepMode = mode
            sessionModeOverride = nil
            return true
        }
        switch mode {
        case .lidClosedAwake:
            guard setDisableSleep(true) else { return false }
            Self.sleepMode = mode
            sessionModeOverride = nil
            startModeServices(for: mode)
        case .displayOnly:
            // Antes do pmset, como no `disable()`: o verificador não repõe o 1.
            setRestoreAllowed(false)
            guard setDisableSleep(false) else {
                setRestoreAllowed(true)
                return false
            }
            Self.sleepMode = mode
            sessionModeOverride = nil
            CrashWatchdog.stop()
            startModeServices(for: mode)
        }
        // Acrescenta ou larga a assertion de system (e a de ecrã, se o painel estava apagado).
        if !ensureAssertions() {
            NSLog("Sleepy: falha a ajustar as power assertions ao novo modo — o ecrã ou o Mac podem adormecer")
        }
        NSLog("Sleepy: modo \(mode.rawValue)")
        onStateChange?()
        return true
    }

    /// Lets go of what this process holds (power assertions, auto-off timer)
    /// but leaves `pmset disablesleep` and the persisted state untouched, so
    /// whoever runs Sleepy next — Hone after a relaunch, or the old app — re-arms
    /// through `restoreOnLaunch`. Never prompts. O watchdog de crash também
    /// fica vivo: se ninguém pegar nisto, é ele que larga o disablesleep.
    func suspend() {
        stopRemoteMonitor()
        // A espera fica em disco: o próximo `restoreOnLaunch` volta a armar o monitor.
        claudeMonitor.stop()
        claudeActivity = nil
        setRestoreAllowed(false)
        stopLidMonitor()
        stopVerification()
        releaseAssertion()
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        isActive = false
        syncMouseNudger()
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
        // Em `.displayOnly` não há disablesleep para confirmar (nem repor).
        guard isActive, activeMode.usesDisableSleep, !verifyInFlight else { return }
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
        // Uma verificação que ficou a meio de uma troca para `.displayOnly` não conta.
        guard isActive, activeMode.usesDisableSleep else { return }
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

    /// Os timers de fundo do Sleepy ligado: o verificador do SleepDisabled (só
    /// `.lidClosedAwake`; em `.displayOnly` o `verifySleepDisabled` é no-op) e
    /// a bateria/temperatura (os dois modos).
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
            // Um fim de sessão remota que não pegou (o desligar falhou) tenta-se de novo.
            self?.reconcileRemoteSession()
            // O teto da espera pelo Claude, e um "acabou" cujo desligar falhou.
            self?.reconcileClaudeWait()
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
    /// Em `.displayOnly` o `SleepDisabled` não faz parte da decisão: o estado é
    /// só a intenção guardada (um 1 sobrado repõe-se a 0 à parte).
    static func restoreDecision(mode: SleepMode = .lidClosedAwake,
                                persistedActive: Bool, expired: Bool,
                                resetSucceeded: Bool, systemValue: Bool?) -> RestoreDecision {
        if mode == .displayOnly {
            return persistedActive && !expired
                ? .init(active: true, clearPersisted: false, keepActiveSince: true)
                : .init(active: false, clearPersisted: true, keepActiveSince: false)
        }
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
        // O modo da sessão que ficou em disco (se o gatilho remoto a ligou), não o guardado.
        let mode = activeMode
        let persistedActive = SleepyDefaults.store.bool(forKey: activeKey)
        // Uma espera pelo Claude que caducou (teto, ou o Mac reiniciou) conta como um
        // prazo passado durante a paragem: reset calado, sem aviso nem ação no fim.
        let expired = autoOffExpired()
            || Self.claudeWaitIsStale(armedSince: waitForClaudeSince, bootTime: Self.bootTime(), now: Date())

        var resetSucceeded = false
        var systemValue: Bool?
        if mode.usesDisableSleep {
            if persistedActive && !expired {
                _ = PrivilegedAccess.setDisableSleep(true)
            } else {
                resetSucceeded = PrivilegedAccess.setDisableSleep(false)
            }
            // O ícone segue o que o sistema diz, não o que julgamos ter feito. Sem
            // acesso sem password não conseguimos mexer no disablesleep em silêncio,
            // e mentir sobre o estado seria pior do que mostrá-lo.
            systemValue = Self.systemSleepDisabled()
        } else if Self.systemSleepDisabled() == true {
            // Neste modo não há disablesleep: um 1 sobrado (crash, modo trocado
            // por fora) repõe-se a 0 em silêncio, e só com o caminho sem password.
            if !PrivilegedAccess.setDisableSleep(false) {
                NSLog("Sleepy: SleepDisabled sobrado a 1 e sem acesso sem password para o repor — o Mac pode não adormecer com a tampa fechada")
            }
        }
        let decision = Self.restoreDecision(
            mode: mode, persistedActive: persistedActive, expired: expired,
            resetSucceeded: resetSucceeded, systemValue: systemValue)
        if decision.clearPersisted { clearPersisted() }
        isActive = decision.active
        if isActive {
            if !ensureAssertions() {
                NSLog("Sleepy: falha a criar as power assertions no arranque — o ecrã ou o Mac podem adormecer")
            }
            SleepyDefaults.store.set(true, forKey: activeKey)
            if !decision.keepActiveSince || activeSince == nil { activeSince = Date() }
            // Crash a meio de uma tampa fechada: o brilho ficou a 0. De tampa
            // fechada não se repõe aqui — o monitor volta a apagar ou repõe
            // (em `.displayOnly` não há monitor: o `startModeServices` repõe).
            if mode.usesDisableSleep, LidDisplay.dimmedByUs, !LidMonitor.current().lidClosed { LidDisplay.restore() }
            // O mesmo para o LPM e o som. Tampa fechada: o monitor trata (e não repete o que já está feito).
            if LidExtras.hasPending, !LidMonitor.current().lidClosed { LidExtras.restore() }
            startModeServices(for: mode)
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
        resumeRemoteTracking()
        resumeClaudeWait()
        syncMouseNudger()
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
        // Também cobre a troca para `.displayOnly` e o Sleepy a desligar-se.
        LidExtras.restore()
        guard wasDimmed || LidDisplay.dimmedByUs else { return }
        LidDisplay.restore()
        NSLog("Sleepy: a largar a tampa — brilho do painel e do teclado repostos")
    }

    /// Único ponto de entrada das mudanças de tampa/ecrã externo (já estabilizadas).
    func lidStateChanged(_ state: LidState) {
        // Em `.displayOnly` ninguém apaga o painel: a tampa fechada adormece o Mac.
        guard isActive, activeMode.usesDisableSleep else { return }
        // Fechar ou abrir a tampa muda o que a térmica conta (só `.serious` com a
        // tampa fechada sem externo) e a bateria com a tampa fechada interessa já:
        // avalia-se agora, não só no próximo tick. Sem reentrada: desligar daqui
        // passa por `disable()` → `stopLidMonitor()`, que só pára o monitor (não
        // volta a chamar esta função). Corre depois de tudo, também nos `return`.
        defer { checkPowerGuards(reason: state.lidClosed ? "tampa fechada" : "tampa aberta") }
        if LidMonitor.shouldDim(state) {
            // O sleep da tampa chega uns 5–8 s depois de fechar: dá tempo de
            // confirmar o SleepDisabled e, se caiu, repô-lo.
            verifySleepDisabled(reason: "tampa fechada")
            guard !lidDimmed else { return }
            lidDimmed = true
            releaseAssertion(ofType: kIOPMAssertionTypePreventUserIdleDisplaySleep)
            LidDisplay.dim()
            LidExtras.apply()
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
        // Tampa aberta ou ecrã externo: repõe o LPM e o som, também os de uma sessão anterior.
        LidExtras.restore()
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

    /// Segundos somados ao prazo com o "+1 h". Persistido (sobrevive a um
    /// relançamento); limpa-se ao ligar, ao desligar e ao mudar a duração.
    private var autoOffExtension: TimeInterval {
        get { SleepyDefaults.store.double(forKey: Self.autoOffExtensionKey) }
        set {
            if newValue > 0 {
                SleepyDefaults.store.set(newValue, forKey: Self.autoOffExtensionKey)
            } else {
                SleepyDefaults.store.removeObject(forKey: Self.autoOffExtensionKey)
            }
        }
    }

    /// Quando o auto-desligar dispara: início + duração + extensão. Em "Até às"
    /// (`untilClockMinutes`) é a primeira ocorrência da hora depois do mais tardio
    /// de `since` e `untilSetAt`, mais a extensão. `nil` com a duração a 0 (nunca). Pura.
    static func autoOffDate(since: Date, minutes: Int, extension seconds: TimeInterval = 0,
                            untilClock: Int = 18 * 60, untilSetAt: Date? = nil,
                            calendar: Calendar = .current) -> Date? {
        if minutes == untilClockMinutes {
            let anchor = max(since, untilSetAt ?? since)
            return untilDate(clock: untilClock, after: anchor, calendar: calendar)
                .addingTimeInterval(max(0, seconds))
        }
        guard minutes > 0 else { return nil }
        return since.addingTimeInterval(TimeInterval(minutes) * 60 + max(0, seconds))
    }

    /// A primeira ocorrência de `clock` (minutos desde a meia-noite) estritamente
    /// depois de `anchor`: à hora exata conta a do dia seguinte. Pura.
    static func untilDate(clock: Int, after anchor: Date, calendar: Calendar = .current) -> Date {
        let c = min(max(clock, 0), 24 * 60 - 1)
        let time = DateComponents(hour: c / 60, minute: c % 60, second: 0)
        // `.nextTime`: uma hora que não existe (salto da primavera) passa para a seguinte.
        return calendar.nextDate(after: anchor, matching: time, matchingPolicy: .nextTime)
            ?? anchor.addingTimeInterval(24 * 3600)
    }

    /// O prazo para a linha de estado do painel: "Desliga sozinho às 18:00", com
    /// "amanhã" ou a data (dd/MM) se não for hoje; com o prazo já passado, o
    /// auto-desligar falhou. Pura.
    static func autoOffLabel(off: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = formatted(off, "HH:mm", calendar: calendar)
        if off <= now { return "Não desligou às \(time) — desliga à mão" }
        if calendar.isDate(off, inSameDayAs: now) { return "Desliga sozinho às \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(off, inSameDayAs: tomorrow) {
            return "Desliga sozinho amanhã às \(time)"
        }
        return "Desliga sozinho a \(formatted(off, "dd/MM", calendar: calendar)) às \(time)"
    }

    private static func formatted(_ date: Date, _ format: String, calendar: Calendar) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = format
        return fmt.string(from: date)
    }

    /// `autoOffDate` com as preferências e o estado desta sessão.
    private func deadline(since: Date) -> Date? {
        Self.autoOffDate(since: since, minutes: Self.autoOffMinutes, extension: autoOffExtension,
                         untilClock: Self.autoOffUntilClock, untilSetAt: Self.autoOffUntilSetAt)
    }

    /// Já avisámos (5 min antes) que o auto-desligar se aproxima. Em disco, ligado
    /// ao `activeSince` da sessão: um relançamento dentro da janela não repete o
    /// aviso, e uma sessão nova nunca herda o de outra. Volta a armar ao prolongar
    /// ou mudar a duração.
    private var autoOffWarned: Bool {
        get {
            Self.sameSession(SleepyDefaults.store.object(forKey: Self.autoOffWarnedKey) as? Date,
                             activeSince: activeSince)
        }
        set {
            if newValue, let since = activeSince {
                SleepyDefaults.store.set(since, forKey: Self.autoOffWarnedKey)
            } else {
                SleepyDefaults.store.removeObject(forKey: Self.autoOffWarnedKey)
            }
        }
    }

    /// `stamp` marca a sessão que começou em `activeSince`? Com folga de 1 s para
    /// arredondamentos. Pura.
    static func sameSession(_ stamp: Date?, activeSince: Date?) -> Bool {
        guard let stamp, let activeSince else { return false }
        return abs(stamp.timeIntervalSince(activeSince)) < 1
    }

    /// Chave do `userInfo` do aviso: o `activeSince` (segundos desde 1970) da
    /// sessão que o mandou.
    static let sessionInfoKey = "activeSince"

    static func notificationUserInfo(activeSince: Date) -> [AnyHashable: Any] {
        [sessionInfoKey: activeSince.timeIntervalSince1970]
    }

    /// O "Mais 1 h" desta notificação é para a sessão atual? Uma notificação de uma
    /// sessão antiga (ou sem marca) não prolonga nada. Pura.
    static func notificationMatchesSession(_ userInfo: [AnyHashable: Any], activeSince: Date?) -> Bool {
        guard let seconds = (userInfo[sessionInfoKey] as? NSNumber)?.doubleValue else { return false }
        return sameSession(Date(timeIntervalSince1970: seconds), activeSince: activeSince)
    }

    /// Faltam no máximo 5 min (e ainda não passou o prazo) e ainda não avisámos.
    static let autoOffWarning: TimeInterval = 5 * 60

    static func shouldWarnBeforeAutoOff(offDate: Date, now: Date, alreadyWarned: Bool) -> Bool {
        let remaining = offDate.timeIntervalSince(now)
        return !alreadyWarned && remaining > 0 && remaining <= autoOffWarning
    }

    /// Momento em que o auto-off vai disparar, para mostrar no menu.
    var autoOffDate: Date? {
        // Uma sessão ligada pelo gatilho remoto não tem prazo: acaba com a sessão.
        // Com a espera pelo Claude também não: acaba com ele (ou no teto).
        guard isActive, Self.hasDeadline(startedByTrigger: startedByTrigger, waitingForClaude: waitsForClaude),
              let since = activeSince else { return nil }
        return deadline(since: since)
    }

    private func autoOffExpired() -> Bool {
        guard Self.hasDeadline(startedByTrigger: startedByTrigger, waitingForClaude: waitsForClaude),
              let since = activeSince,
              let off = deadline(since: since)
        else { return false }
        return Date() >= off
    }

    /// O prazo do "Desligar sozinho" aplica-se? Nem numa sessão do gatilho remoto
    /// nem com a espera pelo Claude armada. Pura.
    static func hasDeadline(startedByTrigger: Bool, waitingForClaude: Bool) -> Bool {
        !startedByTrigger && !waitingForClaude
    }

    /// Adia o desligar sozinho (por omissão, 1 h). Só com o Sleepy ligado e com
    /// auto-desligar (com "Nunca" não há prazo para adiar). Volta a armar o aviso.
    func extendSession(by seconds: TimeInterval = 3600) {
        guard isActive, seconds > 0, autoOffDate != nil else { return }
        autoOffExtension += seconds
        autoOffWarned = false
        scheduleAutoOff()
        onStateChange?()
    }

    /// O "Mais 1 h" tocado numa notificação: só prolonga a sessão que a mandou.
    func extendSession(fromNotification userInfo: [AnyHashable: Any]) {
        guard Self.notificationMatchesSession(userInfo, activeSince: activeSince) else {
            NSLog("Sleepy: «Mais 1 h» de uma notificação de outra sessão — ignorado")
            return
        }
        extendSession()
    }

    /// Cinco minutos antes do prazo, uma vez por sessão: notifica, com a ação "Mais 1 h".
    private func warnBeforeAutoOffIfNeeded() {
        guard let off = autoOffDate, let since = activeSince,
              Self.shouldWarnBeforeAutoOff(offDate: off, now: Date(), alreadyWarned: autoOffWarned) else { return }
        autoOffWarned = true
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        Notifier.shared.notify("O Sleepy desliga-se às \(fmt.string(from: off))",
                               category: Notifier.autoOffCategory,
                               userInfo: Self.notificationUserInfo(activeSince: since))
    }

    private func clearPersisted() {
        SleepyDefaults.store.set(false, forKey: activeKey)
        SleepyDefaults.store.removeObject(forKey: activeSinceKey)
        SleepyDefaults.store.removeObject(forKey: Self.autoOffWarnedKey)
        autoOffExtension = 0
        startedByTrigger = false
        sessionModeOverride = nil
        waitForClaudeSince = nil
    }

    /// Verificação periódica em vez de um único timer para o prazo todo: um
    /// timer longo escorrega se a máquina chegar a dormir ou a entrar em dark
    /// wake, e o prazo passaria despercebido. Comparar contra o relógio de
    /// parede a cada 15s custa nada e não pode escorregar. Com o prazo já
    /// passado dispara logo, mas o timer fica a tentar de novo se não der.
    /// `silent`: esse disparo imediato não pede admin (arranque); os seguintes sim.
    private func scheduleAutoOff(silent: Bool = false) {
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffPromptDeclined = false
        guard isActive, autoOffDate != nil else { return }
        if autoOffExpired() { autoOff(silent: silent) }
        // Desligou, ou passou a sessão remota (sem prazo): nada a vigiar.
        guard isActive, autoOffDate != nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.autoOffExpired() else {
                self.warnBeforeAutoOffIfNeeded()
                return
            }
            self.autoOff()
        }
        timer.tolerance = 5
        // .common para continuar a correr enquanto um menu/popover está aberto.
        RunLoop.main.add(timer, forMode: .common)
        autoOffTimer = timer
    }

    /// O prazo passou. Com uma sessão remota ativa (e o gatilho ligado e não
    /// travado), desligar cortava-a — o `sleepnow` ou a ação no fim deitam o SSH
    /// abaixo: passa a sessão do gatilho, que acaba com ela (ou no teto de 12 h).
    /// O fim da espera pelo Claude (`reason`) segue a mesma regra.
    private func autoOff(_ reason: StopReason = .autoOff, silent: Bool = false) {
        if Self.autoOffKeepsRemoteSession(preference: Self.stayAwakeForRemoteSessions,
                                          sessionsActive: remoteSessions?.isActive == true,
                                          suppressed: remoteSuppressed) {
            convertToTriggerSession(reason)
            return
        }
        stopAutomatically(reason, silent: silent)
    }

    /// Ver `autoOff()`. Pura.
    static func autoOffKeepsRemoteSession(preference: Bool, sessionsActive: Bool, suppressed: Bool) -> Bool {
        preference && sessionsActive && !suppressed
    }

    private func convertToTriggerSession(_ reason: StopReason) {
        let label = remoteSessions.flatMap(RemoteSessionMonitor.label) ?? "sessão remota ativa"
        let what = reason == .autoOff ? "prazo do auto-desligar" : "fim da espera pelo Claude"
        NSLog("Sleepy: \(what) com \(label) — passa a sessão remota (acaba com ela, teto de 12 h)")
        // Uma sessão do gatilho não espera pelo Claude.
        disarmClaudeWait()
        startedByTrigger = true
        // O teto conta a partir daqui.
        activeSince = Date()
        autoOffExtension = 0
        autoOffWarned = false
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        onStateChange?()
    }

    /// Desliga o Sleepy sozinho e diz porquê. Único caminho do auto-desligar, do
    /// limite de bateria, da proteção térmica, do fim da sessão remota (este
    /// sem aviso, sem ação no fim e sem prompt de admin) e da espera pelo Claude
    /// (sem prompt de admin). `silent`: sem prompt de admin desta vez (o disparo
    /// do arranque).
    func stopAutomatically(_ reason: StopReason, silent: Bool = false) {
        guard isActive else { return }
        // Tampa fechada com ecrã externo é um Mac em uso: há prompt (vê-se no
        // externo) e não se manda dormir.
        let closed = LidMonitor.current().closedWithoutExternal
        let lid = closed ? "fechada sem ecrã externo" : "aberta ou com ecrã externo"
        switch reason {
        case .autoOff:
            let when = Self.autoOffMinutes == Self.untilClockMinutes
                ? "à hora marcada (\(Self.clockText(Self.autoOffUntilClock)))"
                : "ao fim de \(Self.autoOffMinutes) min"
            NSLog("Sleepy: auto-desligar \(when) (tampa \(lid))")
        case .battery(let percent): NSLog("Sleepy: a desligar com a bateria a \(percent) % (tampa \(lid))")
        case .thermal: NSLog("Sleepy: a desligar, o Mac está a aquecer (tampa \(lid))")
        case .remoteSessionEnded: NSLog("Sleepy: a sessão remota terminou — a desligar (tampa \(lid))")
        case .remoteSessionCap: NSLog("Sleepy: sessão remota ligada há mais de 12 h — a desligar (tampa \(lid))")
        case .claudeFinished: NSLog("Sleepy: o Claude acabou as tarefas — a desligar (tampa \(lid))")
        case .claudeIdle: NSLog("Sleepy: o Claude não estava a trabalhar — a desligar sem ação no fim (tampa \(lid))")
        case .claudeCap: NSLog("Sleepy: 12 h à espera do Claude — a desligar (tampa \(lid))")
        }
        // Já marcado para o `disable()` publicar o motivo de uma vez; se falhar, desfaz-se.
        lastStop = (reason, Date())
        // De tampa fechada sem externo, ou numa sessão do gatilho, não pode haver
        // prompt de admin: era invisível e ficava a bloquear a app. Só o caminho
        // sem password.
        let allowPrompt = Self.stopAllowsPrompt(
            reason: reason, lidClosedWithoutExternal: closed, promptDeclined: autoOffPromptDeclined,
            startedByTrigger: startedByTrigger, silent: silent)
        disable(allowPrompt: allowPrompt, suppressRemote: reason.suppressesRemoteTrigger)
        guard !isActive else {
            lastStop = nil
            NSLog("Sleepy: desligar sozinho falhou — sem acesso sem password instalado")
            // Os timers continuam: tentam de novo em silêncio (15s o auto-desligar,
            // 30s e as mudanças de bateria/temperatura o resto) e, ao abrir a
            // tampa, pede admin uma vez. Recusado, não volta a pedir.
            autoOffPromptDeclined = Self.promptDeclinedAfterFailedStop(allowPrompt: allowPrompt,
                                                                       wasDeclined: autoOffPromptDeclined)
            // Sem sudo, uma sessão do gatilho nunca se desligava: passa a normal, com prazo.
            if Self.failedStopBecomesTimedSession(reason: reason, startedByTrigger: startedByTrigger) {
                NSLog("Sleepy: a sessão remota não se desligou — passa a sessão normal, com prazo")
                becomeTimedSession()
            }
            return
        }
        if reason.notifies {
            Notifier.shared.notify("Sleepy desligou-se — \(reason.notificationReason).")
        }
        // Repor o disablesleep não faz o Mac adormecer sozinho: o evento de
        // lid-close já foi consumido e ele fica acordado até ao idle. De tampa
        // fechada é o comportamento que o utilizador espera, por isso pedimos
        // o sleep explicitamente (o pmset sleepnow não precisa de privilégios).
        guard closed else {
            // Ação escolhida para o fim (só tempo e bateria). Com a tampa
            // fechada sem externo o Mac já dorme, por isso não chega aqui.
            if let command = Self.endCommand(action: Self.endAction, reason: reason) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.run(command) }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.sleepNow() }
    }

    // MARK: - Sessões remotas

    /// O modo de uma sessão ligada pelo gatilho. Sem ninguém ao ecrã não há prompt
    /// de admin, por isso "fica acordado" só com o sudo silencioso; senão só ecrã.
    /// Pura.
    static func effectiveMode(stored: SleepMode, passwordless: Bool) -> SleepMode {
        stored.usesDisableSleep && !passwordless ? .displayOnly : stored
    }

    /// Desliga no fim da sessão? Só se foi o gatilho a ligar: o que o utilizador
    /// ligou à mão fica como está. Pura.
    static func shouldStopForEndedSession(startedByTrigger: Bool, sessionActive: Bool) -> Bool {
        startedByTrigger && !sessionActive
    }

    /// O que fazer com um estado novo do monitor.
    enum RemoteTriggerDecision: Equatable {
        case start, stop, nothing, clearSuppression
    }

    /// Sessões ativas: liga, salvo se já está ligado ou se o gatilho está travado
    /// (desligado à mão durante a sessão). Sem sessões: desliga o que o gatilho
    /// ligou e destrava. Pura.
    static func remoteTriggerDecision(sessionsActive: Bool, isActive: Bool,
                                      startedByTrigger: Bool, suppressed: Bool) -> RemoteTriggerDecision {
        if sessionsActive { return isActive || suppressed ? .nothing : .start }
        if isActive && startedByTrigger { return .stop }
        return suppressed ? .clearSuppression : .nothing
    }

    /// Teto de uma sessão do gatilho, mesmo com sessões a contar: uma entrada do
    /// utmpx que ficou (ou um pid reciclado) não deixa o Mac acordado sem fim.
    static let remoteSessionCap: TimeInterval = 12 * 3600

    static func remoteCapReached(since: Date, now: Date) -> Bool {
        now.timeIntervalSince(since) >= remoteSessionCap
    }

    /// Um desligar que falhou no fim (ou no teto) de uma sessão do gatilho passa-a
    /// a sessão normal, com prazo; os outros tentam de novo. Pura.
    static func failedStopBecomesTimedSession(reason: StopReason, startedByTrigger: Bool) -> Bool {
        startedByTrigger && reason.endsTriggerSession
    }

    /// Para a linha de estado do painel ("sessão SSH ativa"). `nil` se o Sleepy
    /// está desligado ou foi ligado à mão.
    var remoteSessionLabel: String? {
        guard isActive, startedByTrigger else { return nil }
        return remoteSessions.flatMap(RemoteSessionMonitor.label) ?? "sessão remota ativa"
    }

    /// Liga ou desliga o monitor com a preferência. Desligada com uma sessão do
    /// gatilho a correr, desliga-a. Com o tool parado só se guarda.
    private func remotePreferenceChanged() {
        guard toolRunning else { return }
        if Self.stayAwakeForRemoteSessions {
            startRemoteMonitor()
            return
        }
        stopRemoteMonitor()
        if isActive, startedByTrigger { releaseTriggerSession() }
    }

    private func startRemoteMonitor() {
        guard !remoteMonitor.isRunning else { return }
        remoteMonitor.start { [weak self] sessions in self?.remoteSessionsChanged(sessions) }
        NSLog("Sleepy: a seguir sessões remotas (SSH e partilha de ecrã)")
    }

    func stopRemoteMonitor() {
        guard remoteMonitor.isRunning else { return }
        remoteMonitor.stop()
        remoteSessions = nil
        NSLog("Sleepy: deixou de seguir sessões remotas")
    }

    /// No arranque: segue as sessões se a preferência o pede e resolve o que o
    /// gatilho deixou ligado antes de a app fechar (a sessão pode ter acabado).
    private func resumeRemoteTracking() {
        let enabled = Self.stayAwakeForRemoteSessions
        if enabled { startRemoteMonitor() } else { stopRemoteMonitor() }
        guard isActive, startedByTrigger else { return }
        guard enabled else {
            releaseTriggerSession()
            return
        }
        // Uma leitura só do utmpx e dos processos: pode ser aqui, no arranque.
        remoteSessions = RemoteSessionMonitor.read()
        reconcileRemoteSession()
    }

    /// O monitor entrega o estado já estabilizado, no main. Idempotente: repetir
    /// o mesmo estado não faz nada.
    private func remoteSessionsChanged(_ sessions: RemoteSessions) {
        guard Self.stayAwakeForRemoteSessions else { return }
        remoteSessions = sessions
        NSLog("Sleepy: sessões remotas — \(RemoteSessionMonitor.label(sessions) ?? "nenhuma")")
        switch Self.remoteTriggerDecision(sessionsActive: sessions.isActive, isActive: isActive,
                                          startedByTrigger: startedByTrigger, suppressed: remoteSuppressed) {
        case .start:
            startForRemoteSession(sessions)
        case .stop:
            clearRemoteSuppression()
            reconcileRemoteSession()
        case .clearSuppression:
            clearRemoteSuppression()
        case .nothing:
            if !isActive, remoteSuppressed {
                NSLog("Sleepy: foi desligado durante esta sessão remota — não volta a ligar até ela acabar")
            }
            // Ligado à mão: não se mexe. Ligado pelo gatilho: o texto do painel pode mudar.
            if isActive, startedByTrigger { onStateChange?() }
        }
    }

    private func clearRemoteSuppression() {
        guard remoteSuppressed else { return }
        remoteSuppressed = false
        NSLog("Sleepy: as sessões remotas acabaram — o gatilho volta a poder ligar")
    }

    /// Liga por causa de uma sessão remota. Nunca pede password: não há ninguém
    /// ao ecrã. O modo guardado não muda; se a sessão usa outro, é um modo só dela.
    private func startForRemoteSession(_ sessions: RemoteSessions) {
        guard !remoteSuppressed else {
            NSLog("Sleepy: sessão remota ativa, mas o gatilho está travado (desligado durante ela)")
            return
        }
        let stored = Self.sleepMode
        let mode = Self.effectiveMode(stored: stored, passwordless: PrivilegedAccess.isInstalled)
        let label = RemoteSessionMonitor.label(sessions) ?? "sessão remota"
        NSLog("Sleepy: \(label) — a ligar em modo \(mode.rawValue)")
        if enable(sessionMode: mode == stored ? nil : mode, byTrigger: true) { return }
        // A flag diz que há sudo silencioso mas ele falhou (regra apagada por fora): só ecrã.
        guard mode.usesDisableSleep else { return }
        NSLog("Sleepy: sem acesso sem password a sério — a ligar só o ecrã")
        enable(sessionMode: .displayOnly, byTrigger: true)
    }

    /// Desliga o que o gatilho ligou quando a sessão acaba, ou ao fim do teto de
    /// 12 h. Chamado pelo monitor, no arranque e de 30 em 30 s. Sem leitura do
    /// monitor não desliga pelo fim da sessão: o desconhecido nunca desliga.
    private func reconcileRemoteSession() {
        guard isActive, startedByTrigger else { return }
        if let since = activeSince, Self.remoteCapReached(since: since, now: Date()) {
            stopAutomatically(.remoteSessionCap)
            return
        }
        guard Self.stayAwakeForRemoteSessions,
              let sessions = remoteSessions,
              Self.shouldStopForEndedSession(startedByTrigger: startedByTrigger, sessionActive: sessions.isActive)
        else { return }
        stopAutomatically(.remoteSessionEnded)
    }

    /// A preferência foi desligada com uma sessão do gatilho a correr: desliga-a,
    /// sem aviso nem prompt. Se não deu, passa a sessão normal, com prazo, em vez
    /// de ficar ligada sem fim.
    private func releaseTriggerSession() {
        NSLog("Sleepy: gatilho remoto desligado — a desligar a sessão que ele tinha ligado")
        disable(allowPrompt: false)
        guard isActive else { return }
        becomeTimedSession()
    }

    /// Uma sessão do gatilho que não se desligou passa a sessão normal: prazo a
    /// contar de agora, e o painel deixa de dizer "sessão remota ativa".
    private func becomeTimedSession() {
        startedByTrigger = false
        activeSince = Date()
        scheduleAutoOff()
        onStateChange?()
    }

    // MARK: - Até o Claude acabar

    /// Teto da espera, a contar de quando foi armada: um transcript que fica a
    /// parecer "a trabalhar" não deixa o Mac acordado sem fim.
    static let claudeWaitCap: TimeInterval = 12 * 3600

    /// Com a espera armada desde `armedSince`: desliga por isto, ou `nil` para
    /// continuar. O teto ganha a tudo; sem leitura do monitor não desliga. Acabado
    /// sem nunca ter visto trabalho é `.claudeIdle` (sem ação no fim). Pura.
    static func claudeWaitStop(armedSince: Date, activity: ClaudeActivity?, now: Date) -> StopReason? {
        if now.timeIntervalSince(armedSince) >= claudeWaitCap { return .claudeCap }
        guard let activity, activity.finished else { return nil }
        return activity.sawWork ? .claudeFinished : .claudeIdle
    }

    /// Uma espera que ficou em disco já não vale: passou o teto, ou o Mac arrancou
    /// depois de ela ser armada (as tarefas do Claude não sobrevivem a um reinício).
    /// Sem espera, não. Sem `bootTime` só conta o teto. Pura.
    static func claudeWaitIsStale(armedSince: Date?, bootTime: Date?, now: Date) -> Bool {
        guard let armedSince else { return false }
        if now.timeIntervalSince(armedSince) >= claudeWaitCap { return true }
        return bootTime.map { $0 > armedSince } ?? false
    }

    /// Quando o Mac arrancou (`kern.boottime`); `nil` se a leitura falhar.
    static func bootTime() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }

    /// O monitor só lê o disco com a espera armada, o Sleepy ligado e o tool a correr. Pura.
    static func claudeMonitorShouldRun(waiting: Bool, isActive: Bool, toolRunning: Bool) -> Bool {
        waiting && isActive && toolRunning
    }

    /// Para a linha de estado do painel. `nil` sem a espera armada.
    var claudeWaitText: String? {
        guard isActive, waitsForClaude else { return nil }
        return ClaudeActivityMonitor.statusText(claudeActivity)
    }

    /// Arma ou desarma a espera. Armar com o Sleepy desligado liga-o primeiro
    /// (`enable()` normal, pode pedir admin): se não ligar, nada fica armado e
    /// devolve `false`. Nunca numa sessão do gatilho remoto. Desarmar com o
    /// Sleepy ligado deixa-o ligado, e o prazo normal conta a partir de agora
    /// (desde o `activeSince` podia disparar logo).
    @discardableResult
    func setWaitForClaude(_ on: Bool) -> Bool {
        if on {
            guard !waitsForClaude else { return true }
            if !isActive { enable() }
            guard isActive, !startedByTrigger else { return false }
            waitForClaudeSince = Date()
            claudeActivity = nil
            NSLog("Sleepy: a esperar que o Claude acabe (sem prazo, teto de 12 h)")
            // Sem prazo: larga o timer do auto-desligar.
            scheduleAutoOff()
            syncClaudeMonitor()
        } else {
            guard waitsForClaude else { return true }
            disarmClaudeWait()
            NSLog("Sleepy: espera pelo Claude desarmada")
            if isActive {
                activeSince = Date()
                autoOffExtension = 0
                autoOffWarned = false
                scheduleAutoOff()
            }
        }
        onStateChange?()
        return true
    }

    /// Esquece a espera (também em disco) e larga o monitor. Idempotente.
    private func disarmClaudeWait() {
        waitForClaudeSince = nil
        claudeActivity = nil
        syncClaudeMonitor()
    }

    private func syncClaudeMonitor() {
        if Self.claudeMonitorShouldRun(waiting: waitsForClaude, isActive: isActive, toolRunning: toolRunning) {
            guard !claudeMonitor.isRunning else { return }
            claudeMonitor.start { [weak self] activity in self?.claudeActivityChanged(activity) }
        } else {
            claudeMonitor.stop()
        }
    }

    /// O monitor entrega só quando a leitura muda, no main.
    private func claudeActivityChanged(_ activity: ClaudeActivity) {
        guard isActive, waitsForClaude else { return }
        claudeActivity = activity
        if activity.finished { NSLog("Sleepy: nenhuma sessão do Claude a trabalhar há 2 min") }
        reconcileClaudeWait()
        // Continua ligado: o painel mostra o número novo.
        if isActive { onStateChange?() }
    }

    /// Desliga quando o Claude acabou ou no teto. Chamado pelo monitor e de 30 em
    /// 30 s (um desligar que falhou tenta-se de novo). Nunca pede admin (ver
    /// `StopReason.allowsAdminPrompt`). Com uma sessão remota a seguir, passa a
    /// sessão do gatilho, como o auto-desligar.
    private func reconcileClaudeWait() {
        guard isActive, let since = waitForClaudeSince,
              let reason = Self.claudeWaitStop(armedSince: since, activity: claudeActivity, now: Date())
        else { return }
        autoOff(reason)
    }

    /// No arranque: a espera que ficou em disco volta a armar o monitor (a
    /// leitura recomeça, com a confirmação de 2 min). Uma espera caducada já foi
    /// tratada pelo `restoreOnLaunch` como prazo passado; só chega aqui se o
    /// reset não pegou — larga a espera e deixa o prazo normal tentar de novo,
    /// em silêncio, sem a ação no fim.
    private func resumeClaudeWait() {
        guard let since = waitForClaudeSince else { return }
        guard isActive, !startedByTrigger else {
            disarmClaudeWait()
            return
        }
        if Self.claudeWaitIsStale(armedSince: since, bootTime: Self.bootTime(), now: Date()) {
            NSLog("Sleepy: a espera pelo Claude caducou (teto ou reinício do Mac) — volta ao prazo normal")
            disarmClaudeWait()
            scheduleAutoOff(silent: true)
            return
        }
        NSLog("Sleepy: a retomar a espera pelo Claude")
        syncClaudeMonitor()
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
        let closed = Self.closedForThermal(thermal, lid: LidMonitor.current())
        if thermalGuard.shouldStop(state: thermal, closedWithoutExternal: closed, at: Date()) {
            NSLog("Sleepy: estado térmico \(thermal.rawValue) (\(reason))")
            // `.critical` também dispara de tampa aberta: diz-se a verdade.
            stopAutomatically(.thermal(lidClosed: closed))
            return
        }
        updateThermalRecheck()
    }

    /// O que o `ThermalGuard` entende por "tampa fechada sem ecrã externo". A
    /// tampa só interessa a partir de `.serious`: abaixo disso nem se lê (daí o
    /// autoclosure, que evita o IOKit). Pura.
    static func closedForThermal(_ state: ProcessInfo.ThermalState, lid: @autoclosure () -> LidState) -> Bool {
        state.rawValue >= ProcessInfo.ThermalState.serious.rawValue && lid().closedWithoutExternal
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

    // MARK: - Ação no fim

    /// Executa a ação já resolvida por `endCommand`. Só no main.
    private static func run(_ command: EndCommand) {
        switch command {
        case .pmset(let arguments): runPmsetInBackground(arguments)
        case .lockScreen: lockScreen()
        }
    }

    /// Bloqueia já o ecrã com `SACLockScreenImmediate` (login.framework, o que o
    /// "Bloquear ecrã" do macOS usa). É API privada: se faltar, apaga o ecrã —
    /// que com "pedir password" ativo também bloqueia. Nunca simula teclas.
    private static func lockScreen() {
        typealias LockFunction = @convention(c) () -> Int32
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            NSLog("Sleepy: SACLockScreenImmediate indisponível — a apagar o ecrã em vez de bloquear")
            runPmsetInBackground(["displaysleepnow"])
            return
        }
        _ = unsafeBitCast(symbol, to: LockFunction.self)()
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
