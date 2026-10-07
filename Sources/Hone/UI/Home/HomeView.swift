import SwiftUI
import HoneDesign

/// The popover's frame: a top bar of icon tabs (Home + one per open Kit) with
/// Settings and Quit on the right, over whatever the selected tab shows.
struct PopoverShell<Content: View>: View {
    let tabs: [HomeTab]
    let selectedTab: String?
    var onSelectTab: (String?) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
        .background(VibeColor.canvas.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    private var topBar: some View {
        HStack(spacing: 1) {
            ForEach(tabs) { tab in
                Button { onSelectTab(tab.id) } label: {
                    Image(systemName: tab.systemImage)
                }
                .buttonStyle(VibeBarButtonStyle(isSelected: tab.id == selectedTab))
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(tab.id == selectedTab ? .isSelected : [])
            }
            Spacer(minLength: 12)
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(VibeBarButtonStyle())
                .help("Definições do Hone")
                .accessibilityLabel("Definições do Hone")
            Button(action: quit) { Image(systemName: "power") }
                .buttonStyle(VibeBarButtonStyle())
                .help("Sair do Hone")
                .accessibilityLabel("Sair do Hone")
        }
        .padding(.horizontal, VibeSpacing.outer)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

/// Hone's home: attention strips, Hone's own card, then its tweaks (a symbol,
/// a switch and a cog each) and the dedicated apps (each with its own mascot).
/// Pure values in, closures out (see `HomeModels`).
struct HomeView: View {
    let tools: [HomeTool]
    let notices: [HomeNotice]
    var actions = HomeActions()

    var body: some View {
        VStack(spacing: VibeSpacing.cardGap) {
            ForEach(notices) { notice in
                noticeStrip(notice)
            }
            HoneCard(tweaks: tools.filter { !$0.isApp && $0.isAvailable }, actions: actions)
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 0) {
                    VibeSectionLabel(group.title)
                    VStack(spacing: 4) {
                        ForEach(group.tools) { tool in
                            ToolRow(tool: tool, actions: actions)
                        }
                    }
                    .vibeCard(padding: 8)
                }
            }
        }
        .padding(.horizontal, VibeSpacing.outer)
        .padding(.bottom, VibeSpacing.outer)
        .frame(width: VibeMetrics.panelWidth)
    }

    @ViewBuilder
    private func noticeStrip(_ notice: HomeNotice) -> some View {
        switch notice {
        case .update(let version):
            VibeNoticeStrip("Atualização \(version) disponível", color: VibeColor.success,
                            actionTitle: "Instalar", action: actions.installUpdate)
        case .accessibility:
            VibeNoticeStrip("Falta Acessibilidade", color: VibeColor.danger,
                            actionTitle: "Conceder acesso…", action: actions.requestAccessibility)
        }
    }

    /// Tweaks first, then apps; each keeps the manager's order. A group with
    /// nothing in it is left out.
    private var groups: [(title: String, tools: [HomeTool])] {
        [("Ajustes", tools.filter { !$0.isApp }), ("Apps", tools.filter(\.isApp))]
            .filter { !$0.tools.isEmpty }
    }
}

// MARK: - Hone

/// Hone itself: one mascot for the app and all its tweaks, so no switch here
/// (each tweak has its own below).
private struct HoneCard: View {
    let tweaks: [HomeTool]
    let actions: HomeActions

    private let blobHeight: CGFloat = 50

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Blob(color: VibeToolColor.hone, mood: .awake, height: blobHeight, glow: true)
                .frame(width: blobHeight * 1.3, height: blobHeight)
                .padding(.leading, 6)

            VStack(alignment: .leading, spacing: 6) {
                // The count only when it fits beside the name.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        title
                        Text(summary)
                            .font(VibeFont.caption)
                            .foregroundStyle(VibeColor.text3)
                    }
                    title
                }
                .lineLimit(1)
                Text("Os ajustes que faltam ao macOS.")
                    .font(VibeFont.body)
                    .foregroundStyle(VibeColor.text3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Definições…") { actions.openSettings(nil) }
                    .buttonStyle(VibeLinkButtonStyle(.strong))
                    .help("Definições do Hone")
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 72)
        .vibeCard(padding: VibeSpacing.cardPadding)
    }

    private var title: some View {
        Text("Hone")
            .font(VibeFont.title)
            .foregroundStyle(VibeColor.text1)
    }

    private var summary: String {
        "\(tweaks.filter(\.isEnabled).count) de \(tweaks.count) ajustes ligados"
    }
}

// MARK: - Row

/// One tweak or app: a symbol (tweaks) or its own mascot (apps), the name,
/// then the switch and a cog for its settings. Only an app's row is itself
/// clickable (it opens the app's panel); a tweak's controls are the switch
/// and the cog.
private struct ToolRow: View {
    let tool: HomeTool
    let actions: HomeActions

    @State private var hovering = false

