import Foundation
import IOKit.ps

/// Leitura da bateria interna. A parte que interpreta o dicionário é pura, para
/// testar com dicionários falsos; só `currentBattery()` fala com o IOKit.
enum PowerSource {
    /// Percentagem e se está em bateria, a partir da descrição de uma fonte de
    /// energia. `nil` se não for a bateria interna (UPS) ou faltar alguma chave.
    static func battery(from description: [String: Any]) -> (percent: Int, onBattery: Bool)? {
        if let type = description[kIOPSTypeKey] as? String, type != kIOPSInternalBatteryType { return nil }
        guard let current = description[kIOPSCurrentCapacityKey] as? Int,
              let max = description[kIOPSMaxCapacityKey] as? Int, max > 0,
              let state = description[kIOPSPowerSourceStateKey] as? String else { return nil }
        let percent = Int((Double(current) / Double(max) * 100).rounded())
        return (min(100, Swift.max(0, percent)), state == kIOPSBatteryPowerValue)
    }

    /// A bateria interna agora. `nil` num Mac sem bateria ou se a leitura falhar.
    static func currentBattery() -> (percent: Int, onBattery: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let reading = battery(from: description) { return reading }
        }
        return nil
    }
}

/// Desliga o Sleepy quando a bateria desce até ao limite escolhido. Puro.
struct BatteryGuard: Equatable {
    /// 0 = nunca.
    var threshold: Int
    private var failedReads = 0

    init(threshold: Int) { self.threshold = threshold }

    /// Uma leitura desconhecida (`nil`) nunca desliga. Na corrente também não:
    /// o limite é para não deixar o Mac a morrer de bateria.
    func shouldStop(percent: Int?, onBattery: Bool?) -> Bool {
        guard threshold > 0, onBattery == true, let percent else { return false }
        return percent <= threshold
    }

    /// Conta as leituras falhadas seguidas. Devolve `true` uma só vez por série
    /// (à segunda), para o log não encher num Mac sem bateria.
    mutating func recordRead(succeeded: Bool) -> Bool {
        if succeeded { failedReads = 0; return false }
        failedReads += 1
        return failedReads == 2
    }
}

/// Desliga o Sleepy quando o Mac aquece: `.critical` logo; `.serious` só depois
/// de `seriousHold` seguidos com a tampa fechada e sem ecrã externo (a mochila).
/// Puro: a data vem de fora.
struct ThermalGuard: Equatable {
    static let seriousHold: TimeInterval = 30

    private var seriousSince: Date?

    /// Já começou a contar o `.serious`: convém voltar a avaliar a tempo.
    var isCounting: Bool { seriousSince != nil }

    mutating func shouldStop(state: ProcessInfo.ThermalState,
                             closedWithoutExternal: Bool, at now: Date) -> Bool {
        switch state {
        case .critical:
            return true
        case .serious:
            // Tampa aberta ou ecrã externo: há alguém a ver o Mac, não se conta.
            guard closedWithoutExternal else { seriousSince = nil; return false }
            let since = seriousSince ?? now
            seriousSince = since
            return now.timeIntervalSince(since) >= Self.seriousHold
        default:
            seriousSince = nil
            return false
        }
    }
}

/// Avisa quando a fonte de energia ou o estado térmico mudam. Só no main:
/// a fonte de run loop e o observer ficam no main, e `onChange` também corre lá.
final class PowerWatcher {
    private var source: CFRunLoopSource?
    private var thermalObserver: NSObjectProtocol?
    private var onChange: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerWatcher>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
            source = created
        } else {
            NSLog("Sleepy: sem notificações da bateria — fica só o timer")
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.onChange?()
        }
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        source = nil
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        onChange = nil
    }
}
