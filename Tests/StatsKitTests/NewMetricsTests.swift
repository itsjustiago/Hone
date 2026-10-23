import XCTest
import SwiftUI
import AppKit
@testable import StatsKit

// Temperature, power, network and disk in the history, the bar and the panel.

final class HistoryScaleTests: XCTestCase {
    func testTheOriginalMetricsAreAlreadyFractions() {
        for metric in [Metric.cpu, .memory, .gpu, .fan] {
            XCTAssertEqual(HistoryScale.fractions([0, 0.25, 1], for: metric), [0, 0.25, 1])
        }
    }

    func testTemperatureIsAFractionOfOneHundredDegrees() {
        XCTAssertEqual(HistoryScale.fractions([0, 45, 100], for: .temperature), [0, 0.45, 1])
    }

    func testPowerNeverScalesBelowTenWatts() {
        XCTAssertEqual(HistoryScale.fractions([2, 5], for: .power), [0.2, 0.5])
        XCTAssertEqual(HistoryScale.fractions([20, 40], for: .power), [0.5, 1])
        XCTAssertEqual(HistoryScale.fractions([20, 40], for: .power, peak: 80), [0.25, 0.5])
        XCTAssertEqual(HistoryScale.fractions([2, 5], for: .power, peak: 4), [0.2, 0.5], "a small peak doesn't lower the floor")
        XCTAssertEqual(HistoryScale.fractions([], for: .power), [])
    }

    func testNetworkNeverScalesBelowOneHundredKilobytes() {
        XCTAssertEqual(HistoryScale.fractions([51_200], for: .network), [0.5])
        XCTAssertEqual(HistoryScale.fractions([1_000_000, 500_000], for: .network), [1, 0.5])
        XCTAssertEqual(HistoryScale.fractions([1_000_000], for: .network, peak: 2_000_000), [0.5])
        XCTAssertEqual(HistoryScale.fractions([0, 0], for: .network), [0, 0])
        XCTAssertEqual(HistoryScale.fractions([50_000], for: .network, peak: 0), [50_000.0 / 102_400])
    }
}

final class NewMetricsPresentationTests: XCTestCase {
    func testTemperatureTone() {
        XCTAssertEqual(LoadTone.forTemperature(40), .normal)
        XCTAssertEqual(LoadTone.forTemperature(84.9), .normal)
        XCTAssertEqual(LoadTone.forTemperature(85), .warning)
        XCTAssertEqual(LoadTone.forTemperature(94.9), .warning)
        XCTAssertEqual(LoadTone.forTemperature(95), .critical)
    }

    func testPowerSourceFromTheProvidingType() {
        XCTAssertEqual(PowerSource(providingType: "Battery Power"), .battery)
        XCTAssertEqual(PowerSource(providingType: "AC Power"), .ac)
        XCTAssertEqual(PowerSource(providingType: "UPS Power"), .ups)
        XCTAssertNil(PowerSource(providingType: ""))
        XCTAssertNil(PowerSource(providingType: "Solar Power"))
        XCTAssertEqual([PowerSource.battery, .ac, .ups].map(\.title), ["Bateria", "Corrente", "UPS"])
        _ = PowerSource.current()  // whatever this Mac says, it must not crash
    }

    func testMetricsAreOrderedAndNamed() {
        XCTAssertEqual(Metric.allCases, [.cpu, .memory, .gpu, .fan, .temperature, .power, .network, .disk])
        XCTAssertEqual(Metric.allCases.filter(\.enabledByDefault), [.cpu, .memory, .gpu, .fan])
        XCTAssertEqual([Metric.temperature, .power, .network, .disk].map(\.shortLabel), ["TEMP", "PWR", "NET", "DISK"])
        XCTAssertEqual([Metric.temperature, .power, .network, .disk].map(\.title), ["Temperatura", "Energia", "Rede", "Disco"])
        XCTAssertEqual([Metric.temperature, .power, .network, .disk].map(\.spokenName), ["temperatura", "energia", "rede", "disco"])
        for metric in Metric.allCases {
            XCTAssertNotNil(metric.glyphSymbol, "\(metric) needs a symbol that exists on this macOS")
        }
    }

    func testAccessibilityTextOfTheNewReadouts() {
        let s = MenuBarSpec(items: [.init(metric: .temperature, text: "58°", tone: .normal),
                                    .init(metric: .power, text: "47 W", tone: .normal),
                                    .init(metric: .network, text: "12 KB/s", tone: .normal, secondary: "1,2 MB/s")],
                            showLabels: true, colorize: false)
        XCTAssertEqual(s.accessibilityText, "temperatura 58°, energia 47 W, rede, envio 12 KB/s, receção 1,2 MB/s")
        let none = MenuBarSpec(items: [.init(metric: .network, text: "–", tone: .normal, secondary: "–")],
                               showLabels: false, colorize: false)
        XCTAssertEqual(none.accessibilityText, "rede, envio –, receção –")
    }

    private func spec(_ metric: Metric, _ text: String, _ secondary: String? = nil, labels: Bool) -> MenuBarSpec {
        MenuBarSpec(items: [.init(metric: metric, text: text, tone: .normal, secondary: secondary)],
                    showLabels: labels, colorize: false)
    }

