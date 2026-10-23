import XCTest
import SwiftUI
import AppKit
@testable import StatsKit

// The disk metric: counters, free space, formatting, the bar and the panel.

// MARK: - Pure maths

final class DiskSamplerTests: XCTestCase {
    func testRatesSumTheDeltasPerSecond() {
        let before: [UInt64: DiskCounters] = [1: .init(read: 1_000, written: 500), 2: .init(read: 0, written: 0)]
        let after: [UInt64: DiskCounters] = [1: .init(read: 3_000, written: 1_500), 2: .init(read: 1_000, written: 100)]
        XCTAssertEqual(DiskSampler.rates(previous: before, current: after, seconds: 2),
                       DiskRates(read: 1_500, write: 550))
    }

    func testRatesIgnoreRegressionsNewAndGoneDisks() {
        let before: [UInt64: DiskCounters] = [4: .init(read: 5_000, written: 1_000),
                                              9: .init(read: 10, written: 10)]
        let after: [UInt64: DiskCounters] = [4: .init(read: 100, written: 3_000),       // read counter went back
                                             12: .init(read: 9_999, written: 9_999)]    // new, 9 is gone
        XCTAssertEqual(DiskSampler.rates(previous: before, current: after, seconds: 1),
                       DiskRates(read: 0, write: 2_000))
        XCTAssertEqual(DiskSampler.rates(previous: [:], current: after, seconds: 1),
                       DiskRates(read: 0, write: 0))
        XCTAssertEqual(DiskSampler.rates(previous: before, current: [:], seconds: 1),
                       DiskRates(read: 0, write: 0))
    }

    func testRatesNeedPositiveTime() {
        let counters: [UInt64: DiskCounters] = [4: .init(read: 1, written: 1)]
        XCTAssertNil(DiskSampler.rates(previous: counters, current: counters, seconds: 0))
        XCTAssertNil(DiskSampler.rates(previous: counters, current: counters, seconds: -1))
        XCTAssertNil(DiskSampler.rates(previous: counters, current: counters, seconds: .nan))
    }

    func testCountersComeFromTheStatisticsDictionary() {
        let big: UInt64 = 4_171_431_710_720   // beyond 32 bits
        XCTAssertEqual(DiskSampler.counters(statistics: ["Bytes (Read)": NSNumber(value: big),
                                                         "Bytes (Write)": NSNumber(value: 7), "Errors (Read)": 0]),
                       DiskCounters(read: big, written: 7))
        XCTAssertNil(DiskSampler.counters(statistics: nil))
        XCTAssertNil(DiskSampler.counters(statistics: [:]))
        XCTAssertNil(DiskSampler.counters(statistics: ["Bytes (Read)": 1]), "both counters or none")
        XCTAssertNil(DiskSampler.counters(statistics: ["Bytes (Read)": "1", "Bytes (Write)": "2"]))
    }

    func testDiskImagesAreLeftOut() {
        XCTAssertTrue(DiskSampler.isDiskImage(protocolCharacteristics: [
            "Physical Interconnect": "Virtual Interface", "Physical Interconnect Location": "File"]))
        XCTAssertTrue(DiskSampler.isDiskImage(protocolCharacteristics: ["Physical Interconnect Location": "File"]))
        XCTAssertTrue(DiskSampler.isDiskImage(protocolCharacteristics: ["Physical Interconnect": "Virtual Interface"]))
        XCTAssertFalse(DiskSampler.isDiskImage(protocolCharacteristics: [
            "Physical Interconnect": "PCI-Express", "Physical Interconnect Location": "Internal"]))
        XCTAssertFalse(DiskSampler.isDiskImage(protocolCharacteristics: [:]))
        XCTAssertFalse(DiskSampler.isDiskImage(protocolCharacteristics: nil), "no provider info: counted")
    }

    func testSpaceNeedsAvailableAndTotal() {
        XCTAssertEqual(DiskSampler.space(available: 368, total: 995, name: "Macintosh HD"),
                       DiskSpace(available: 368, total: 995, name: "Macintosh HD"))
        XCTAssertNil(DiskSampler.space(available: nil, total: 995, name: "x"))
        XCTAssertNil(DiskSampler.space(available: 368, total: nil, name: "x"))
        XCTAssertNil(DiskSampler.space(available: 368, total: 0, name: "x"))
        XCTAssertNil(DiskSampler.space(available: 368, total: -5, name: "x"))
        XCTAssertEqual(DiskSampler.space(available: -3, total: 10, name: nil)?.available, 0)
    }

