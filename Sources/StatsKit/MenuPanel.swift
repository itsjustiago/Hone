import SwiftUI
import HoneDesign

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
/// Plain SwiftUI, canvas included, so the content can be rendered off-screen.
struct StatsPanel: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var state: PanelState
    @ObservedObject var processes: TopProcessesModel

    var onSettings: () -> Void
    /// Non-nil when hosted inside Hone's popover: the header shows a back chevron.
    var onBack: (() -> Void)?
    var onToggleOwnIcon: () -> Void

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
        // `preferredContentSize`) is the content's own, unchanged. The canvas
        // goes outside the layout so it fills whatever height the host has.
        TopAnchoredLayout { content }
            .vibePanelBackground()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: VibeSpacing.cardGap) {
            header

            if let selection {
                // One metric: its card already has the sparkline, a tile would repeat it.
                if visible.count > 1 { tiles }
                detailCard(for: selection)
            } else {
                emptyState
            }

            VibeMenuRow("Definições…", systemImage: "gearshape", action: onSettings)
                .vibeMenuCard()
        }
        .vibePanelLayout()
    }

    // MARK: Header

    private var header: some View {
        VibePanelHeader(title: "Stats",
                        subtitle: "\(monitor.chipName) · \(monitor.logicalCores) núcleos",
                        color: VibeToolColor.stats, mood: .awake, onBack: onBack) {
            VibeOwnIconButton(showsOwnIcon: state.showsOwnIcon, action: onToggleOwnIcon)
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        HStack(spacing: VibeSpacing.s) {
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
                .font(VibeFont.caption)
                .foregroundStyle(VibeColor.text3)
                .multilineTextAlignment(.center)
            Button("Abrir Definições", action: onSettings)
                .buttonStyle(VibeLinkButtonStyle(.strong))
        }
        .frame(maxWidth: .infinity)
        .vibeCard(padding: 16)
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .vibeCard(padding: 12)
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
                    .foregroundStyle(VibeColor.text1)
                Text(memory.map { "de \(Format.bytes($0.total))" } ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(VibeColor.text3)
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
                .font(VibeFont.caption)
                .foregroundStyle(VibeColor.text3)
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
                Text(fan?.name ?? "Ventoinha \(index + 1)")
                    .font(.system(size: 12))
                    .foregroundStyle(VibeColor.text2)
                Spacer(minLength: 8)
                Text(fan.map { "\(Format.rpm($0.rpm)) rpm" } ?? Format.noData)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(VibeColor.text1)
            }
            FractionBar(fraction: fan?.loadFraction ?? 0)
            Text(fan.map { "\(Format.rpm($0.minRPM))–\(Format.rpm($0.maxRPM)) rpm" } ?? " ")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(VibeColor.text3)
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

// MARK: - Preview fixtures

/// Entry point for Hone's offscreen preview renders: fake readings, nothing samples.
public enum StatsPreview {
    public enum Tab: Sendable { case cpu, memory, gpu, fan }

    @MainActor
    public static func panel(_ tab: Tab = .cpu, back: (() -> Void)? = nil) -> AnyView {
        let suite = "pt.hone.stats-preview"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let monitor = SystemMonitor(settings: StatsSettings(store: defaults))

        var snapshot = StatsSnapshot()
        snapshot.cpu = CPUUsage(total: 0.37, user: 0.24, system: 0.13, idle: 0.63,
                                perCore: [0.62, 0.55, 0.31, 0.12, 0.44, 0.21, 0.08, 0.33, 0.7, 0.18, 0.05, 0.27])
        snapshot.load = LoadAverage(one: 2.84, five: 2.51, fifteen: 2.12)
        snapshot.memory = MemorySampler.breakdown(
            counters: VMCounters(internalPages: 634_842, purgeable: 6_718, wired: 219_287,
                                 compressor: 414_007, external: 239_276, free: 5_646),
            pageSize: 16_384, total: 25_769_803_776)
        snapshot.swap = SwapUsage(total: 4 << 30, used: 1_300_000_000)
        snapshot.gpu = GPUReading(device: 0.18, renderer: 0.16, tiler: 0.07, inUseMemory: 1 << 30,
                                  name: "Apple GPU", cores: 20)
        snapshot.fans = [FanReading(name: "Ventoinha 1", rpm: 3417, minRPM: 2317, maxRPM: 7826)]
        monitor.snapshot = snapshot
        monitor.fanCount = 1
        monitor.unavailable = [:]
        for (index, metric) in Metric.allCases.enumerated() {
            var buffer = RingBuffer(capacity: SystemMonitor.historyLength)
            for i in 0..<SystemMonitor.historyLength {
                buffer.append(0.3 + 0.22 * sin(Double(i) / 4 + Double(index)) + 0.08 * sin(Double(i) * 1.7))
            }
            monitor.history[metric] = buffer
        }

        let state = PanelState()
        switch tab {
        case .cpu: state.selected = .cpu
        case .memory: state.selected = .memory
        case .gpu: state.selected = .gpu
        case .fan: state.selected = .fan
        }

        let processes = TopProcessesModel()
        let names = ["Safari", "Xcode", "WindowServer", "Slack", "Finder"]
        processes.rowsByMetric = [
            .cpu: names.enumerated().map {
                ProcessRow(id: Int32($0.offset), name: $0.element, cpu: 38 / Double($0.offset + 1),
                           memoryBytes: 0)
            },
            .memory: names.enumerated().map {
                ProcessRow(id: Int32($0.offset), name: $0.element, cpu: 0,
                           memoryBytes: UInt64(2_400_000_000 / ($0.offset + 1)))
            },
            .gpu: names.prefix(3).enumerated().map {
                ProcessRow(id: Int32($0.offset), name: $0.element, cpu: 0, memoryBytes: 0,
                           gpu: 21 / Double($0.offset + 1))
            },
        ]
        processes.fresh = [.cpu, .memory, .gpu]

        return AnyView(StatsPanel(monitor: monitor, state: state, processes: processes,
                                  onSettings: {}, onBack: back, onToggleOwnIcon: {}))
    }

    /// The tool's page in Settings, with throwaway values.
    @MainActor
    public static func settings() -> AnyView {
        let suite = "pt.hone.stats-preview"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let settings = StatsSettings(store: defaults)
        let monitor = SystemMonitor(settings: settings)
        monitor.unavailable = [:]
        return AnyView(StatsSettingsView(settings: settings, monitor: monitor))
    }
}
