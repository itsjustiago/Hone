import AppKit
import CoreGraphics

/// "Mexer o rato": o Teams e o Slack marcam-nos como ausentes pelo tempo sem
/// input (rato ou teclado) — as assertions do Sleepy seguram o Mac acordado mas
/// não contam como input. De N em N minutos sem mexermos, o cursor anda 1 px e
/// volta logo ao sítio. Só move: nunca clica, nunca carrega em teclas.
///
/// Nunca com a tampa fechada sem ecrã externo (`lidDimmed`): o painel está apagado
/// com `pmset displaysleepnow` e um movimento sintético podia acendê-lo dentro da
/// tampa. Nem com o ecrã apagado à mão (canto ativo, ⌃⇧⏏, `pmset displaysleepnow`
/// com a tampa aberta): o movimento acendia-o. Nem com o ecrã bloqueado, nem com um
/// botão do rato carregado (um arrasto em curso), nem sem a permissão do macOS para
/// postar eventos.
///
/// Não é um event tap nem um hotkey: só posta eventos (`CGEvent.post`), por isso
/// não se mete na camada de input que o Hone partilha com as outras ferramentas.
enum MouseNudge {
    /// De quanto em quanto tempo o `MouseNudger` olha para o tempo sem input.
    static let tick: TimeInterval = 30

    /// O utilizador já esteve parado quase `interval`: o próximo tick passaria do
    /// prazo, por isso mexe-se agora. Com o utilizador a mexer-se, `idle` é baixo
    /// e nada acontece. `interval` 0 = desligado.
    static func shouldNudge(idle: TimeInterval, interval: TimeInterval, tick: TimeInterval) -> Bool {
        interval > 0 && idle >= interval - tick
    }

    /// Todas as condições têm de se verificar: qualquer uma sozinha trava.
    static func canNudge(isActive: Bool, lidDimmed: Bool, displayAsleep: Bool, screenLocked: Bool,
                         buttonsDown: Bool, hasAccess: Bool) -> Bool {
        isActive && !lidDimmed && !displayAsleep && !screenLocked && !buttonsDown && hasAccess
    }

    /// Para onde mexer: 1 px para a direita, ou para a esquerda se já está na
    /// última coluna do ecrã. `y` não muda. Coordenadas globais do CoreGraphics
    /// (origem em cima à esquerda); `bounds` é o ecrã onde está o cursor. Pura.
    static func nudgeTarget(from p: CGPoint, in bounds: CGRect) -> CGPoint {
        let x = p.x + 1 >= bounds.maxX ? p.x - 1 : p.x + 1
        return CGPoint(x: x, y: p.y)
    }

    /// O pedido de permissão do sistema só aparece quando o utilizador liga a
    /// opção (de "Nunca" para um intervalo) e ainda não há acesso: nunca no
    /// arranque nem no timer. Pura.
    static func shouldRequestAccess(from old: Int, to new: Int, hasAccess: Bool) -> Bool {
        old == 0 && new > 0 && !hasAccess
    }
}

/// O timer do "Mexer o rato". Só no main. Quem decide quando corre é o
/// `SleepController.syncMouseNudger()` (Sleepy ligado, tool a correr, intervalo > 0).
final class MouseNudger {
    private var timer: Timer?
    private var interval: TimeInterval = 0

    /// `kCGAnyInputEventType` (`~0`): o tempo desde qualquer input, rato ou teclado.
    private static let anyInput = CGEventType(rawValue: ~0)

    var isRunning: Bool { timer != nil }

    /// Já a correr, só muda o intervalo: o próximo tick já o lê, sem reiniciar o relógio.
    func start(interval: TimeInterval) {
        self.interval = interval
        guard timer == nil else { return }
        let timer = Timer(timeInterval: MouseNudge.tick, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 5
        // .common para continuar a correr enquanto um menu/popover está aberto.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSLog("Sleepy: a mexer o rato quando fica \(Int(interval / 60)) min parado")
    }

    func stop() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        NSLog("Sleepy: deixou de mexer o rato")
    }

    private func tick() {
        guard let anyInput = Self.anyInput else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard MouseNudge.shouldNudge(idle: idle, interval: interval, tick: MouseNudge.tick) else { return }
        let sleepy = SleepController.shared
        guard MouseNudge.canNudge(
            isActive: sleepy.isActive, lidDimmed: sleepy.lidDimmed,
            displayAsleep: CGDisplayIsAsleep(Self.cursorDisplayID()) != 0,
            screenLocked: Self.isScreenLocked(), buttonsDown: NSEvent.pressedMouseButtons != 0,
            hasAccess: CGPreflightPostEventAccess()) else { return }
        nudge()
    }

    /// Mexe o cursor 1 px e volta ao ponto original. Dois `mouseMoved`, nada de cliques.
    private func nudge() {
        guard let origin = CGEvent(source: nil)?.location else { return }
        let target = MouseNudge.nudgeTarget(from: origin, in: Self.displayBounds())
        let source = CGEventSource(stateID: .hidSystemState)
        for point in [target, origin] {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    /// O ecrã onde está o cursor; na falta, o principal.
    private static func cursorDisplayID() -> CGDirectDisplayID {
        guard let point = CGEvent(source: nil)?.location else { return CGMainDisplayID() }
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 {
            return display
        }
        return CGMainDisplayID()
    }

    private static func displayBounds() -> CGRect {
        CGDisplayBounds(cursorDisplayID())
    }

    private static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
    }
}