    func testNetworkWidthIgnoresLabelsAndValue() {
        let reference = MenuBarRenderer.widgetWidth(metric: .network, showLabels: true)
        XCTAssertEqual(MenuBarRenderer.widgetWidth(metric: .network, showLabels: false), reference)
        for (up, down) in [("0 KB/s", "0 KB/s"), ("12 KB/s", "1,2 MB/s"), ("999 KB/s", "999 MB/s"), ("–", "–")] {
            for labels in [true, false] {
                let size = MenuBarRenderer.imageSize(for: spec(.network, up, down, labels: labels), height: 22)
                XCTAssertEqual(size.width, reference)
                XCTAssertEqual(MenuBarRenderer.image(for: spec(.network, up, down, labels: labels), height: 22).size, size)
            }
        }
    }

    func testTemperatureAndPowerWidthIgnoresTheValue() {
        for labels in [true, false] {
            XCTAssertEqual(MenuBarRenderer.imageSize(for: spec(.temperature, "7°", labels: labels), height: 22),
                           MenuBarRenderer.imageSize(for: spec(.temperature, "100°", labels: labels), height: 22))
            XCTAssertEqual(MenuBarRenderer.imageSize(for: spec(.power, "4,2 W", labels: labels), height: 22),
                           MenuBarRenderer.imageSize(for: spec(.power, "999 W", labels: labels), height: 22))
        }
    }

    func testSegmentsStayLeftToRightWithTheNewReadouts() {
        for labels in [true, false] {
            let all = MenuBarSpec(items: Metric.allCases.map { .init(metric: $0, text: "0", tone: .normal, secondary: $0 == .network || $0 == .disk ? "0" : nil) },
                                  showLabels: labels, colorize: false)
            let segments = MenuBarRenderer.segments(for: all)
            XCTAssertEqual(segments.map(\.metric), Metric.allCases)
            for (previous, next) in zip(segments, segments.dropFirst()) {
                XCTAssertEqual(next.span.lowerBound, previous.span.upperBound + MenuBarRenderer.spacing)
            }
            // A click on each reading, the two-line ones included, lands on it.
            for segment in segments {
                let middle = (segment.span.lowerBound + segment.span.upperBound) / 2
                XCTAssertEqual(MenuBarRenderer.segment(atX: middle, in: all), segment)
            }
        }
    }

    /// Rows (from the top) of a 1x render that have any ink.
    private func inkRows(_ image: NSImage) throws -> [Int] {
        let width = Int(image.size.width.rounded(.up)), height = Int(image.size.height)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        return (0..<height).filter { y in
            (0..<width).contains { x in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 }
        }
    }

    func testNetworkDrawsTwoLinesWithInkOnBothHalves() throws {
        for labels in [true, false] {
            let image = MenuBarRenderer.image(for: spec(.network, "12 KB/s", "1,2 MB/s", labels: labels), height: 22)
            let rows = try inkRows(image)
            XCTAssertTrue(rows.contains { $0 < 11 }, "upload line in the top half")
            XCTAssertTrue(rows.contains { $0 >= 11 }, "download line in the bottom half")
            XCTAssertGreaterThanOrEqual(rows.first ?? 0, 2, "inside the bar, not cut at the top")
            XCTAssertLessThan(rows.last ?? 99, 21, "inside the bar, not cut at the bottom")
        }
    }
}

// MARK: - Panel

@MainActor
final class NewMetricsPanelTests: XCTestCase {
    func testTileColumns() {
        let columns = (1...8).map { StatsPanel.tileColumns(count: $0) }
        XCTAssertEqual(columns, [1, 2, 3, 4, 3, 3, 4, 4])
    }

    private func idealHeight(metrics: Set<Metric>, selected: Metric) -> CGFloat {
        let settings = StatsSettings(store: UserDefaults(suiteName: "tiles-\(UUID().uuidString)")!)
        settings.enabledMetrics = metrics
        let monitor = SystemMonitor(settings: settings)
        monitor.unavailable = [:]
        monitor.fanCount = 1
        let state = PanelState()
        state.selected = selected
        let panel = StatsPanel(monitor: monitor, state: state, processes: TopProcessesModel(),
                               onSettings: {}, onBack: nil, onToggleOwnIcon: {})
        return NSHostingView(rootView: AnyView(panel)).fittingSize.height
    }

    func testMoreThanFourTilesWrapIntoASecondRow() {
        let four = idealHeight(metrics: [.cpu, .memory, .gpu, .fan], selected: .fan)
        let five = idealHeight(metrics: [.cpu, .memory, .gpu, .fan, .temperature], selected: .fan)
        let eight = idealHeight(metrics: Set(Metric.allCases), selected: .fan)
        XCTAssertGreaterThan(five, four + 30, "a second row of tiles")
        XCTAssertEqual(eight, five, "five to eight tiles are two rows either way")
    }

