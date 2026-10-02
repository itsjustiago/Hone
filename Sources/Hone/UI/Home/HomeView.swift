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

/// Hone's home: attention strips, a hero card for the selected tool and the
/// tool pills in two groups: the tweaks that are simply on or off, then the
/// dedicated apps. Pure values in, closures out (see `HomeModels`).
struct HomeView: View {
    let tools: [HomeTool]
    let notices: [HomeNotice]
    let selectedToolID: String
    var onSelect: (String) -> Void = { _ in }
    var actions = HomeActions()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: HomeTool? {
        tools.first { $0.id == selectedToolID } ?? tools.first
    }

    var body: some View {
        VStack(spacing: VibeSpacing.cardGap) {
            ForEach(notices) { notice in
                noticeStrip(notice)
            }
            if let selected {
                HeroCard(tool: selected, actions: actions)
            }
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 0) {
                    VibeSectionLabel(group.title)
                    pillsCard(group.tools)
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

    /// Two columns; a lone last pill takes the full row.
    private func pillsCard(_ tools: [HomeTool]) -> some View {
        let rows = stride(from: 0, to: tools.count, by: 2).map { Array(tools[$0..<min($0 + 2, tools.count)]) }
        return Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(rows, id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { tool in
                        ToolPill(tool: tool, isSelected: tool.id == selected?.id,
                                 onSelect: { select(tool.id) }, actions: actions)
                            .gridCellColumns(row.count == 1 ? 2 : 1)
                    }
                }
            }
        }
        .vibeCard(padding: 8)
    }

    private func select(_ id: String) {
        guard id != selected?.id else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : VibeMotion.arrive) { onSelect(id) }
    }
}

// MARK: - Hero

private struct HeroCard: View {
    let tool: HomeTool
    let actions: HomeActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let blobHeight: CGFloat = 50

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Blob(color: tool.tint, mood: tool.mood, height: blobHeight, glow: tool.isLive)
                    .id(tool.id)
                    .transition(blobTransition)
            }
            .frame(width: blobHeight * 1.3, height: blobHeight)
            .padding(.leading, 6)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : VibeMotion.arrive, value: tool.id)

            ZStack(alignment: .topLeading) {
                details
                    .id(tool.id)
                    .transition(.opacity)
            }
            .animation(.easeOut(duration: 0.15), value: tool.id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 72)
        .vibeCard(padding: VibeSpacing.cardPadding)
        .overlay(alignment: .topTrailing) {
            if tool.isAvailable && !tool.isMomentary {
                Toggle("Ligar \(tool.title)", isOn: Binding(
                    get: { tool.isEnabled },
                    set: { actions.setEnabled(tool.id, $0) }))
                    .toggleStyle(VibeToggleStyle(tint: tool.tint, isPaused: tool.isPaused))
                    .accessibilityLabel("Ligar \(tool.title)")
                    .padding(VibeSpacing.cardPadding)
            }
        }
        .animation(VibeMotion.standard, value: tool.isEnabled)
    }

    private var blobTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity),
                                              removal: .opacity)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleRow
            Text(tool.tagline)
                .font(VibeFont.body)
                .foregroundStyle(VibeColor.text3)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let alert = tool.alert, let text = tool.alertText {
                VibeStatusLine(text, color: alert.color)
            }
            actionRow
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 7) {
            VibeDot(tool.isEnabled || tool.isMomentary ? tool.tint : VibeColor.dotOff, size: 7)
            // The grey category only when it fits beside the title.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    title
                    Text(tool.category)
                        .font(VibeFont.subtitle)
                        .foregroundStyle(VibeColor.text3)
                }
                title
            }
            .lineLimit(1)
        }
        // Clear of the switch in the corner.
        .padding(.trailing, tool.isMomentary ? 0 : VibeMetrics.toggle.width + 8)
    }

    private var title: some View {
        Text(tool.title)
            .font(VibeFont.title)
            .foregroundStyle(VibeColor.text1)
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            if tool.isMomentary, tool.isAvailable {
                Button(tool.actionLabel) { actions.perform(tool.id) }
                    .buttonStyle(VibeLinkButtonStyle(.strong))
                settingsButton(.secondary)
            } else if tool.isPaused {
                Button("Fechar app antiga") { actions.quitLegacyApp(tool.id) }
                    .buttonStyle(VibeLinkButtonStyle(.strong))
                    .help("Enquanto o \(tool.title) antigo estiver aberto, o do Hone fica em pausa para não haver ícones e atalhos em duplicado.")
                settingsButton(.secondary)
            } else if tool.canOpenPanel {
                Button("Abrir \(tool.title)") { actions.openPanel(tool.id) }
                    .buttonStyle(VibeLinkButtonStyle(.strong))
                settingsButton(.secondary)
            } else {
                settingsButton(.strong)
            }
        }
    }

    private func settingsButton(_ emphasis: VibeLinkButtonStyle.Emphasis) -> some View {
        Button("Definições…") { actions.openSettings(tool.id) }
            .buttonStyle(VibeLinkButtonStyle(emphasis))
            .help("Definições de \(tool.title)")
    }
}

// MARK: - Pill

private struct ToolPill: View {
    let tool: HomeTool
    let isSelected: Bool
    let onSelect: () -> Void
    let actions: HomeActions

    @State private var hovering = false

    private let blobHeight: CGFloat = 19

    var body: some View {
        Button(action: onSelect) {
            Text(tool.shortTitle)
                .font(VibeFont.pill)
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                // Name centred in the space right of the mascot.
                .padding(.leading, 6 + blobHeight * 1.3 + 4)
                .padding(.trailing, 12)
                .frame(height: VibeMetrics.pillHeight)
                .overlay(alignment: .leading) {
                    Blob(color: tool.tint, mood: tool.mood, height: blobHeight)
                        .padding(.leading, 6)
                }
                .overlay(alignment: .trailing) {
                    if let alert = tool.alert {
                        VibeDot(alert.color, size: 5).padding(.trailing, 9)
                    }
                }
                .background(fill, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(border, lineWidth: 1))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(VibePressStyle())
        .onHover { hovering = $0 }
        .animation(VibeMotion.quick, value: hovering)
        .animation(VibeMotion.standard, value: isSelected)
        .contextMenu { menu }
        .help(tool.title)
        .accessibilityLabel("\(tool.title), \(tool.accessibilityState)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        let base = isSelected ? VibeColor.raised : VibeColor.inset
        return hovering ? base.vibeMix(over: .white, amount: 0.03) : base
    }

    private var border: Color {
        let lit = tool.isLive || tool.isPaused || (tool.alert != nil && tool.isEnabled)
        if isSelected {
            return lit ? tool.tint.vibeMix(over: VibeColor.card, amount: 0.42) : VibeColor.selectedBorder
        }
        if lit && !tool.isMomentary { return tool.tint.vibeMix(over: VibeColor.card, amount: 0.17) }
        return VibeColor.cardBorder
    }

    private var nameColor: Color {
        if isSelected { return VibeColor.text1 }
        if tool.isMomentary || (tool.isAvailable && tool.isEnabled) { return VibeColor.text2 }
        return VibeColor.text4
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