    func testUsedFractionIsClamped() {
        XCTAssertEqual(DiskSpace(available: 250, total: 1_000, name: nil).usedFraction, 0.75)
        XCTAssertEqual(DiskSpace(available: 0, total: 1_000, name: nil).usedFraction, 1)
        XCTAssertEqual(DiskSpace(available: 2_000, total: 1_000, name: nil).usedFraction, 0)
        XCTAssertEqual(DiskSpace(available: 5, total: 0, name: nil).usedFraction, 0)
    }
}

// MARK: - Formatting and scale

final class DiskFormatTests: XCTestCase {
    func testDiskSpaceIsBaseOneThousandLikeTheFinder() {
        XCTAssertEqual(Format.diskSpace(0), "0 MB")
        XCTAssertEqual(Format.diskSpace(850_000_000), "850 MB")
        XCTAssertEqual(Format.diskSpace(999_400_000), "999 MB")
        XCTAssertEqual(Format.diskSpace(4_200_000_000), "4,2 GB")
        XCTAssertEqual(Format.diskSpace(368_000_000_000), "368 GB")
        XCTAssertEqual(Format.diskSpace(995_000_000_000), "995 GB")
        XCTAssertEqual(Format.diskSpace(1_200_000_000_000), "1,2 TB")
        XCTAssertEqual(Format.diskSpace(15_300_000_000_000), "15,3 TB")
    }

    func testARoundingThatReachesTheNextUnitMovesToIt() {
        XCTAssertEqual(Format.diskSpace(999_600_000_000), "1,0 TB", "never 1000 GB")
        XCTAssertEqual(Format.diskSpace(999_500_000), "1,0 GB", "never 1000 MB")
        XCTAssertEqual(Format.diskSpace(9_960_000_000), "10 GB", "never 10,0 GB")
        XCTAssertEqual(Format.diskSpace(999_400_000_000), "999 GB")
    }

    func testNegativeIsZero() {
        XCTAssertEqual(Format.diskSpace(-1), "0 MB")
        XCTAssertEqual(Format.diskSpace(.min), "0 MB")
    }

    func testPartsSplitNumberAndUnit() {
        XCTAssertTrue(Format.diskSpaceParts(368_000_000_000) == ("368", "GB"))
        XCTAssertTrue(Format.diskSpaceParts(4_200_000_000) == ("4,2", "GB"))
        XCTAssertTrue(Format.diskSpaceParts(850_000_000) == ("850", "MB"))
        XCTAssertTrue(Format.diskSpaceParts(1_200_000_000_000) == ("1,2", "TB"))
    }

    func testDiskFree() {
        XCTAssertEqual(Format.diskFree(368_000_000_000), "368 GB livres")
        XCTAssertEqual(Format.diskFree(4_200_000_000), "4,2 GB livres")
        XCTAssertEqual(Format.diskFree(-5), "0 MB livres")
    }

    func testDiskNeverScalesBelowOneMegabytePerSecond() {
        XCTAssertEqual(HistoryScale.diskFloor, 1_048_576)
        XCTAssertEqual(HistoryScale.fractions([524_288], for: .disk), [0.5])
        XCTAssertEqual(HistoryScale.fractions([10_485_760, 5_242_880], for: .disk), [1, 0.5])
        XCTAssertEqual(HistoryScale.fractions([10_485_760], for: .disk, peak: 20_971_520), [0.5])
        XCTAssertEqual(HistoryScale.fractions([0, 0], for: .disk), [0, 0])
        XCTAssertEqual(HistoryScale.fractions([524_288], for: .disk, peak: 0), [0.5])
        XCTAssertEqual(HistoryScale.fractions([], for: .disk), [])
    }
}

// MARK: - Menu bar

final class DiskBarTests: XCTestCase {
    private func spec(_ text: String, _ secondary: String?, labels: Bool) -> MenuBarSpec {
        MenuBarSpec(items: [.init(metric: .disk, text: text, tone: .normal, secondary: secondary)],
                    showLabels: labels, colorize: false)
    }

    func testDiskWidthIgnoresLabelsAndValue() {
        let reference = MenuBarRenderer.widgetWidth(metric: .disk, showLabels: true)
        XCTAssertGreaterThan(reference, 0)
        XCTAssertEqual(MenuBarRenderer.widgetWidth(metric: .disk, showLabels: false), reference)
        for (read, write) in [("0 KB/s", "0 KB/s"), ("12 KB/s", "1,2 MB/s"), ("999 KB/s", "999 MB/s"), ("–", "–")] {
            for labels in [true, false] {
                let size = MenuBarRenderer.imageSize(for: spec(read, write, labels: labels), height: 22)
                XCTAssertEqual(size.width, reference)
                XCTAssertEqual(MenuBarRenderer.image(for: spec(read, write, labels: labels), height: 22).size, size)
            }
        }
    }