    func testEveryDetailHasContent() {
        for metric in [Metric.temperature, .power, .network, .disk] {
            let height = idealHeight(metrics: [metric], selected: metric)
            XCTAssertGreaterThan(height, 150, "\(metric) detail is laid out")
        }
    }

    func testPreviewsCoverTheNewTabs() {
        for tab in [StatsPreview.Tab.temperature, .power, .network, .disk] {
            let host = NSHostingView(rootView: StatsPreview.panel(tab))
            XCTAssertGreaterThan(host.fittingSize.height, 150)
        }
    }
}

// MARK: - StatsTool

@MainActor
final class NewMetricsToolTests: XCTestCase {
    private func makeStore(extra: [String: Bool] = [:]) -> UserDefaults {
        let suite = "stats-new-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        addTeardownBlock { store.removePersistentDomain(forName: suite) }
        for metric in [Metric.cpu, .memory, .gpu, .fan] { store.set(false, forKey: metric.defaultsKey) }
        for metric in [Metric.temperature, .power, .network] { store.set(true, forKey: metric.defaultsKey) }
        for (key, value) in extra { store.set(value, forKey: key) }
        return store
    }

    private func snapshot(temperature: Double?) -> StatsSnapshot {
        var snapshot = StatsSnapshot()
        snapshot.temperature = temperature.map { TemperatureReading(cpu: $0, gpu: nil, battery: nil) }
        snapshot.power = 47.3
        snapshot.network = NetworkRates(download: 1.2 * 1_048_576, upload: 12 * 1024)
        return snapshot
    }

    func testTheBarShowsTheNewReadouts() {
        let tool = StatsTool(defaults: makeStore())
        tool.monitor.snapshot = snapshot(temperature: 58.4)
        tool.monitor.onSample?()
        XCTAssertEqual(tool.menuBarImage.accessibilityDescription,
                       "temperatura 58°, energia 47 W, rede, envio 12 KB/s, receção 1,2 MB/s")
    }

    func testNoDataIsAnEnDashNeverZero() {
        let tool = StatsTool(defaults: makeStore())
        tool.monitor.snapshot = StatsSnapshot()
        tool.monitor.onSample?()
        XCTAssertEqual(tool.menuBarImage.accessibilityDescription, "temperatura –, energia –, rede, envio –, receção –")
    }

    func testOnlyTemperatureTurnsTheBarIntoAnAlert() {
        let tool = StatsTool(defaults: makeStore(extra: [StatsSettings.colorByLoadKey: true]))
        tool.monitor.snapshot = snapshot(temperature: 70)
        tool.monitor.onSample?()
        XCTAssertTrue(tool.menuBarImage.isTemplate)
        tool.monitor.snapshot = snapshot(temperature: 90)
        tool.monitor.onSample?()
        XCTAssertFalse(tool.menuBarImage.isTemplate)

        let plain = StatsTool(defaults: makeStore())
        plain.monitor.snapshot = snapshot(temperature: 99)
        plain.monitor.onSample?()
        XCTAssertTrue(plain.menuBarImage.isTemplate, "no colour unless 'colour by load' is on")
    }

    func testProcessListsStayOnTheirThreeMetrics() async {
        let model = TopProcessesModel()
        for metric in [Metric.fan, .temperature, .power, .network, .disk] {
            await model.watch(metric: metric)  // returns at once: nothing to list
            XCTAssertTrue(model.rowsByMetric.isEmpty)
        }
    }

    // MARK: Os três de uma vez (ecrã «Novidades» do Hone)

    func testExtraReadoutsSwitchTurnsTheThreeOnTogetherAndOffAgain() {
        let store = makeStore()
        for metric in [Metric.temperature, .power, .network] { store.set(false, forKey: metric.defaultsKey) }
        store.set(true, forKey: Metric.cpu.defaultsKey)
        let tool = StatsTool(defaults: store)
        XCTAssertFalse(tool.showsExtraReadouts)

        tool.setShowsExtraReadouts(true)
        XCTAssertTrue(tool.showsExtraReadouts)
        for metric in [Metric.temperature, .power, .network] {
            XCTAssertEqual(store.object(forKey: metric.defaultsKey) as? Bool, true, "\(metric)")
        }

        tool.setShowsExtraReadouts(false)
        XCTAssertFalse(tool.showsExtraReadouts)
        for metric in [Metric.temperature, .power, .network] {
            XCTAssertEqual(store.object(forKey: metric.defaultsKey) as? Bool, false, "\(metric)")
        }
        XCTAssertEqual(store.object(forKey: Metric.cpu.defaultsKey) as? Bool, true, "as outras ficam como estavam")
    }

    func testExtraReadoutsSwitchIsOffUnlessAllThreeAreOn() {
        let store = makeStore()  // as três ligadas
        let tool = StatsTool(defaults: store)
        XCTAssertTrue(tool.showsExtraReadouts)
        store.set(false, forKey: Metric.power.defaultsKey)
        let partial = StatsTool(defaults: store)
        XCTAssertFalse(partial.showsExtraReadouts)
        partial.setShowsExtraReadouts(true)
        XCTAssertTrue(partial.showsExtraReadouts)
    }
}
