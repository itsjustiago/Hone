import SwiftUI

/// What the user is looking at in the panel. Memory only, by design.
final class PanelState: ObservableObject {
    @Published var selected: Metric = .cpu
    /// Mirrors `StatsTool.showsOwnMenuBarIcon` so the detach/attach button
    /// swaps its glyph live.
    @Published var showsOwnIcon = true

    /// The tab actually shown: the chosen one if it's still on, else the first.
    func selection(among visible: [Metric]) -> Metric? {
        visible.contains(selected) ? selected : visible.first
    }
}

/// The Stats panel, shown from its own menu-bar icon or inside Hone's popover.
/// The vibrancy background is applied by `StatsTool.makeMenuPanel`, outside
/// this view, so the content can be rendered off-screen.
struct StatsPanel: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var state: PanelState
    @ObservedObject var processes: TopProcessesModel

    var onSettings: () -> Void
    /// Non-nil when hosted inside Hone's popover: the header shows a back chevron.
    var onBack: (() -> Void)?
    var onToggleOwnIcon: () -> Void

    private let panelWidth: CGFloat = 300
    private let edge: CGFloat = 8
    private let contentInset: CGFloat = 14

    private var visible: [Metric] { monitor.activeMetrics }

    private var selection: Metric? { state.selection(among: visible) }

    /// CPU, Memory and GPU have a process/app list: they share a minimum height so
    /// switching between them doesn't make the popover jump.
    static let sharedMinHeight: CGFloat = 303

    private var historyHelp: String { "Últimos \(SystemMonitor.historyLength * monitor.intervalSeconds) s" }

    var body: some View {
        // Pinned to the top: while the popover animates between tab heights the
        // hosting view is taller or shorter than this content, and SwiftUI would
        // centre it, making everything slide. The ideal size (what feeds
        // `preferredContentSize`) is the content's own, unchanged.
        TopAnchoredLayout { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, contentInset)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if let selection {
                // One metric: its card already has the sparkline, a tile would repeat it.
                if visible.count > 1 {
                    tiles
                        .padding(.horizontal, edge)
                        .padding(.bottom, 8)
                }
                detailCard(for: selection)
                    .padding(.horizontal, edge)
            } else {
                emptyState.padding(.horizontal, edge)
            }

            Divider()
                .padding(.horizontal, contentInset)
                .padding(.vertical, 8)

            MenuButton(action: onSettings) {
                MenuActionLabel(title: "Definições…", shortcut: "", systemImage: "gearshape")
            }
            .padding(.horizontal, edge)
            .padding(.bottom, 8)
        }
        .frame(width: panelWidth)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            if let onBack {
                HeaderIconButton(systemName: "chevron.left", help: "Voltar ao Hone", action: onBack)
                    .padding(.leading, -6)
                    .padding(.trailing, -4)
            }
            AppIcon(systemName: "cpu", size: 27)
            VStack(alignment: .leading, spacing: 0) {
                Text("Stats").font(.system(size: 15, weight: .bold))
                Text("\(monitor.chipName) · \(monitor.logicalCores) núcleos")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            HeaderIconButton(
                systemName: state.showsOwnIcon ? "menubar.arrow.down.rectangle" : "menubar.arrow.up.rectangle",
                help: state.showsOwnIcon
                    ? "Tirar o ícone próprio (continua no menu do Hone)"
                    : "Separar num ícone próprio na barra de menus",
                action: onToggleOwnIcon)
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        HStack(spacing: 6) {
            ForEach(visible) { metric in
                MetricTile(title: metric.title,
                           value: text(for: metric),
                           unit: metric.unit,
                           help: metric == .fan ? "Ventoinha mais rápida" : nil,
                           values: monitor.values(for: metric),
                           historyHelp: historyHelp,
                           selected: selection == metric) {
                    state.selected = metric
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Métricas")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Nenhuma métrica ligada. Liga o CPU, a memória, a GPU ou as ventoinhas para as veres na barra de menus.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Abrir Definições", action: onSettings)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.07)))
    }

    /// Value shown in a tile.
    private func text(for metric: Metric) -> String {
        let s = monitor.snapshot
        switch metric {
        case .cpu: return s.cpu.map { Format.percent($0.total) } ?? Format.noData
        case .memory: return s.memory.map { Format.percent($0.usedFraction) } ?? Format.noData
        case .gpu: return s.gpu.map { Format.percent($0.device) } ?? Format.noData
        case .fan: return FanMath.fastest(s.fans).map { Format.rpm($0.rpm) } ?? Format.noData
        }
    }

    // MARK: Detail

    /// Only the selected tab's detail exists, so each tab has its natural
    /// height; the fade is entry-only and quick.
    private func detailCard(for metric: Metric) -> some View {
        detail(for: metric)
            .id(metric)
            .transition(.asymmetric(insertion: .opacity, removal: .identity))
            .animation(.easeOut(duration: 0.1), value: metric)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.07)))
    }

    @ViewBuilder
    private func detail(for metric: Metric) -> some View {
        switch metric {
        case .cpu: cpuDetail
        case .memory: memoryDetail
        case .gpu: gpuDetail
        case .fan: fanDetail
        }
    }

    private func processList(for metric: Metric) -> some View {
        ProcessList(metric: metric, rows: processes.rowsByMetric[metric] ?? [],
                    isFresh: processes.fresh.contains(metric))
    }

    private func sparkline(_ metric: Metric) -> some View {
        Sparkline(values: monitor.values(for: metric), help: historyHelp).frame(height: 56)
    }

    private var cpuDetail: some View {
        let cpu = monitor.snapshot.cpu
        func pct(_ value: Double?) -> String { value.map(Format.percent) ?? Format.noData }
        return VStack(alignment: .leading, spacing: 8) {
            sparkline(.cpu)
            HStack {
                StatColumn(title: "Utilizador", value: pct(cpu?.user))
                StatColumn(title: "Sistema", value: pct(cpu?.system))
                StatColumn(title: "Inativo", value: pct(cpu?.idle))
            }
            VStack(spacing: 0) {
                InfoRow(title: "Carga (1 · 5 · 15 min)",
                        value: monitor.snapshot.load.map { Format.load(($0.one, $0.five, $0.fifteen)) } ?? Format.noData)
                InfoRow(title: "Núcleos", value: monitor.coreSummary)
            }
            CoreBars(values: cpu?.perCore ?? [])
            processList(for: .cpu)
        }
        .frame(minHeight: Self.sharedMinHeight, alignment: .top)
    }

    private var memoryDetail: some View {
        let memory = monitor.snapshot.memory
        func bytes(_ value: UInt64?) -> String { value.map(Format.bytes) ?? Format.noData }
        return VStack(alignment: .leading, spacing: 8) {
            sparkline(.memory)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(bytes(memory?.used))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text(memory.map { "de \(Format.bytes($0.total))" } ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                PressurePill(pressure: monitor.snapshot.pressure)
            }
            VStack(spacing: 0) {
                InfoRow(title: "Memória de apps", value: bytes(memory?.app))
                InfoRow(title: "Memória fixa", value: bytes(memory?.wired))
                InfoRow(title: "Comprimida", value: bytes(memory?.compressed))
                InfoRow(title: "Em cache", value: bytes(memory?.cached))
                InfoRow(title: "Livre", value: bytes(memory?.free))
                InfoRow(title: "Swap usado", value: bytes(monitor.snapshot.swap?.used))
            }
            processList(for: .memory)
        }
        .frame(minHeight: Self.sharedMinHeight, alignment: .top)
    }

    private var gpuDetail: some View {
        let gpu = monitor.snapshot.gpu
        func pct(_ value: Double?) -> String { value.map(Format.percent) ?? Format.noData }
        return VStack(alignment: .leading, spacing: 8) {
            sparkline(.gpu)
            VStack(spacing: 0) {
                InfoRow(title: "Total", value: pct(gpu?.device))
                InfoRow(title: "Renderizador", value: pct(gpu?.renderer))
                InfoRow(title: "Tiler", value: pct(gpu?.tiler))
                InfoRow(title: "Memória em uso", value: gpu?.inUseMemory.map(Format.bytes) ?? Format.noData)
            }
            Text(gpuDescription(gpu))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            processList(for: .gpu)
        }
        .frame(minHeight: Self.sharedMinHeight, alignment: .top)
    }

    private func gpuDescription(_ gpu: GPUReading?) -> String {
        guard let gpu else { return "" }
        return [gpu.name, gpu.cores.map { "\($0) núcleos" }].compactMap { $0 }.joined(separator: " · ")
    }

    private var fanDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            sparkline(.fan)
            // One block per fan the Mac really has, so the height is fixed.
            ForEach(0..<monitor.fanCount, id: \.self) { index in
                fanRow(index < monitor.snapshot.fans.count ? monitor.snapshot.fans[index] : nil, index: index)
            }
        }
    }

    private func fanRow(_ fan: FanReading?, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(fan?.name ?? "Ventoinha \(index + 1)").font(.system(size: 12))
                Spacer(minLength: 8)
                Text(fan.map { "\(Format.rpm($0.rpm)) rpm" } ?? Format.noData)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            FractionBar(fraction: fan?.loadFraction ?? 0)
            Text(fan.map { "\(Format.rpm($0.minRPM))–\(Format.rpm($0.maxRPM)) rpm" } ?? " ")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Takes whatever height the host offers (taller or shorter than the content)
/// and keeps its single child at the top, at its own ideal height: extra space
/// stays empty below, and a shorter frame clips the bottom, never the top.
struct TopAnchoredLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: proposal.height ?? ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
