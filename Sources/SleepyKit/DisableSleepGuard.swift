import Foundation

/// Contabilidade das vezes que o `SleepDisabled` caiu com o Sleepy ligado, e o
/// aviso honesto que daí sai. Puro: as datas vêm de fora, para testar sem relógio.
///
/// Dois avisos, o primeiro mais grave:
/// - não deu para repor: com a tampa fechada o Mac pode adormecer;
/// - reposto `threshold` vezes ou mais em `window`: o macOS está a desfazer o que fazemos.
///
/// O aviso só limpa quando as leituras voltam a dar 1, sem precisar de reposição,
/// durante `window` seguidos — ou no `disable()`.
struct DisableSleepGuard: Equatable {
    static let window: TimeInterval = 10 * 60
    static let threshold = 3

    static let notRestoredMessage =
        "O sleep voltou a estar ligado e não deu para o desligar — com a tampa fechada o Mac pode adormecer."
    static let flappingMessage =
        "O macOS está a repor o sleep — com a tampa fechada o Mac pode adormecer."

    private enum Kind: Equatable { case notRestored, flapping }

    private var current: Kind?
    private var restorations: [Date] = []
    /// A última vez que houve problema (reposição ou falha a repor).
    private var lastTrouble: Date?

    /// O aviso a mostrar agora, ou nil.
    var warning: String? {
        switch current {
        case .notRestored: return Self.notRestoredMessage
        case .flapping: return Self.flappingMessage
        case nil: return nil
        }
    }

    /// O sistema disse 0 e a reposição pegou.
    mutating func recordRestored(at now: Date) {
        restorations.append(now)
        restorations.removeAll { now.timeIntervalSince($0) > Self.window }
        lastTrouble = now
        // Se já se repôs, o "não deu para repor" deixou de ser verdade.
        current = restorations.count >= Self.threshold ? .flapping : nil
    }

    /// O sistema disse 0 e não deu para repor.
    mutating func recordFailure(at now: Date) {
        lastTrouble = now
        current = .notRestored
    }

    /// Leitura a 1 sem precisar de reposição.
    mutating func recordOK(at now: Date) {
        guard current != nil, let last = lastTrouble else { return }
        if now.timeIntervalSince(last) >= Self.window {
            current = nil
            restorations.removeAll()
            lastTrouble = nil
        }
    }
}
