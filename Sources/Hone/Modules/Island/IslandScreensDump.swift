import AppKit

/// Dev tool: where the island would go on the screens connected now, as text, no
/// windows. `HONE_ISLAND_SCREENS_DUMP=1` prints each screen's frame, menu bar and
/// notch (real or virtual) with the island's compact and open frames, then the plan
/// for each choice, then the plan as if the lid were closed (the built-in screen
/// gone), then what the islands would do on the way (`IslandScreens.changes`): the
/// lid closing, and the choice switched either way. From no island at all they would
/// just open the plan, already listed. Like the preview renderer it exits before anything else runs (see
/// `HoneMain`): no panels, no modules, no defaults written. Only numbers: no screen
/// names.
@MainActor
enum IslandScreensDump {
    static func run() -> Never {
        let screens = NSScreen.screens.compactMap { screen in
            IslandScreens.Info(screen: screen).map { ($0, screen.maximumFramesPerSecond) }
        }
        print(text(for: screens))
        exit(0)
    }

    /// The dump for `screens` (each with its refresh rate), without reading any display.
    static func text(for screens: [(info: IslandScreens.Info, hertz: Int)]) -> String {
        let infos = screens.map(\.info)
        var lines = ["\(infos.count) ecrãs"]
        for (info, hertz) in screens {
            let geometry = info.geometry
            lines.append("ecrã \(info.id) · \(info.isBuiltIn ? "interno" : "externo") · \(hertz) Hz")
            lines.append("  frame \(rect(info.frame)) · visível \(rect(info.visibleFrame))")
            lines.append("  barra de menus \(number(info.menuBarHeight)) pt · área segura no topo \(number(info.safeAreaTop)) pt")
            lines.append("  notch \(geometry.isVirtual ? "virtual" : "real") \(rect(geometry.notchRect))")
            lines.append("  ilha compacta \(rect(geometry.islandFrame(for: .compact)))")
            lines.append("  ilha aberta \(rect(geometry.islandFrame(for: .expanded)))")
        }
        for choice in IslandScreenChoice.allCases {
            lines.append(plan(IslandScreens.plan(infos, choice: choice), title: "plano «\(choice.display)»"))
        }
        let lidClosed = infos.filter { !$0.isBuiltIn }
        for choice in IslandScreenChoice.allCases {
            lines.append(plan(IslandScreens.plan(lidClosed, choice: choice),
                              title: "tampa fechada, plano «\(choice.display)»"))
        }
        let all = IslandScreens.plan(infos, choice: .all)
        let notch = IslandScreens.plan(infos, choice: .notch)
        lines.append(changes(IslandScreens.changes(from: all, to: IslandScreens.plan(lidClosed, choice: .all)),
                             title: "a tampa a fechar, «\(IslandScreenChoice.all.display)»"))
        lines.append(changes(IslandScreens.changes(from: all, to: notch),
                             title: "«\(IslandScreenChoice.all.display)» → «\(IslandScreenChoice.notch.display)»"))
        lines.append(changes(IslandScreens.changes(from: notch, to: all),
                             title: "«\(IslandScreenChoice.notch.display)» → «\(IslandScreenChoice.all.display)»"))
        return lines.joined(separator: "\n")
    }

    private static func changes(_ changes: IslandScreens.Changes, title: String) -> String {
        guard !changes.isEmpty else { return "\(title): nada muda" }
        var parts: [String] = []
        if !changes.added.isEmpty { parts.append("abre " + changes.added.map { "\($0.id)" }.joined(separator: ", ")) }
        if !changes.removed.isEmpty { parts.append("fecha " + changes.removed.map { "\($0)" }.joined(separator: ", ")) }
        if !changes.moved.isEmpty { parts.append("move " + changes.moved.map { "\($0.id)" }.joined(separator: ", ")) }
        return "\(title): " + parts.joined(separator: " · ")
    }

    private static func plan(_ plan: [IslandScreen], title: String) -> String {
        guard !plan.isEmpty else { return "\(title): nenhum ecrã" }
        let entries = plan.map { "\($0.id) (\($0.geometry.isVirtual ? "virtual" : "real"))" }
        return "\(title): \(entries.joined(separator: ", "))"
    }

    private static func rect(_ rect: CGRect) -> String {
        "\(number(rect.origin.x)),\(number(rect.origin.y)) \(number(rect.width))×\(number(rect.height))"
    }

    private static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", Double(value))
    }
}
