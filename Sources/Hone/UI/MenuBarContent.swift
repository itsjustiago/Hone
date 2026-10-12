import SwiftUI
import AppKit
import HoneDesign

/// Which embedded tool's panel the Hone popover shows in place of the home.
/// Owned by `AppDelegate` so closing the popover can reset it.
@MainActor
@Observable
final class PopoverNavigation {
    var toolID: String?
}

/// The panel shown from the menu-bar icon, hosted in an `NSPopover`. Bridges
/// the live `ModuleManager` to the value-driven `PopoverShell` + `HomeView`.
struct MenuBarContent: View {
    @Bindable var manager: ModuleManager
    var updateChecker: UpdateChecker
    @Bindable var navigation: PopoverNavigation
    var dismiss: () -> Void = {}
    /// Closes every popover showing the given tool's panel (see `AppDelegate`).
    var dismissToolPanels: (String) -> Void = { _ in }
    /// Opens Settings on the given tool's page; `nil` keeps the current page.
    var openSettings: (String?) -> Void = { _ in }
    @State private var permissions = Permissions.shared

    /// Embedded tools whose panel can be shown right now (on, not paused).
    private var openableTools: [any MenuBarTool] {
        manager.menuBarTools.filter { $0.isEnabled && !manager.isPaused($0) }
    }

    /// The tool whose panel is on screen; falls back to the home when it was
    /// switched off or paused meanwhile.
    private var shownTool: (any MenuBarTool)? {
        guard let id = navigation.toolID else { return nil }
        return openableTools.first { $0.id == id }
    }

    var body: some View {
        let shown = shownTool
        PopoverShell(
            tabs: [.home] + openableTools.map { HomeTab(id: $0.id, systemImage: $0.iconSystemName, title: $0.title) },
            selectedTab: shown?.id,
            onSelectTab: { id in
                if let id { openPanel(id) } else { navigation.toolID = nil }
            },
            openSettings: {
                dismiss()
                openSettings(nil)
            },
            quit: { NSApplication.shared.terminate(nil) }
        ) {
            if let tool = shown {
                tool.makeMenuPanel(
                    back: nil,
                    dismiss: { dismissToolPanels(tool.id) },
                    openSettings: { openSettings(tool.id) },
                    toggleOwnIcon: { manager.setShowsOwnMenuBarIcon(!tool.showsOwnMenuBarIcon, for: tool) })
                    .background(backShortcut)
            } else {
                HomeView(tools: homeTools, notices: notices, actions: actions)
            }
        }
    }

    /// ⌘[ goes back to the home, like "Back" elsewhere on the Mac.
    private var backShortcut: some View {
        Button("Voltar ao Hone") { navigation.toolID = nil }
            .keyboardShortcut("[", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func openPanel(_ id: String) {
        guard let tool = openableTools.first(where: { $0.id == id }) else { return }
        tool.panelWillShow()
        navigation.toolID = tool.id
    }

    // MARK: - Manager → values

    /// Manager order, momentary tools last.
    private var homeTools: [HomeTool] {
        let ordered = manager.modules.filter { !$0.isMomentary } + manager.modules.filter(\.isMomentary)
        return ordered.map { module in
            let tool = module as? any MenuBarTool
            return HomeTool(
                id: module.id, title: module.title, shortTitle: module.shortTitle,
                category: module.category, tagline: module.tagline,
                iconSystemName: module.iconSystemName, tint: module.tint,
                isAvailable: module.isAvailable, isMomentary: module.isMomentary,
                actionLabel: module.actionLabel, isEnabled: module.isEnabled,
                hasPanel: tool != nil, alert: alert(for: module, tool: tool),
                isIdle: manager.isIdle(module))
        }
    }

    private func alert(for module: any HoneModule, tool: (any MenuBarTool)?) -> HomeTool.Alert? {
        guard module.isAvailable, module.isEnabled, !module.isMomentary else { return nil }
        if manager.isPaused(module) { return .paused }
        if let permission = tool?.permission, permission.essential, !permission.isGranted {
            return .missingPermission(permission.kind.title)
        }
        if manager.isWaitingOnPermission(module) { return .missingPermission(ToolPermission.Kind.accessibility.title) }
        return nil
    }

    private var notices: [HomeNotice] {
        var list: [HomeNotice] = []
        if let version = updateChecker.availableUpdate?.version { list.append(.update(version: version)) }
        if manager.modules.contains(where: { manager.isWaitingOnPermission($0) }) { list.append(.accessibility) }
        return list
    }

    private var actions: HomeActions {
        HomeActions(
            setEnabled: { id, on in
                guard let module = module(id) else { return }
                manager.setEnabled(on, for: module)
            },
            openPanel: { openPanel($0) },
            openSettings: { id in
                dismiss()
                openSettings(id)
            },
            perform: { id in
                dismiss()
                module(id)?.performAction()
            },
            quitLegacyApp: { id in
                if let tool = manager.menuBarTools.first(where: { $0.id == id }) { manager.quitLegacyApp(for: tool) }
            },
            installUpdate: {
                dismiss()
                updateChecker.install()
            },
            requestAccessibility: { permissions.requestAccessibility() },
            quit: { NSApplication.shared.terminate(nil) })
    }

    private func module(_ id: String) -> (any HoneModule)? {
        manager.modules.first { $0.id == id }
    }
}