    func testAccessibilityText() {
        let s = MenuBarSpec(items: [.init(metric: .disk, text: "340 KB/s", tone: .normal, secondary: "1,2 MB/s")],
                            showLabels: true, colorize: false)
        XCTAssertEqual(s.accessibilityText, "disco, leitura 340 KB/s, escrita 1,2 MB/s")
        let none = MenuBarSpec(items: [.init(metric: .disk, text: "–", tone: .normal)],
                               showLabels: false, colorize: false)
        XCTAssertEqual(none.accessibilityText, "disco, leitura –, escrita –")
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

    func testDiskDrawsTwoLinesWithInkOnBothHalves() throws {
        for labels in [true, false] {
            let image = MenuBarRenderer.image(for: spec("12 KB/s", "1,2 MB/s", labels: labels), height: 22)
            let rows = try inkRows(image)
            XCTAssertTrue(rows.contains { $0 < 11 }, "read line in the top half")
            XCTAssertTrue(rows.contains { $0 >= 11 }, "write line in the bottom half")
            XCTAssertGreaterThanOrEqual(rows.first ?? 0, 2, "inside the bar, not cut at the top")
            XCTAssertLessThan(rows.last ?? 99, 21, "inside the bar, not cut at the bottom")
        }
    }

    func testDiskSitsAfterTheNetworkInTheBar() {
        let both = MenuBarSpec(items: [.init(metric: .network, text: "0", tone: .normal, secondary: "0"),
                                       .init(metric: .disk, text: "0", tone: .normal, secondary: "0")],
                               showLabels: true, colorize: false)
        let segments = MenuBarRenderer.segments(for: both)
        XCTAssertEqual(segments.map(\.metric), [.network, .disk])
        XCTAssertEqual(segments[1].span.lowerBound, segments[0].span.upperBound + MenuBarRenderer.spacing)
    }
}

// MARK: - Monitor

@MainActor
final class DiskMonitorTests: XCTestCase {
    private func makeSettings(_ metrics: Set<Metric>) -> StatsSettings {
        let settings = StatsSettings(store: UserDefaults(suiteName: "stats-disk-\(UUID().uuidString)")!)
        settings.enabledMetrics = metrics
        return settings
    }

    private func makeMonitor(_ metrics: Set<Metric>) -> SystemMonitor {
        SystemMonitor(settings: makeSettings(metrics))
    }

