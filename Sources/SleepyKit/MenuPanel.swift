import SwiftUI
import AppKit

/// Live state the menu-bar panel reflects. Populated by `SleepyTool` right
/// before the panel shows so the toggle, auto-off and permissions stay fresh.
final class SleepMenuModel: ObservableObject {
    @Published var isActive = false
    @Published var autoOffText: String?
    @Published var autoOffMinutes = SleepController.autoOffMinutes
    @Published var passwordlessInstalled = PrivilegedAccess.isInstalled
    /// Mirrors `SleepyTool.showsOwnMenuBarIcon` so the detach/attach button
    /// swaps its glyph live.
    @Published var showsOwnIcon = true
}

/// The Sleepy panel, shown either from its own menu-bar icon or inside Hone's
/// popover. App-level rows (quit, updates, version) belong to Hone now.
struct MenuPanel: View {
    @ObservedObject var model: SleepMenuModel

    var onToggleSleep: () -> Void
    var onEnablePasswordless: () -> Void
    var onChangeAutoOff: (Int) -> Void
    var onSettings: () -> Void
    /// Non-nil when hosted inside Hone's popover: the header shows a back chevron.
    var onBack: (() -> Void)?
    var onToggleOwnIcon: () -> Void

    private let panelWidth: CGFloat = 300
    private let edge: CGFloat = 8
    private var contentInset: CGFloat { 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, contentInset)
                .padding(.top, 12)
                .padding(.bottom, 10)

            heroCard
                .padding(.horizontal, edge)

            if !model.passwordlessInstalled {
                permissionBanner
                    .padding(.horizontal, edge)
                    .padding(.top, 8)
            }

            Divider()
                .padding(.horizontal, contentInset)
                .padding(.vertical, 8)

            VStack(spacing: 1) {
                autoOffRow
                MenuButton(action: onSettings) {
                    MenuActionLabel(title: "Definições…", shortcut: "",
                                    systemImage: "gearshape")
                }
            }
            .padding(.horizontal, edge)
            .padding(.bottom, 8)
        }
        .frame(width: panelWidth)
        .background(VisualEffectBackground())
        // Keep controls (switch tint) fully coloured even when the popover
        // window isn't key — otherwise the .switch style desaturates to grey.
        .environment(\.controlActiveState, .active)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 11) {
            if let onBack {
                HeaderIconButton(systemName: "chevron.left", help: "Voltar ao Hone", action: onBack)
                    .padding(.leading, -6)
                    .padding(.trailing, -4)
            }
            AppIcon(systemName: model.isActive ? "sun.max.fill" : "moon.zzz.fill", size: 27)
            VStack(alignment: .leading, spacing: 0) {
                Text("Sleepy").font(.system(size: 15, weight: .bold))
                Text(model.isActive ? "Sleep impedido" : "Sleep normal")
                    .font(.caption2)
                    .foregroundStyle(model.isActive ? AnyShapeStyle(Brand.tint) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
            HeaderIconButton(
                systemName: model.showsOwnIcon ? "menubar.arrow.down.rectangle" : "menubar.arrow.up.rectangle",
                help: model.showsOwnIcon ? "Juntar ao Hone" : "Separar para a barra de menus",
                action: onToggleOwnIcon)
        }
    }

    // MARK: - Hero toggle

    private var heroCard: some View {
        HStack(spacing: 12) {
            AppIcon(systemName: "bolt.fill", size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Impedir sleep")
                    .font(.system(size: 14, weight: .semibold))
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(model.isActive ? AnyShapeStyle(Brand.tint) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { model.isActive }, set: { _ in onToggleSleep() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Brand.tint)
                .controlSize(.large)
        }
        .padding(12)
        .background(
            model.isActive ? AnyShapeStyle(Brand.tint.opacity(0.10)) : AnyShapeStyle(.primary.opacity(0.04)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(model.isActive ? Brand.tint.opacity(0.28) : .primary.opacity(0.07))
        )
        .animation(.easeInOut(duration: 0.18), value: model.isActive)
    }

    private var statusLine: String {
        if !model.isActive { return "O Mac dorme normalmente." }
        if let t = model.autoOffText { return t }
        return "O Mac fica acordado, mesmo de tampa fechada."
    }

    // MARK: - Auto-off row

    /// A duração é a definição que se mexe com frequência, por isso vive aqui e
    /// não dentro das Definições — o "Iniciar no login" ficou lá, é de uma vez só.
    private var autoOffRow: some View {
        HStack(spacing: 11) {
            Image(systemName: "timer")
                .font(.system(size: 14))
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text("Desligar sozinho").font(.system(size: 13))
            Spacer(minLength: 8)
            Picker("", selection: Binding(get: { model.autoOffMinutes },
                                          set: { onChangeAutoOff($0) })) {
                ForEach(SleepController.autoOffOptions) { Text($0.short).tag($0.minutes) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    // MARK: - Banners

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ligar sem password")
                    .font(.subheadline.weight(.medium))
                Text("Instala uma regra restrita para não pedir password a cada toggle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Ativar…", action: onEnablePasswordless)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - Menu action label + button style

/// Small circular glyph button for the panel header (back, detach/attach).
/// Quiet at rest; a soft pill appears only under the pointer.
struct HeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .background(hovering ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.clear),
                            in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct MenuActionLabel: View {
    let title: String
    let shortcut: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            if !shortcut.isEmpty {
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Row button with native-menu hover highlight, matching Facet.
struct MenuButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering && isEnabled ? AnyShapeStyle(Brand.tint.opacity(0.16)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The system menu material (translucent vibrancy), matching Facet's
/// `MenuBarExtra(.window)` background so all three menus share one look.
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
