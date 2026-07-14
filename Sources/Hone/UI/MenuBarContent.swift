import SwiftUI
import AppKit

/// The panel shown from the menu-bar icon. Hosted in an `NSPopover` (arrow +
/// smooth grow animation), matching Clippy & Sleepy.
struct MenuBarContent: View {
    @Bindable var manager: ModuleManager
    var updateChecker: UpdateChecker
    var dismiss: () -> Void = {}
    var openSettings: () -> Void = {}
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

    var body: some View {
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

            VStack(spacing: 2) {
                ForEach(manager.modules, id: \.id) { module in
                    ModuleRow(module: module, manager: manager, innerPad: contentInset - edge)
                }
            }
            .padding(.horizontal, edge)

            Divider()
                .padding(.horizontal, contentInset)
                .padding(.vertical, 8)

            VStack(spacing: 1) {
                Button {
                    dismiss()
                    openSettings()
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
        let active = manager.modules.filter { $0.isAvailable && $0.isEnabled }.count
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
    @State private var hovering = false

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
            }
            Spacer(minLength: 8)
            if module.isAvailable {
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

    /// A tool that is switched on "lights up" with its tint — the highlight ported
    /// from Sleepy's hero card so active tools read at a glance.
    private var isActive: Bool { module.isAvailable && module.isEnabled }

    private var rowBackground: AnyShapeStyle {
        if isActive { return AnyShapeStyle(module.tint.opacity(hovering ? 0.16 : 0.10)) }
        if hovering { return AnyShapeStyle(.primary.opacity(0.06)) }
        return AnyShapeStyle(.clear)
    }

    private var statusText: String {
        if !module.isAvailable { return "Em breve" }
        return module.isEnabled ? "Ativo" : "Desligado"
    }
    private var statusColor: AnyShapeStyle {
        if module.isAvailable && module.isEnabled { return AnyShapeStyle(module.tint) }
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