    /// Lets the main queue run, where the background reads hand their result back.
    private func spin(_ seconds: TimeInterval, until condition: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testDiskHasNoRatesUntilTheSecondReading() throws {
        try XCTSkipIf(DiskSampler.read()?.isEmpty ?? true, "sem contadores de disco neste ambiente")
        let monitor = makeMonitor([.disk])
        monitor.sample(.tick)
        XCTAssertNil(monitor.snapshot.disk)
        XCTAssertTrue(monitor.values(for: .disk).isEmpty)
        XCTAssertTrue(monitor.writeValues().isEmpty)
        Thread.sleep(forTimeInterval: 0.3)
        for _ in 0..<3 { monitor.sample(.extra) }
        XCTAssertNil(monitor.snapshot.disk, "extra samples never touch the disk rates")
        XCTAssertTrue(monitor.rawValues(for: .disk).isEmpty)
        monitor.sample(.tick)
        XCTAssertNotNil(monitor.snapshot.disk)
        XCTAssertEqual(monitor.rawValues(for: .disk).count, 1)
        XCTAssertEqual(monitor.writeHistory.values.count, 1)
        monitor.sample(.cpuFollowUp)
        XCTAssertEqual(monitor.rawValues(for: .disk).count, 1, "two reads a few ms apart are ignored")
        Thread.sleep(forTimeInterval: 0.3)
        monitor.sample(.cpuFollowUp)
        XCTAssertEqual(monitor.rawValues(for: .disk).count, 2, "the follow-up adds history like a tick")
        XCTAssertEqual(monitor.writeHistory.values.count, 2)
    }

    func testReadAndWriteShareOneScale() {
        let monitor = makeMonitor([.disk])
        monitor.history[.disk]?.append(524_288)
        XCTAssertEqual(monitor.values(for: .disk), [0.5], "1 MB/s floor")
        monitor.history[.disk]?.append(20_971_520)
        monitor.writeHistory.append(10_485_760)
        XCTAssertEqual(monitor.values(for: .disk), [524_288.0 / 20_971_520, 1])
        XCTAssertEqual(monitor.writeValues(), [0.5])
    }

    func testFreeSpaceIsReadInTheBackground() throws {
        try XCTSkipIf(DiskSampler.readSpace() == nil, "sem leitura do espaço neste ambiente")
        let monitor = makeMonitor([.disk])
        var samples = 0
        monitor.onSample = { samples += 1 }
        monitor.sample(.tick)
        XCTAssertNil(monitor.snapshot.diskSpace, "the tick never waits for the volume")
        spin(5) { monitor.snapshot.diskSpace != nil }
        XCTAssertGreaterThan(monitor.snapshot.diskSpace?.total ?? 0, 0)
        XCTAssertEqual(samples, 2, "one for the tick, one when the space arrives")
    }

    func testFreeSpaceIsNotReadAgainWithinThirtySeconds() throws {
        try XCTSkipIf(DiskSampler.readSpace() == nil, "sem leitura do espaço neste ambiente")
        let monitor = makeMonitor([.disk])
        monitor.sample(.tick)
        spin(5) { monitor.snapshot.diskSpace != nil }
        XCTAssertNotNil(monitor.snapshot.diskSpace)
        monitor.snapshot.diskSpace = nil
        for _ in 0..<3 { monitor.sample(.tick) }
        monitor.sample(.extra)
        spin(0.4)
        XCTAssertNil(monitor.snapshot.diskSpace, "read at most every \(SystemMonitor.diskSpaceInterval) s")
    }

    func testTheSpaceIsOnlyReadWhileTheDiskIsOn() {
        let monitor = makeMonitor([.memory])
        monitor.sample(.tick)
        spin(0.4)
        XCTAssertNil(monitor.snapshot.diskSpace)
    }

    func testApplyingTheSpace() {
        let monitor = makeMonitor([.disk])
        let space = DiskSpace(available: 368_000_000_000, total: 995_000_000_000, name: "Macintosh HD")
        var samples = 0
        monitor.onSample = { samples += 1 }
        monitor.applyDiskSpace(space, generation: monitor.diskSpaceGeneration - 1)
        XCTAssertNil(monitor.snapshot.diskSpace, "a read from before the disk was switched off is ignored")
        XCTAssertEqual(samples, 0)
        monitor.applyDiskSpace(space, generation: monitor.diskSpaceGeneration)
        XCTAssertEqual(monitor.snapshot.diskSpace, space)
        XCTAssertEqual(samples, 1)
        monitor.applyDiskSpace(space, generation: monitor.diskSpaceGeneration)
        XCTAssertEqual(samples, 1, "the same value draws nothing new")
        monitor.applyDiskSpace(nil, generation: monitor.diskSpaceGeneration)
        XCTAssertNil(monitor.snapshot.diskSpace, "a failed read hides the space instead of keeping a stale value")
        XCTAssertEqual(samples, 2)
    }

    func testAReadFinishingAfterStopIsIgnored() throws {
        try XCTSkipIf(DiskSampler.readSpace() == nil, "sem leitura do espaço neste ambiente")
        let monitor = makeMonitor([.disk])
        monitor.start()   // the first tick starts the read…
        monitor.stop()    // …and the monitor stops before it comes back
        spin(0.5)
        XCTAssertNil(monitor.snapshot.diskSpace)
    }

    func testSwitchingTheDiskOffClearsItAndDropsAReadInFlight() throws {
        try XCTSkipIf(DiskSampler.readSpace() == nil, "sem leitura do espaço neste ambiente")
        let settings = makeSettings([.disk])
        let monitor = SystemMonitor(settings: settings)
        monitor.start()
        defer { monitor.stop() }
        monitor.snapshot.disk = DiskRates(read: 1, write: 1)
        settings.setEnabled(.disk, false)
        XCTAssertNil(monitor.snapshot.disk)
        XCTAssertNil(monitor.snapshot.diskSpace)
        spin(0.5)
        XCTAssertNil(monitor.snapshot.diskSpace, "the late result is ignored")
    }

    func testSwitchingTheDiskOnReadsAtOnce() throws {
        try XCTSkipIf(DiskSampler.readSpace() == nil, "sem leitura do espaço neste ambiente")
        let settings = makeSettings([.memory])
        let monitor = SystemMonitor(settings: settings)
        monitor.start()
        defer { monitor.stop() }
        settings.setEnabled(.disk, true)
        spin(5) { monitor.snapshot.diskSpace != nil }
        XCTAssertNotNil(monitor.snapshot.diskSpace)
    }

    func testProbeKeepsTheDiskUnlessNothingCanBeRead() throws {
        try XCTSkipIf(DiskSampler.read()?.isEmpty ?? true, "sem contadores de disco neste ambiente")
        let monitor = makeMonitor([.disk])
        monitor.probeAvailability()
        XCTAssertNil(monitor.unavailable[.disk])
        XCTAssertTrue(monitor.activeMetrics.contains(.disk))
    }
}

// MARK: - Panel and tool

@MainActor
final class DiskPanelTests: XCTestCase {
    private func idealHeight(space: DiskSpace?) -> CGFloat {
        let settings = StatsSettings(store: UserDefaults(suiteName: "disk-panel-\(UUID().uuidString)")!)
        settings.enabledMetrics = [.disk]
        let monitor = SystemMonitor(settings: settings)
        monitor.unavailable = [:]
        monitor.snapshot.diskSpace = space
        let state = PanelState()
        state.selected = .disk
        let panel = StatsPanel(monitor: monitor, state: state, processes: TopProcessesModel(),
                               onSettings: {}, onBack: nil, onToggleOwnIcon: {})
        return NSHostingView(rootView: AnyView(panel)).fittingSize.height
    }

