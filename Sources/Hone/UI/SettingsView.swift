import SwiftUI
import HoneDesign

/// Sizes the Settings window and its pages agree on.
enum SettingsLayout {
    static let size = CGSize(width: 680, height: 540)
    static let sidebarWidth: CGFloat = 216
    /// The window has no visible title bar; content starts below its buttons.
    static let titlebar: CGFloat = 40
}

private struct SettingsPageScrollsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether a page scrolls. Only the preview renders turn it off: they can't
    /// draw a `ScrollView`, so they lay the whole page out instead.
    var settingsPageScrolls: Bool {
        get { self[SettingsPageScrollsKey.self] }
        set { self[SettingsPageScrollsKey.self] = newValue }
    }
}

/// One row of the Settings sidebar. Plain values, so the shell can be rendered
/// offscreen from fake data (see `PreviewRenderer+Settings`).
struct SettingsEntry: Identifiable {
    enum Leading {
        case blob(Color, Blob.Mood)
        case symbol(String)
        /// A Hone tweak: its symbol, in its colour (only apps wear a mascot).
        case tweak(String, Color)
    }

    let id: String
    let title: String
    let leading: Leading
    /// Off tools read dimmer, like their pills on the home.
    var isActive = true
    /// A dedicated app (own mascot) rather than one of Hone's tweaks.
    var isApp = false

    static let general = SettingsEntry(id: "general", title: "Geral", leading: .symbol("gearshape.fill"))
}

// MARK: - Shell

/// The window's frame: a sidebar of pages and the selected page on the right.
struct SettingsShell<Detail: View>: View {
    let tools: [SettingsEntry]
    @Binding var selection: String
    /// The window's height; only the preview renders ask for another.
    var height = SettingsLayout.size.height
    @ViewBuilder var detail: Detail

