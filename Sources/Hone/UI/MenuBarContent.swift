import SwiftUI
import AppKit

/// Which embedded tool's panel the Hone popover shows in place of the tool
/// list. Owned by `AppDelegate` so closing the popover can reset it.
@MainActor
@Observable
final class PopoverNavigation {
    var toolID: String?
}

/// The panel shown from the menu-bar icon. Hosted in an `NSPopover` (arrow +
/// smooth grow animation), matching Clippy & Sleepy.
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

    // A single content inset used everywhere so every row, the header, the
    // dividers and the footer share the same left/right margin. Hover highlights
    // sit `highlightInset` from the edge and pad back to the same content line.
    private let panelWidth: CGFloat = 300
    private let edge: CGFloat = 8
    private var contentInset: CGFloat { 14 } // edge (8) + inner pad (6)

    private var needsPermission: Bool {
        manager.modules.contains { manager.isWaitingOnPermission($0) }
    }

    // Switch tools first, momentary (one-shot) tools grouped below a divider.
    private var switchModules: [any HoneModule] { manager.modules.filter { !$0.isMomentary } }
    private var momentaryModules: [any HoneModule] { manager.modules.filter { $0.isMomentary } }

    var body: some View {
        if let id = navigation.toolID, let tool = manager.menuBarTools.first(where: { $0.id == id }) {
            // Drilled into a tool: its own panel, with a back chevron to the list.
            // The popover follows the new preferred size on its own.
            tool.makeMenuPanel(
                back: { navigation.toolID = nil },
                dismiss: { dismissToolPanels(tool.id) },
                openSettings: { openSettings(tool.id) },
                toggleOwnIcon: { manager.setShowsOwnMenuBarIcon(!tool.showsOwnMenuBarIcon, for: tool) })
        } else {
            toolList
        }
    }

    private var toolList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, contentInset)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if updateChecker.availableUpdate != nil {
                updateBanner
                    .padding(.horizontal, edge)
                    .padding(.bottom, 8)
            }

            if needsPermission {
                permissionBanner
                    .padding(.horizontal, edge)
                    .padding(.bottom, 8)
            }

            moduleList(switchModules)

            if !momentaryModules.isEmpty {
                Divider()
                    .padding(.horizontal, contentInset)
                    .padding(.vertical, 6)
                moduleList(momentaryModules)
            }

            Divider()
                .padding(.horizontal, contentInset)
                .padding(.vertical, 8)

            VStack(spacing: 1) {
                Button {
                    dismiss()
                    openSettings(nil)
                } label: {
                    MenuActionLabel(title: "Definições…", shortcut: "", systemImage: "gearshape")
                }
                .buttonStyle(MenuButtonStyle(innerPad: contentInset - edge))

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    MenuActionLabel(title: "Sair do Hone", shortcut: "", systemImage: "power")
                }
                .buttonStyle(MenuButtonStyle(innerPad: contentInset - edge))
            }
            .padding(.horizontal, edge)
            .padding(.bottom, 8)
        }
        .frame(width: panelWidth)
        .background(VisualEffectBackground())
    }

    private func moduleList(_ modules: [any HoneModule]) -> some View {
        VStack(spacing: 2) {
            ForEach(modules, id: \.id) { module in
                ModuleRow(module: module, manager: manager,
                          innerPad: contentInset - edge, dismiss: dismiss, openSettings: openSettings,
                          openPanel: { tool in
                              tool.panelWillShow()
                              navigation.toolID = tool.id
                          })
            }
        }
        .padding(.horizontal, edge)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 27, height: 27)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text("Hone")
                    .font(.system(size: 15, weight: .bold))
                Text(activeSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var activeSummary: String {
        let active = manager.modules.filter { $0.isAvailable && $0.isEnabled && !$0.isMomentary }.count
        switch active {
        case 0: return "Nenhuma ferramenta ativa"
        case 1: return "1 ferramenta ativa"
        default: return "\(active) ferramentas ativas"
        }
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Falta acesso de Acessibilidade")
                    .font(.subheadline.weight(.medium))
                Text("O Hone precisa dele para controlar o scroll.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Conceder acesso…") { permissions.requestAccessibility() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var updateBanner: some View {
        Button {
            dismiss()
            updateChecker.install()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Atualização disponível")
                        .font(.subheadline.weight(.medium))
                    if let v = updateChecker.availableUpdate?.version {
                        Text("Versão \(v) — clica para instalar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One toggleable tool line inside the menu.
private struct ModuleRow: View {
    let module: any HoneModule
    @Bindable var manager: ModuleManager
    let innerPad: CGFloat
    var dismiss: () -> Void = {}
    var openSettings: (String?) -> Void = { _ in }
    /// Shows an embedded tool's panel inside the popover.
    var openPanel: (any MenuBarTool) -> Void = { _ in }
    @State private var hovering = false
    @State private var hoveringGear = false
    @State private var hoveringChevron = false

    private var tool: (any MenuBarTool)? { module as? any MenuBarTool }
    private var isPaused: Bool { manager.isPaused(module) }

    var body: some View {
        HStack(spacing: 11) {
            ModuleIcon(systemName: module.iconSystemName, tint: module.tint, size: 27)
                .saturation(module.isAvailable ? 1 : 0)
                .opacity(module.isAvailable ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(module.title).font(.system(size: 13, weight: .medium))
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let tool, isPaused {
                    Button("Fechar \(tool.title)") { manager.quitLegacyApp(for: tool) }
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            }
            Spacer(minLength: 8)
            if module.isAvailable {
                settingsButton
            }
            trailingControl
            if let tool {
                panelButton(tool)
            }
        }
        .padding(.horizontal, innerPad)
        .padding(.vertical, 7)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isActive ? AnyShapeStyle(module.tint.opacity(0.25)) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.16), value: module.isEnabled)
    }

    /// Quick path to this tool's Settings page. Quiet at rest, brighter with the
    /// row, and only shows its own pill when the pointer is on the gear itself.
    private var settingsButton: some View {
        Button {
            dismiss()
            openSettings(module.id)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: 22, height: 22)
                .background(hoveringGear ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.clear),
                            in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringGear = $0 }
        .help("Definições de \(module.title)")
    }

    /// Drill-in to the tool's own panel. Only while it's actually running —
    /// an off or paused tool has nothing live to show.
    private func panelButton(_ tool: any MenuBarTool) -> some View {
        let canOpen = tool.isEnabled && !isPaused
        return Button {
            openPanel(tool)
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering && canOpen ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: 18, height: 22)
                .background(hoveringChevron && canOpen ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .onHover { hoveringChevron = $0 }
        .help("Abrir \(tool.title)")
        .padding(.trailing, -4)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if !module.isAvailable {
            EmptyView()
        } else if module.isMomentary {
            // Momentary tools run once — a button, not a persistent switch.
            Button(module.actionLabel) {
                dismiss()
                module.performAction()
            }
            .buttonStyle(.borderedProminent)
            .tint(module.tint)
            .controlSize(.small)
        } else {
            Toggle("", isOn: Binding(
                get: { module.isEnabled },
                set: { manager.setEnabled($0, for: module) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(module.tint)
            .controlSize(.small)
        }
    }

    /// A tool that is switched on "lights up" with its tint — the highlight ported
    /// from Sleepy's hero card so active tools read at a glance.
    private var isActive: Bool { module.isAvailable && module.isEnabled && !module.isMomentary && !isPaused }

    private var rowBackground: AnyShapeStyle {
        if isActive { return AnyShapeStyle(module.tint.opacity(hovering ? 0.16 : 0.10)) }
        if hovering { return AnyShapeStyle(.primary.opacity(0.06)) }
        return AnyShapeStyle(.clear)
    }

    private var statusText: String {
        if !module.isAvailable { return "Em breve" }
        if module.isMomentary { return "Bloqueia as teclas para limpar" }
        if isPaused { return "Em pausa — o \(module.title) antigo está aberto" }
        return module.isEnabled ? "Ativo" : "Desligado"
    }
    private var statusColor: AnyShapeStyle {
        if isPaused { return AnyShapeStyle(.orange) }
        if module.isAvailable && module.isEnabled && !module.isMomentary { return AnyShapeStyle(module.tint) }
        return AnyShapeStyle(.secondary)
    }
}

private struct MenuActionLabel: View {
    let title: String
    let shortcut: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 27)
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 13))
            Spacer()
            Text(shortcut)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// Row-highlight button style matching native menu hover behaviour.
private struct MenuButtonStyle: ButtonStyle {
    let innerPad: CGFloat
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, innerPad)
            .padding(.vertical, 7)
            .background(hovering ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// The system menu material (translucent vibrancy) — keeps Hone's original
/// `MenuBarExtra(.window)` look now that the panel lives in an `NSPopover`.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
