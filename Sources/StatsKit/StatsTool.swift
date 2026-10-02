import AppKit
import SwiftUI
import Combine

/// Stats (CPU, memory, GPU and fans live in the menu bar) packaged as a tool a
/// host app (Hone) can embed. Owns no status item or window: the host decides
/// where the icon, the panel and the settings are shown.
@MainActor
public final class StatsTool {
    private let defaults: UserDefaults
    private let settings: StatsSettings
    let monitor: SystemMonitor
    private let panelState = PanelState()
    private let processes = TopProcessesModel()
    private var cancellable: AnyCancellable?

    private var currentSpec: MenuBarSpec
    private var currentImage: NSImage

    public private(set) var isRunning = false

    /// Called whenever what the menu bar image draws changes (rounded values,
    /// labels, colours) — not on every sample.
    public var onMenuBarImageChange: (() -> Void)?

    public convenience init() {
        self.init(defaults: .standard)
    }

    /// `defaults` is injectable so tests never touch the real preferences.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        settings = StatsSettings(store: defaults)
        monitor = SystemMonitor(settings: settings)
        currentSpec = MenuBarSpec(items: [], showLabels: true, colorize: false)
        currentImage = MenuBarRenderer.image(for: currentSpec)
        panelState.showsOwnIcon = showsOwnMenuBarIcon
        monitor.showsOwnIcon = showsOwnMenuBarIcon
        monitor.onSample = { [weak self] in self?.refreshImage() }
        // Subscribed after the monitor's own sink, so it already has fresh samples.
        cancellable = settings.didChange.sink { [weak self] in
            MainActor.assumeIsolated { self?.refreshImage() }
        }
        refreshImage(notify: false)
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        monitor.start()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        monitor.stop()
        processes.reset()
    }

    // MARK: - Menu bar

    public var menuBarImage: NSImage { currentImage }

    /// Whether the user wants Stats under its own menu-bar icon (absent = shown).
    public var showsOwnMenuBarIcon: Bool {
        get { defaults.object(forKey: StatsSettings.showMenuBarIconKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: StatsSettings.showMenuBarIconKey)
            panelState.showsOwnIcon = newValue
            monitor.showsOwnIcon = newValue
        }
    }

    private func makeSpec() -> MenuBarSpec {
        let s = monitor.snapshot
        // The bar's "no data" is an en dash, narrower than the panel's em dash.
        let noData = "–"
        let colorize = settings.colorByLoad
        func tone(_ value: LoadTone) -> LoadTone { colorize ? value : .normal }
        let items: [MenuBarSpec.Item] = monitor.activeMetrics.map { metric in
            switch metric {
            case .cpu:
                let f = s.cpu?.total
                return .init(metric: metric, text: f.map(Format.percent) ?? noData, tone: tone(.forLoad(f ?? 0)))
            case .memory:
                return .init(metric: metric, text: s.memory.map { Format.percent($0.usedFraction) } ?? noData,
                             tone: tone(.forPressure(s.pressure)))
            case .gpu:
                let f = s.gpu?.device
                return .init(metric: metric, text: f.map(Format.percent) ?? noData, tone: tone(.forLoad(f ?? 0)))
            case .fan:
                let fastest = FanMath.fastest(s.fans)
                return .init(metric: metric, text: fastest.map { Format.rpm($0.rpm) } ?? noData,
                             tone: tone(.forLoad(fastest?.loadFraction ?? 0)))
            }
        }
        return MenuBarSpec(items: items, showLabels: settings.showLabels, colorize: colorize)
    }

    /// Redraws only when something visible changed: every notification makes
    /// the host recompose all tools' icons.
    private func refreshImage(notify: Bool = true) {
        let spec = makeSpec()
        guard spec != currentSpec else { return }
        currentSpec = spec
        currentImage = MenuBarRenderer.image(for: spec)
        if notify { onMenuBarImageChange?() }
    }

    // MARK: - Panel

    /// Fresh numbers before the panel shows, and a new session for the process list.
    public func panelWillShow() {
        panelState.showsOwnIcon = showsOwnMenuBarIcon
        processes.panelOpened()
        monitor.sample(.extra)
    }

    public func makeMenuPanel(back: (() -> Void)?,
                              dismiss: @escaping () -> Void,
                              openSettings: @escaping () -> Void,
                              toggleOwnIcon: @escaping () -> Void) -> AnyView {
        AnyView(PanelHost(
            monitor: monitor, state: panelState, processes: processes,
            onSettings: { dismiss(); openSettings() },
            onBack: back,
            onToggleOwnIcon: toggleOwnIcon))
    }

    // MARK: - Settings

    public func makeSettingsView() -> AnyView {
        AnyView(StatsSettingsView(settings: settings, monitor: monitor))
    }
}

/// The panel plus what must not be part of it when rendered off-screen: the
/// live process loop and the active control state.
private struct PanelHost: View {
    let monitor: SystemMonitor
    let state: PanelState
    let processes: TopProcessesModel
    let onSettings: () -> Void
    let onBack: (() -> Void)?
    let onToggleOwnIcon: () -> Void

    @ObservedObject private var processModel: TopProcessesModel
    @ObservedObject private var panelState: PanelState
    @ObservedObject private var observedMonitor: SystemMonitor

    init(monitor: SystemMonitor, state: PanelState, processes: TopProcessesModel,
         onSettings: @escaping () -> Void, onBack: (() -> Void)?, onToggleOwnIcon: @escaping () -> Void) {
        self.monitor = monitor
        self.state = state
        self.processes = processes
        self.onSettings = onSettings
        self.onBack = onBack
        self.onToggleOwnIcon = onToggleOwnIcon
        _processModel = ObservedObject(wrappedValue: processes)
        _panelState = ObservedObject(wrappedValue: state)
        _observedMonitor = ObservedObject(wrappedValue: monitor)
    }

    private struct TaskKey: Equatable {
        var metric: Metric?
        var generation: Int
    }

    /// The tab on screen (falls back when the chosen metric was switched off).
    private var shown: Metric? { panelState.selection(among: observedMonitor.activeMetrics) }

    var body: some View {
        StatsPanel(monitor: monitor, state: state, processes: processes,
                   onSettings: onSettings, onBack: onBack, onToggleOwnIcon: onToggleOwnIcon)
            // Keep controls fully coloured even when the popover window isn't key.
            .environment(\.controlActiveState, .active)
            .onAppear { monitor.panelAppeared() }
            .onDisappear { monitor.panelDisappeared() }
            // SwiftUI cancels this when the panel goes away, which is what stops `top`.
            .task(id: TaskKey(metric: shown, generation: processModel.generation)) {
                if let shown { await processModel.watch(metric: shown) }
            }
    }
}