    private let blobHeight: CGFloat = 19
    private let leadingWidth: CGFloat = 26

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: leadingWidth)
            VStack(alignment: .leading, spacing: 2) {
                nameRow
                if tool.alert != nil { statusLine }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(minHeight: VibeMetrics.rowHeight)
        .background(fill, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(border, lineWidth: 1))
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { if tool.canOpenPanel { actions.openPanel(tool.id) } }
        .animation(VibeMotion.quick, value: hovering)
        .animation(VibeMotion.standard, value: tool.isEnabled)
        .contextMenu { menu }
        .help(tool.canOpenPanel ? "Abrir \(tool.title)" : tool.tagline)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tool.title), \(tool.accessibilityState)")
    }

    // MARK: Leading

    @ViewBuilder
    private var leading: some View {
        if tool.isApp {
            Blob(color: tool.tint, mood: tool.mood, height: blobHeight)
        } else {
            Image(systemName: tool.iconSystemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tool.isEnabled ? tool.tint : VibeColor.text4)
                .frame(width: 24, height: 24)
                .background(tool.isEnabled ? tool.tint.vibeMix(over: VibeColor.inset, amount: 0.16)
                                           : VibeColor.card,
                            in: Circle())
                .accessibilityHidden(true)
        }
    }

    // MARK: Name & status

    private var nameRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                name
                Text(tool.category)
                    .font(VibeFont.caption)
                    .foregroundStyle(VibeColor.text4)
            }
            name
        }
        .lineLimit(1)
    }

    private var name: some View {
        Text(tool.title)
            .font(VibeFont.action)
            .foregroundStyle(tool.isMomentary || (tool.isAvailable && tool.isEnabled) ? VibeColor.text1 : VibeColor.text3)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let alert = tool.alert {
            HStack(spacing: 5) {
                VibeDot(alert.color, size: 5)
                Text(tool.isPaused ? "Em pausa" : tool.alertText ?? "")
                    .font(VibeFont.caption)
                    .foregroundStyle(VibeColor.text3)
                    .lineLimit(1)
                    .fixedSize()
                if tool.isPaused {
                    RowLink(title: "Fechar app antiga") { actions.quitLegacyApp(tool.id) }
                        .help("Enquanto o \(tool.title) antigo estiver aberto, o do Hone fica em pausa para não haver ícones e atalhos em duplicado.")
                }
            }
        }
    }

    // MARK: Trailing

    private var trailing: some View {
        HStack(spacing: 6) {
            if !tool.isAvailable {
                Text("Em breve")
                    .font(VibeFont.caption)
                    .foregroundStyle(VibeColor.text4)
            } else {
                if tool.isMomentary {
                    Button(tool.actionLabel) { actions.perform(tool.id) }
                        .buttonStyle(VibeLinkButtonStyle(.strong))
                        .padding(.trailing, 4)
                } else {
                    Toggle("Ligar \(tool.title)", isOn: Binding(
                        get: { tool.isEnabled },
                        set: { actions.setEnabled(tool.id, $0) }))
                        .toggleStyle(VibeToggleStyle(tint: tool.tint, isPaused: tool.isPaused))
                        .accessibilityLabel("Ligar \(tool.title)")
                }
                CogButton(help: "Definições de \(tool.title)") { actions.openSettings(tool.id) }
            }
        }
    }

    // MARK: Look

    private var fill: Color {
        let base = VibeColor.inset
        return hovering && tool.canOpenPanel ? base.vibeMix(over: .white, amount: 0.97) : base
    }

    private var border: Color {
        let lit = tool.isLive || tool.isPaused || (tool.alert != nil && tool.isEnabled)
        return lit && !tool.isMomentary ? tool.tint.vibeMix(over: VibeColor.card, amount: 0.17) : VibeColor.cardBorder
    }

    @ViewBuilder
    private var menu: some View {
        if tool.isMomentary, tool.isAvailable {
            Button(tool.actionLabel) { actions.perform(tool.id) }
        } else if tool.isAvailable {
            Button(tool.isEnabled ? "Desligar" : "Ligar") { actions.setEnabled(tool.id, !tool.isEnabled) }
        }
        if tool.canOpenPanel {
            Button("Abrir \(tool.title)") { actions.openPanel(tool.id) }
        }
        if tool.isPaused {
            Button("Fechar app antiga") { actions.quitLegacyApp(tool.id) }
        }
        Divider()
        Button("Definições de \(tool.title)…") { actions.openSettings(tool.id) }
    }
}

/// The settings cog at the end of a row.
private struct CogButton: View {
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? VibeColor.text1 : VibeColor.text3)
                .frame(width: 26, height: 26)
                .background(hovering ? VibeColor.control : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(VibePressStyle(scale: 0.92))
        .onHover { hovering = $0 }
        .animation(VibeMotion.quick, value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A small text link for a row's status line.
private struct RowLink: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? VibeColor.text1 : VibeColor.text2)
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(VibeMotion.quick, value: hovering)
    }
}
