import SwiftUI
import HoneDesign

/// The switch an item can carry: the same state as the one in the tool's own
/// settings, so flipping it here is flipping it there.
enum WhatsNewToggle: Hashable {
    /// A tweak or app, by module id.
    case module(String)
    /// Stats: temperature, power and network, all three together.
    case statsReadouts
    /// Sleepy: the countdown next to the menu-bar icon.
    case sleepyCountdown
    /// Sleepy: "Mexer o rato".
    case sleepyMouseNudge

    /// The app to switch on when one of its options is turned on while the app
    /// is off (`nil` for a module's own switch).
    var parentModuleID: String? {
        switch self {
        case .module: return nil
        case .statsReadouts: return "stats"
        case .sleepyCountdown, .sleepyMouseNudge: return "sleepy"
        }
    }
}

struct WhatsNewItem: Identifiable {
    let id: String
    /// SF Symbol, drawn in a circle in `tint`.
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let toggle: WhatsNewToggle?

    init(id: String, symbol: String, tint: Color, title: String, detail: String,
         toggle: WhatsNewToggle? = nil) {
        self.id = id
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.detail = detail
        self.toggle = toggle
    }
}

struct WhatsNewRelease: Identifiable {
    let version: String
    let items: [WhatsNewItem]

    var id: String { version }
}

/// What the "Novidades" window shows after an update, and the rules for when
/// it shows. Pure: the window and the tests both go through here.
enum WhatsNew {
    /// The last version whose news the user has been shown.
    static let lastSeenKey = "whatsNew.lastSeenVersion"

    // Ao lançar uma versão: acrescenta aqui as novidades dela (1–4, só o que o utilizador nota).
    // Mais recente primeiro; uma versão sem novidades visíveis fica de fora.
    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(version: "0.8.1", items: [
            WhatsNewItem(
                id: "soundly-200", symbol: "speaker.wave.3.fill", tint: VibeToolColor.soundly,
                title: "Soundly até 200 %",
                detail: "Puxa uma app acima dos 100 %. Duplo clique repõe os 100 %."),
            WhatsNewItem(
                id: "update-checks", symbol: "arrow.triangle.2.circlepath", tint: VibeToolColor.hone,
                title: "Atualizações mais cedo",
                detail: "O Hone procura versões novas de 6 em 6 horas e quando o Mac acorda."),
        ]),
        WhatsNewRelease(version: "0.8.0", items: [
            WhatsNewItem(
                id: "soundly", symbol: "speaker.wave.2", tint: VibeToolColor.soundly,
                title: "Soundly",
                detail: "Volume de cada app, direto da barra de menus.",
                toggle: .module("soundly")),
        ]),
        WhatsNewRelease(version: "0.7.0", items: [
            WhatsNewItem(
                id: "windows-shortcuts", symbol: "square.grid.2x2.fill", tint: VibeToolColor.windowsShortcuts,
                title: "Atalhos do Windows",
                detail: "Cortar e mover no Finder, F2 para mudar o nome, botões laterais do rato e ⌘Q a segurar.",
                toggle: .module("windowsShortcuts")),
            WhatsNewItem(
                id: "stats-readouts", symbol: "thermometer.medium", tint: VibeToolColor.stats,
                title: "Temperatura, energia e rede",
                detail: "Três leituras novas do Stats na barra de menus. Escolhe quais nas definições do Stats.",
                toggle: .statsReadouts),
            WhatsNewItem(
                id: "sleepy-countdown", symbol: "moon.zzz", tint: VibeToolColor.sleepy,
                title: "Sleepy com cor e contagem",
                detail: "O ícone fica laranja com o Sleepy ligado e pode mostrar quanto falta. Novo prazo: «Até às HH:MM».",
                toggle: .sleepyCountdown),
            WhatsNewItem(
                id: "sleepy-mouse-nudge", symbol: "cursorarrow.motionlines", tint: VibeToolColor.sleepy,
                title: "Mexer o rato",
                detail: "Com o Sleepy ligado, o cursor anda 1 px de 5 em 5 minutos para o Teams e o Slack não te porem ausente.",
                toggle: .sleepyMouseNudge),
        ]),
    ]

    /// The releases to show now, newest first: those after `lastSeen` and up to
    /// `current`. A skipped version's news are included. Nothing when the app was
    /// just installed (the welcome window covers it), when `lastSeen` is the
    /// current version, or after a downgrade. No `lastSeen` (an update from before
    /// this screen existed) counts as having seen nothing.
    static func pending(in releases: [WhatsNewRelease], lastSeen: String?, current: String,
                        didOnboard: Bool) -> [WhatsNewRelease] {
        guard didOnboard else { return [] }
        return releases
            .filter { release in
                guard !Updater.isNewer(release.version, than: current) else { return false }
                guard let lastSeen else { return true }
                return Updater.isNewer(release.version, than: lastSeen)
            }
            .sorted { Updater.isNewer($0.version, than: $1.version) }
    }

    /// What to record as seen: the current version, but never lower than what is
    /// already recorded (a downgrade must not make the next update show it all again).
    static func lastSeenToStore(stored: String?, current: String) -> String {
        if let stored, Updater.isNewer(stored, than: current) { return stored }
        return current
    }

    /// Testing by hand. With `HONE_DEBUG_VERSION` set the stored key is neither
    /// read nor written (`persists` is false) and `HONE_DEBUG_LAST_SEEN` stands in
    /// for it (none: everything up to the debug version). `nil` when not debugging.
    static func debugOverride(environment: [String: String]) -> (lastSeen: String?, persists: Bool)? {
        guard environment["HONE_DEBUG_VERSION"] != nil else { return nil }
        return (environment["HONE_DEBUG_LAST_SEEN"], false)
    }
}
