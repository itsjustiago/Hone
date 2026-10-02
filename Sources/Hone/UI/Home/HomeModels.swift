import SwiftUI
import HoneDesign

// Plain values the home renders. `MenuBarContent` builds them from the live
// `ModuleManager`; the preview renderer builds them from fake data. Keeping
// the views off the manager is what makes offscreen renders possible.

/// One tool as the home sees it.
struct HomeTool: Identifiable {
    enum Alert {
        /// On, but held back while the old standalone app runs.
        case paused
        /// On, but missing a permission it can't work without.
        case missingPermission(String)

        var color: Color {
            switch self {
            case .paused: return VibeColor.warning
            case .missingPermission: return VibeColor.danger
            }
        }
    }

    let id: String
    let title: String
    let shortTitle: String
    let category: String
    let tagline: String
    let iconSystemName: String
    let tint: Color
    let isAvailable: Bool
    let isMomentary: Bool
    let actionLabel: String
    let isEnabled: Bool
    /// Has its own panel (an embedded Kit).
    let hasPanel: Bool
    let alert: Alert?

    /// A dedicated app (an embedded Kit, or a one-shot like Limpar Teclado)
    /// rather than a background tweak that is simply on or off.
    var isApp: Bool { hasPanel || isMomentary }

    var isPaused: Bool {
        if case .paused = alert { return true }
        return false
    }

    /// On and actually running — what lights the tool up.
    var isLive: Bool { isAvailable && !isMomentary && isEnabled && alert == nil }

    /// Its panel can be opened (a top-bar tab exists for it).
    var canOpenPanel: Bool { hasPanel && isEnabled && !isPaused }

    var mood: Blob.Mood {
        if isMomentary { return .awake }
        if !isAvailable || !isEnabled { return .asleep }
        return alert == nil ? .awake : .alert
    }

    var alertText: String? {
        switch alert {
        case .paused: return "Em pausa — app antiga aberta"
        case .missingPermission(let name): return "Falta \(name)"
        case nil: return nil
        }
    }

    var accessibilityState: String {
        if isMomentary { return actionLabel }
        if isPaused { return "em pausa" }
        return isEnabled ? "ligado" : "desligado"
    }
}

/// A top-bar tab: Home (`id == nil`) or an embedded tool's panel.
struct HomeTab: Identifiable {
    let id: String?
    let systemImage: String
    let title: String

    static let home = HomeTab(id: nil, systemImage: "house.fill", title: "Início")
}

/// A thin strip above the hero for app-wide things that need attention.
enum HomeNotice: Identifiable {
    case update(version: String)
    case accessibility

    var id: String {
        switch self {
        case .update: return "update"
        case .accessibility: return "accessibility"
        }
    }
}

/// Everything the home can ask for. The defaults do nothing (previews).
struct HomeActions {
    var setEnabled: (String, Bool) -> Void = { _, _ in }
    var openPanel: (String) -> Void = { _ in }
    /// `nil` opens the general page.
    var openSettings: (String?) -> Void = { _ in }
    var perform: (String) -> Void = { _ in }
    var quitLegacyApp: (String) -> Void = { _ in }
    var installUpdate: () -> Void = {}
    var requestAccessibility: () -> Void = {}
    var quit: () -> Void = {}
}