    func testTheSpaceBlockIsLeftOutWithoutAReading() {
        let named = idealHeight(space: DiskSpace(available: 368_000_000_000, total: 995_000_000_000, name: "Macintosh HD"))
        let unnamed = idealHeight(space: DiskSpace(available: 368_000_000_000, total: 995_000_000_000, name: nil))
        let none = idealHeight(space: nil)
        XCTAssertGreaterThan(unnamed, none + 15, "free space and bar")
        XCTAssertGreaterThan(named, unnamed + 10, "the volume row")
        XCTAssertGreaterThan(none, 150, "read and write blocks are still laid out")
    }
}

@MainActor
final class DiskToolTests: XCTestCase {
    private func makeStore() -> UserDefaults {
        let suite = "stats-disk-tool-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        addTeardownBlock { store.removePersistentDomain(forName: suite) }
        for metric in Metric.allCases { store.set(metric == .disk, forKey: metric.defaultsKey) }
        return store
    }

    func testTheBarShowsReadAboveWrite() {
        let tool = StatsTool(defaults: makeStore())
        var snapshot = StatsSnapshot()
        snapshot.disk = DiskRates(read: 340 * 1_024, write: 1.2 * 1_048_576)
        tool.monitor.snapshot = snapshot
        tool.monitor.onSample?()
        XCTAssertEqual(tool.menuBarImage.accessibilityDescription, "disco, leitura 340 KB/s, escrita 1,2 MB/s")
    }

    func testNoDataIsAnEnDashNeverZero() {
        let tool = StatsTool(defaults: makeStore())
        tool.monitor.snapshot = StatsSnapshot()
        tool.monitor.onSample?()
        XCTAssertEqual(tool.menuBarImage.accessibilityDescription, "disco, leitura –, escrita –")
    }

    func testTheDiskIsOffByDefaultAndListedInSettings() {
        let settings = StatsSettings(store: UserDefaults(suiteName: "stats-disk-default-\(UUID().uuidString)")!)
        XCTAssertFalse(settings.enabledMetrics.contains(.disk))
        XCTAssertTrue(Metric.allCases.contains(.disk), "Settings lists Metric.allCases")
        settings.setEnabled(.disk, true)
        XCTAssertTrue(settings.enabledMetrics.contains(.disk))
        let monitor = SystemMonitor(settings: settings)
        XCTAssertTrue(monitor.activeMetrics.contains(.disk))
        monitor.unavailable[.disk] = SystemMonitor.diskNote
        XCTAssertFalse(monitor.activeMetrics.contains(.disk))
    }
}

// MARK: - Real system (sanity only)

final class RealDiskTests: XCTestCase {
    func testCounters() throws {
        let counters = try XCTUnwrap(DiskSampler.read(), "IOKit matching failed")
        guard !counters.isEmpty else { throw XCTSkip("Sem discos físicos neste ambiente") }
        XCTAssertTrue(counters.values.contains { $0.read > 0 }, "the boot disk has read something since boot")
        XCTAssertEqual(DiskSampler.read()?.keys.sorted(), counters.keys.sorted(), "same disks, same keys")
    }

    func testSpace() throws {
        guard let space = DiskSampler.readSpace() else { throw XCTSkip("Sem leitura do espaço neste ambiente") }
        XCTAssertGreaterThan(space.total, 0)
        XCTAssertGreaterThanOrEqual(space.available, 0)
        XCTAssertLessThanOrEqual(space.usedFraction, 1)
    }
}