    /// The sidebar holds the keyboard focus so ↑ and ↓ work from the first click.
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: SettingsLayout.sidebarWidth)
            Rectangle()
                .fill(VibeColor.cardBorder)
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: SettingsLayout.size.width, height: height)
        // The window's content runs under its transparent title bar.
        .ignoresSafeArea()
        .vibePanelBackground()
        .buttonStyle(VibeButtonStyle())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 2) {
                group("Ajustes", tools.filter { !$0.isApp })
                group("Apps", tools.filter(\.isApp), gap: 8)
                row(.general).padding(.top, 10)
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($sidebarFocused)
        .onMoveCommand(perform: move)
        .onAppear { sidebarFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Blob(color: VibePalette.white, mood: .awake, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("Hone")
                    .font(VibeFont.title)
                    .foregroundStyle(VibeColor.text1)
                Text("Ferramentas para o Mac")
                    .font(VibeFont.caption)
                    .foregroundStyle(VibeColor.text3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, SettingsLayout.titlebar)
        .padding(.bottom, 14)
    }

    /// A titled run of rows; left out when empty.
    @ViewBuilder
    private func group(_ title: String, _ entries: [SettingsEntry], gap: CGFloat = 0) -> some View {
        if !entries.isEmpty {
            VibeSectionLabel(title).padding(.top, gap)
            ForEach(entries) { row($0) }
        }
    }

    private func row(_ entry: SettingsEntry) -> some View {
        SidebarRow(entry: entry, isSelected: entry.id == selection) {
            selection = entry.id
            sidebarFocused = true
        }
    }

    /// ↑ and ↓ walk the sidebar, as in a list.
    private func move(_ direction: MoveCommandDirection) {
        let ids = (tools.filter { !$0.isApp } + tools.filter(\.isApp)).map(\.id) + [SettingsEntry.general.id]
        guard let index = ids.firstIndex(of: selection) else { return }
        switch direction {
        case .up: selection = ids[max(index - 1, 0)]
        case .down: selection = ids[min(index + 1, ids.count - 1)]
        default: break
        }
    }
}

private struct SidebarRow: View {
    let entry: SettingsEntry
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    private let blobHeight: CGFloat = 17

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                leading
                    .frame(width: blobHeight * 1.3, height: blobHeight + 2)
                Text(entry.title)
                    .font(VibeFont.pill)
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(fill, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(isSelected ? VibeColor.selectedBorder : .clear, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(VibePressStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(VibeMotion.quick, value: hovering)
        .animation(VibeMotion.standard, value: isSelected)
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var leading: some View {
        switch entry.leading {
        case .blob(let color, let mood):
            Blob(color: color, mood: mood, height: blobHeight)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? VibeColor.text1 : VibeColor.text3)
        case .tweak(let name, let tint):
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(entry.isActive ? tint : VibeColor.text4)
                .frame(width: 21, height: 21)
                .background(entry.isActive ? tint.opacity(0.16) : Color.white.opacity(0.05), in: Circle())
        }
    }

    private var fill: Color { isSelected ? VibeColor.raised : hovering ? VibeColor.card : .clear }

    private var nameColor: Color {
        if isSelected { return VibeColor.text1 }
        return entry.isActive ? VibeColor.text2 : VibeColor.text4
    }
}

/// A page on the right: the header card, then whatever the page holds.
struct SettingsPage<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    @Environment(\.settingsPageScrolls) private var scrolls

    var body: some View {
        if scrolls {
            ScrollView { page }
        } else {
            page.frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            content
        }
        .padding(.horizontal, 18)
        .padding(.top, SettingsLayout.titlebar)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Live window

struct SettingsView: View {
    @Bindable var manager: ModuleManager
    var updateChecker: UpdateChecker
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        SettingsShell(tools: manager.modules.map(entry(for:)), selection: $navigation.selection) {
            detail
        }
    }

    private func entry(for module: any HoneModule) -> SettingsEntry {
        let isApp = module is any MenuBarTool || module.isMomentary
        return SettingsEntry(id: module.id, title: module.title,
                             leading: isApp ? .blob(module.tint, manager.mood(for: module))
                                            : .tweak(module.iconSystemName, module.tint),
                             isActive: module.isAvailable && (module.isMomentary || module.isEnabled),
                             isApp: isApp)
    }

    @ViewBuilder
    private var detail: some View {
        if navigation.selection == SettingsEntry.general.id {
            GeneralSettingsView(updateChecker: updateChecker)
        } else if let module = manager.modules.first(where: { $0.id == navigation.selection }) {
            ModuleDetailView(module: module, manager: manager)
        } else {
            Text("Escolhe uma ferramenta")
                .font(VibeFont.subtitle)
                .foregroundStyle(VibeColor.text3)
        }
    }
}

private extension ModuleManager {
    /// The tool's mascot mood, as on the home: asleep when off, alert when
    /// something holds it back.
    func mood(for module: any HoneModule) -> Blob.Mood {
        if module.isMomentary { return .awake }
        guard module.isAvailable, module.isEnabled else { return .asleep }
        return isPaused(module) || isWaitingOnPermission(module) ? .alert : .awake
    }
}

// MARK: - Module detail

/// A card at the top of a tool's page that asks for something.
struct ToolPageBanner: Identifiable {
    let id: String
    let color: Color
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void
}

/// The tool's permission, as its row in "Permissões".
struct ToolPagePermission {
    let title: String
    let purpose: String
    let isGranted: Bool
    let request: () -> Void
}

extension VibeHeaderStatus {
    /// Switched off in Hone.
    static let off = VibeHeaderStatus("Desligado no Hone", color: VibeColor.dotOff)

    /// Switched on, and what it is doing: the tool's colour while it works, grey
    /// while idle. Non-breaking spaces keep "agora: …" together if the line wraps.
    static func on(_ live: ToolLiveState, tint: Color) -> VibeHeaderStatus {
        let now = "agora: \(live.text)".replacingOccurrences(of: " ", with: "\u{00A0}")
        return VibeHeaderStatus("Ativo no Hone · \(now)", color: live.isActive ? tint : VibeColor.dotOff)
    }
}

/// A tool's page: header card, what needs attention, the tool's own settings and
/// the shared sections. Plain values in, so the preview renderer can draw it
/// offscreen; `ModuleDetailView` feeds it from the live module.
struct ToolPage<Control: View>: View {
    let title: String
    let summary: String
    let tint: Color
    let mood: Blob.Mood
    /// A tweak's symbol, shown in place of the mascot (only apps have one).
    let symbol: String?
    /// What the tool is doing now, under the title (only some tools have one).
    let status: VibeHeaderStatus?
    let banners: [ToolPageBanner]
    /// Off tools keep their settings in view, but out of reach.
    let dimmed: Bool
    let settings: AnyView
    let permission: ToolPagePermission?
    /// The switch for the tool's own menu-bar icon; `nil` when it has none.
    let ownIcon: Binding<Bool>?
    let control: Control

    init(title: String, summary: String, tint: Color, mood: Blob.Mood, symbol: String? = nil,
         status: VibeHeaderStatus? = nil,
         banners: [ToolPageBanner] = [], dimmed: Bool = false, settings: AnyView,
         permission: ToolPagePermission? = nil, ownIcon: Binding<Bool>? = nil,
         @ViewBuilder control: () -> Control) {
        self.title = title
        self.summary = summary
        self.tint = tint
        self.mood = mood
        self.symbol = symbol
        self.status = status
        self.banners = banners
        self.dimmed = dimmed
        self.settings = settings
        self.permission = permission
        self.ownIcon = ownIcon
        self.control = control()
    }

    var body: some View {
        SettingsPage {
            VibePageHeader(title: title, subtitle: summary, color: tint, mood: mood, symbol: symbol,
                           status: status) { control }
        } content: {
            ForEach(banners) { banner in
                VibeBanner(color: banner.color, title: banner.title, detail: banner.detail,
                           actionTitle: banner.actionTitle, action: banner.action)
            }
            Group {
                settings
                if let permission {
                    SettingsSection(title: "Permissões") {
                        SettingsRow(title: permission.title, subtitle: permission.purpose) {
                            if permission.isGranted {
                                Label("Concedida", systemImage: "checkmark.circle.fill")
                                    .font(VibeFont.settingsRow)
                                    .foregroundStyle(VibeColor.success)
                            } else {
                                Button("Conceder…", action: permission.request)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                if let ownIcon {
                    SettingsSection(title: "Barra de menus") {
                        ToggleRow(title: "Ícone próprio na barra de menus",
                                  subtitle: "Mostra o \(title) num ícone separado. Continua também no menu do Hone.",
                                  tint: tint, isOn: ownIcon)
                    }
                }
            }
            .disabled(dimmed)
            .opacity(dimmed ? 0.45 : 1)
        }
    }
}

private struct ModuleDetailView: View {
    let module: any HoneModule
    @Bindable var manager: ModuleManager
    @State private var permissions = Permissions.shared

    var body: some View {
        ToolPage(title: module.title, summary: module.summary, tint: module.tint,
                 mood: manager.mood(for: module),
                 symbol: module is any MenuBarTool || module.isMomentary ? nil : module.iconSystemName,
                 status: status, banners: banners,
                 dimmed: module.isAvailable && !module.isMomentary && !module.isEnabled,
                 settings: module.makeSettingsView(), permission: permission, ownIcon: ownIcon) {
            control
        }
        // Screen Recording isn't polled; refresh so "Concedida" is current.
        .onAppear { permissions.refresh() }
    }

    /// "Ativo no Hone · agora: …" for a tool with a live state: the switch only
    /// says it is on, this says whether it is doing anything. Left out while a
    /// banner already says what holds it back.
    private var status: VibeHeaderStatus? {
        guard let tool = module as? any MenuBarTool, let live = tool.liveState else { return nil }
        guard tool.isEnabled else { return .off }
        guard !manager.isPaused(tool), !manager.isWaitingOnPermission(tool) else { return nil }
        return .on(live, tint: tool.tint)
    }

    private var banners: [ToolPageBanner] {
        var banners: [ToolPageBanner] = []
        if module.isAvailable, manager.isWaitingOnPermission(module) {
            banners.append(ToolPageBanner(
                id: "accessibility", color: VibeColor.danger,
                title: "Falta acesso de Acessibilidade",
                detail: "O Hone precisa dele para esta ferramenta funcionar.",
                actionTitle: "Abrir Definições…") { permissions.openAccessibilitySettings() })
        }
        if let tool = module as? any MenuBarTool, manager.isPaused(tool) {
            banners.append(ToolPageBanner(
                id: "paused", color: VibeColor.warning,
                title: "Em pausa — o \(tool.title) antigo está aberto",
                detail: "Não podem correr as duas ao mesmo tempo. Quando a antiga sair, o Hone assume.",
                actionTitle: "Sair da app \(tool.title)") { manager.quitLegacyApp(for: tool) })
        }
        return banners
    }

    private var permission: ToolPagePermission? {
        guard let tool = module as? any MenuBarTool, let permission = tool.permission else { return nil }
        return ToolPagePermission(title: permission.kind.title, purpose: permission.purpose,
                                  isGranted: permission.isGranted, request: permission.request)
    }

    private var ownIcon: Binding<Bool>? {
        guard let tool = module as? any MenuBarTool else { return nil }
        return Binding(get: { tool.showsOwnMenuBarIcon },
                       set: { manager.setShowsOwnMenuBarIcon($0, for: tool) })
    }

    @ViewBuilder
    private var control: some View {
        if module.isMomentary {
            Button(module.actionLabel, action: module.performAction)
                .buttonStyle(VibeButtonStyle(prominent: true, tint: module.tint))
                .controlSize(.large)
        } else {
            Toggle("Ligar \(module.title)", isOn: Binding(
                get: { module.isEnabled },
                set: { manager.setEnabled($0, for: module) }
            ))
            .labelsHidden()
            .toggleStyle(VibeToggleStyle(tint: module.tint, isPaused: manager.isPaused(module)))
            .accessibilityLabel("Ligar \(module.title)")
        }
    }
}

// MARK: - General

/// Hone's own colour: the white mascot, so its switches are white too.
private let honeTint = VibeToolColor.hone

struct GeneralSettingsView: View {
    var updateChecker: UpdateChecker
    @State private var launch = LaunchAtLogin.shared
    @State private var autoCheck = Updater.autoCheckEnabled
    @State private var showMenuBarIcon = MenuBarIcon.isVisible

    var body: some View {
        SettingsPage {
            VibePageHeader(title: "Geral", subtitle: "Preferências gerais do Hone.", color: honeTint)
        } content: {
            SettingsSection(title: "Barra de menus") {
                ToggleRow(title: "Mostrar na barra de menus",
                          subtitle: "Se desligares, abre o Hone pelo Launchpad para voltar aqui.",
                          tint: honeTint,
                          isOn: Binding(get: { showMenuBarIcon },
                                        set: { showMenuBarIcon = $0; MenuBarIcon.setVisible($0) }))
            }

            SettingsSection(title: "Arranque") {
                ToggleRow(title: "Abrir o Hone no arranque",
                          subtitle: "Inicia automaticamente quando entras na sessão.",
                          tint: honeTint,
                          isOn: Binding(get: { launch.isEnabled },
                                        set: { launch.isEnabled = $0 }))
            }

            SettingsSection(title: "Atualizações") {
                ToggleRow(title: "Procurar automaticamente",
                          tint: honeTint,
                          isOn: Binding(get: { autoCheck },
                                        set: { autoCheck = $0; Updater.autoCheckEnabled = $0 }))
                RowDivider()
                SettingsRow(title: "Versão \(Updater.currentVersion)",
                            subtitle: updateChecker.status.isEmpty ? nil : updateChecker.status) {
                    if let update = updateChecker.availableUpdate {
                        Button("Atualizar para \(update.version)") { updateChecker.install() }
                            .buttonStyle(VibeButtonStyle(prominent: true, tint: VibeColor.success))
                            .controlSize(.small)
                    } else {
                        Button("Procurar agora") { updateChecker.checkNow() }
                            .controlSize(.small)
                    }
                }
            }

            SettingsSection(title: "Sobre") {
                SettingsRow(title: "Hone",
                            subtitle: "Uma caixa de ferramentas modular para o macOS. Mais ferramentas a caminho.") {
                    EmptyView()
                }
                RowDivider()
                HStack {
                    Spacer()
                    Button("Sair do Hone", role: .destructive) {
                        NSApplication.shared.terminate(nil)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
            }
        }
    }
}
