import Foundation
import IOKit

/// O que a linha de energia do painel mostra: de onde vem a energia, a
/// percentagem e os watts (se a leitura os der).
struct PowerReadoutValue: Equatable {
    enum Source: Equatable {
        /// A gastar bateria.
        case battery
        /// Na corrente e a carregar.
        case charging
        /// Na corrente, sem carregar (cheia, ou a manter).
        case plugged
    }

    var source: Source
    var percent: Int?
    var watts: Double?
}

/// Watts e bateria para a linha discreta do painel.
///
/// Em bateria, watts = |tensão × corrente| da `AppleSmartBattery`; na corrente,
/// o `SystemPowerIn` da telemetria. A percentagem e o estado vêm do IOPS
/// ([[PowerSource]]). A interpretação é pura, para testar com dicionários
/// falsos; só `current()` fala com o IOKit. Sem bateria (Mac de secretária) ou
/// com o IOPS a falhar, não há leitura e a linha não aparece.
enum PowerReadout {
    /// Teto de sanidade: acima disto a leitura é lixo, não watts.
    private static let maxPlausibleWatts = 500.0

    /// As chaves da `AppleSmartBattery` que usamos. Lidas uma a uma: o dicionário
    /// inteiro traz as tabelas da bateria, que não interessam a cada 2 s.
    private static let smartBatteryKeys = ["Voltage", "InstantAmperage", "Amperage", "PowerTelemetryData"]

    // MARK: - Interpretação (pura)

    /// `onBattery == nil` = o IOPS não leu a bateria: sem leitura. Watts em falta
    /// não anulam a linha, só a deixam sem eles.
    static func readout(smartBattery: [String: Any], percent: Int?, onBattery: Bool?,
                        charging: Bool?) -> PowerReadoutValue? {
        guard let onBattery else { return nil }
        if onBattery {
            return PowerReadoutValue(source: .battery, percent: percent,
                                     watts: batteryWatts(smartBattery))
        }
        return PowerReadoutValue(source: charging == true ? .charging : .plugged,
                                 percent: percent, watts: adapterWatts(smartBattery))
    }

    /// |mV × mA| / 10⁶. A corrente instantânea é a preferida; a `Amperage` fica de reserva.
    private static func batteryWatts(_ smartBattery: [String: Any]) -> Double? {
        guard let millivolts = number(smartBattery["Voltage"]),
              let milliamps = number(smartBattery["InstantAmperage"]) ?? number(smartBattery["Amperage"])
        else { return nil }
        return plausible(abs(millivolts * milliamps) / 1_000_000)
    }

    /// `PowerTelemetryData["SystemPowerIn"]` em mW.
    private static func adapterWatts(_ smartBattery: [String: Any]) -> Double? {
        guard let telemetry = smartBattery["PowerTelemetryData"] as? [String: Any],
              let milliwatts = number(telemetry["SystemPowerIn"]) else { return nil }
        return plausible(milliwatts / 1000)
    }

    private static func plausible(_ watts: Double) -> Double? {
        watts.isFinite && watts > 0 && watts < maxPlausibleWatts ? watts : nil
    }

    /// O registry guarda a corrente em 64 bits sem sinal: ao descarregar chega como
    /// um inteiro enorme que, lido com sinal, volta a ser o negativo certo.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return Double(number.int64Value)
    }

    // MARK: - Texto

    /// "Bateria 64 % · a gastar 7,2 W", "A carregar 64 % · 23 W", "Na corrente · 18 W".
    static func text(_ value: PowerReadoutValue) -> String {
        let percent = value.percent.map { " \($0) %" } ?? ""
        let watts = value.watts.map(formatWatts)
        switch value.source {
        case .battery:
            return "Bateria\(percent)" + (watts.map { " · a gastar \($0)" } ?? "")
        case .charging:
            return "A carregar\(percent)" + (watts.map { " · \($0)" } ?? "")
        case .plugged:
            return "Na corrente" + (watts.map { " · \($0)" } ?? "")
        }
    }

    /// Vírgula decimal. Abaixo de 10 W uma casa (7,2 W); a partir daí inteiros (23 W).
    static func formatWatts(_ watts: Double) -> String {
        let tenths = (watts * 10).rounded() / 10
        if tenths < 10 {
            return String(format: "%.1f", tenths).replacingOccurrences(of: ".", with: ",") + " W"
        }
        return "\(Int(watts.rounded())) W"
    }

    // MARK: - IOKit

    /// A leitura de agora. `nil` sem bateria ou com o IOPS a falhar. Bloqueia por
    /// instantes no registry: cabe fora do main, mas a leitura isolada no main também.
    static func current() -> PowerReadoutValue? {
        guard let description = PowerSource.currentDescription(),
              let battery = PowerSource.battery(from: description) else { return nil }
        return readout(smartBattery: smartBatteryProperties() ?? [:],
                       percent: battery.percent, onBattery: battery.onBattery,
                       charging: PowerSource.charging(from: description))
    }

    static func currentText() -> String? {
        current().map(text)
    }

    private static func smartBatteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: [String: Any] = [:]
        for key in smartBatteryKeys {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() {
                properties[key] = value
            }
        }
        return properties.isEmpty ? nil : properties
    }
}
