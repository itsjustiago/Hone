import Foundation

/// O que o Sleepy faz quando a tampa fecha.
enum SleepMode: String, CaseIterable, Identifiable {
    /// Tudo como sempre: `pmset disablesleep` (admin) + as três assertions. De
    /// tampa fechada o Mac continua acordado, com ou sem corrente.
    case lidClosedAwake
    /// Só segura o ecrã e o idle: sem `disablesleep`, sem root, sem prompt. Ao
    /// fechar a tampa o Mac dorme, mesmo na corrente.
    case displayOnly

    var id: String { rawValue }

    /// No menu.
    var title: String {
        switch self {
        case .lidClosedAwake: return "Fica acordado"
        case .displayOnly: return "Adormece"
        }
    }

    /// Na pílula da linha estreita do painel.
    var short: String {
        switch self {
        case .lidClosedAwake: return "Acordado"
        case .displayOnly: return "Dorme"
        }
    }

    /// Precisa do `disablesleep`, e por isso do verificador, do watchdog de
    /// crash e do monitor da tampa (que apaga o painel interno).
    var usesDisableSleep: Bool { self == .lidClosedAwake }
}

/// O que fazer quando o Sleepy se desliga sozinho (tempo ou bateria).
enum EndAction: String, CaseIterable, Identifiable {
    case none, sleep, lock, displayOff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Nada"
        case .sleep: return "Dormir"
        case .lock: return "Bloquear o ecrã"
        case .displayOff: return "Apagar o ecrã"
        }
    }

    /// O que correr. `nil` = nada. Puro: quem chama é que executa.
    var command: EndCommand? {
        switch self {
        case .none: return nil
        case .sleep: return .pmset(["sleepnow"])
        case .lock: return .lockScreen
        case .displayOff: return .pmset(["displaysleepnow"])
        }
    }
}

/// Uma ação no fim, já resolvida. Nunca simula teclas: o Hone partilha a
/// camada de input com outras ferramentas.
enum EndCommand: Equatable {
    /// `pmset` sem privilégios (`sleepnow`, `displaysleepnow`).
    case pmset([String])
    /// Bloqueio imediato via `login.framework`; sem ele, apaga o ecrã.
    case lockScreen
}
