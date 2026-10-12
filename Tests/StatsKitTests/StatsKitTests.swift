import XCTest
import AppKit
@testable import StatsKit

// MARK: - Pure maths

final class CPUMathTests: XCTestCase {
    private func ticks(_ user: UInt32, _ system: UInt32, _ idle: UInt32, nice: UInt32 = 0) -> CPUTicks {
        CPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    func testEqualCountersGiveZero() {
        let t = [ticks(100, 50, 850), ticks(10, 10, 10)]
        let usage = CPUSampler.usage(previous: t, current: t)
        XCTAssertEqual(usage.total, 0)
        XCTAssertEqual(usage.perCore, [0, 0])
    }

    func testOneCoreFullyBusy() {
        let previous = [ticks(0, 0, 0), ticks(0, 0, 0)]
        let current = [ticks(60, 40, 0), ticks(0, 0, 100)]
        let usage = CPUSampler.usage(previous: previous, current: current)
        XCTAssertEqual(usage.perCore[0], 1, accuracy: 1e-9)
        XCTAssertEqual(usage.perCore[1], 0, accuracy: 1e-9)
        XCTAssertEqual(usage.total, 0.5, accuracy: 1e-9)
        XCTAssertEqual(usage.user, 0.3, accuracy: 1e-9)
        XCTAssertEqual(usage.system, 0.2, accuracy: 1e-9)
        XCTAssertEqual(usage.idle, 0.5, accuracy: 1e-9)
    }

    func testNiceCountsAsUser() {
        let usage = CPUSampler.usage(previous: [ticks(0, 0, 0)], current: [ticks(0, 0, 50, nice: 50)])
        XCTAssertEqual(usage.user, 0.5, accuracy: 1e-9)
    }

    func testRegressingCounterIsZeroNotNaNOrNegative() {
        let previous = [ticks(500, 500, 500), ticks(0, 0, 0)]
        let current = [ticks(100, 100, 100), ticks(50, 0, 50)]
        let usage = CPUSampler.usage(previous: previous, current: current)
        XCTAssertEqual(usage.perCore[0], 0)
        XCTAssertEqual(usage.perCore[1], 0.5, accuracy: 1e-9)
        for value in [usage.total, usage.user, usage.system, usage.idle] + usage.perCore {
            XCTAssertFalse(value.isNaN)
            XCTAssertGreaterThanOrEqual(value, 0)
        }
        let allRegressed = CPUSampler.usage(previous: [ticks(9, 9, 9)], current: [ticks(1, 1, 1)])
        XCTAssertEqual(allRegressed.total, 0)
    }

    func testCoreSummary() {
        let levels = [CoreLevel(name: "Super", count: 5), CoreLevel(name: "Performance", count: 10)]
        XCTAssertEqual(CPUSampler.coreSummary(levels: levels, logicalCores: 15), "5 Super + 10 Performance")
        XCTAssertEqual(CPUSampler.coreSummary(levels: [], logicalCores: 8), "8 núcleos")
        XCTAssertEqual(CPUSampler.coreSummary(levels: [CoreLevel(name: "Performance", count: 8)], logicalCores: 8), "8 núcleos")
    }
}

final class MemoryMathTests: XCTestCase {
    /// Numbers from a real `vm_stat` (16 KB pages) on a 24 GB Mac.
    func testBreakdownWithRealNumbers() {
        let counters = VMCounters(internalPages: 634_842, purgeable: 6_718, wired: 219_287,
                                  compressor: 414_007, external: 239_276, free: 5_646)
        let m = MemorySampler.breakdown(counters: counters, pageSize: 16_384, total: 25_769_803_776)
        XCTAssertEqual(m.app, (634_842 - 6_718) * 16_384)
        XCTAssertEqual(m.wired, 219_287 * 16_384)
        XCTAssertEqual(m.compressed, 414_007 * 16_384)
        XCTAssertEqual(m.cached, (239_276 + 6_718) * 16_384)
        XCTAssertEqual(m.free, 5_646 * 16_384)
        XCTAssertEqual(m.used, m.app + m.wired + m.compressed)
        XCTAssertEqual(Double(m.used) / 1e9, 20.67, accuracy: 0.01)
        XCTAssertEqual(m.usedFraction, 0.802, accuracy: 0.001)
    }

    func testPurgeableLargerThanInternalDoesNotUnderflow() {
        let counters = VMCounters(internalPages: 1, purgeable: 5, wired: 0, compressor: 0, external: 0, free: 0)
        XCTAssertEqual(MemorySampler.breakdown(counters: counters, pageSize: 4096, total: 1 << 20).app, 0)
    }

    func testPressureLevels() {
        XCTAssertEqual(MemoryPressure(level: 1), .normal)
        XCTAssertEqual(MemoryPressure(level: 2), .warning)
        XCTAssertEqual(MemoryPressure(level: 4), .critical)
        XCTAssertEqual(MemoryPressure(level: 0), .normal)
    }
}

final class GPUParseTests: XCTestCase {
    func testParsesAcceleratorProperties() {
        let reading = GPUSampler.parse(properties: [
            "model": "Apple M5 Pro",
            "gpu-core-count": 20,
            "PerformanceStatistics": ["Device Utilization %": 37, "Renderer Utilization %": 30,
                                      "Tiler Utilization %": 12, "In use system memory": 123_456_789],
        ])
        XCTAssertEqual(reading?.device ?? -1, 0.37, accuracy: 1e-9)
        XCTAssertEqual(reading?.renderer ?? -1, 0.30, accuracy: 1e-9)
        XCTAssertEqual(reading?.tiler ?? -1, 0.12, accuracy: 1e-9)
        XCTAssertEqual(reading?.inUseMemory, 123_456_789)
        XCTAssertEqual(reading?.name, "Apple M5 Pro")
        XCTAssertEqual(reading?.cores, 20)
    }

    func testMissingStatisticsGiveNil() {
        XCTAssertNil(GPUSampler.parse(properties: [:]))
        XCTAssertNil(GPUSampler.parse(properties: ["PerformanceStatistics": ["Tiler Utilization %": 1]]))
    }
}

// MARK: - top

final class TopParserTests: XCTestCase {
    private let twoSamples = """
    Processes: 600 total, 3 running, 597 sleeping, 3000 threads
    Load Avg: 1.5, 1.4, 1.3
    CPU usage: 5.0% user, 3.0% sys, 92.0% idle

    PID    %CPU MEM    COMMAND
    411    0.0  1017M- WindowServer
    84229  0.0  806M-  Claude Helper (R
    93575  0.0  5968K+ top

    Processes: 600 total, 3 running, 597 sleeping, 3000 threads
    Load Avg: 1.5, 1.4, 1.3
    CPU usage: 5.0% user, 3.0% sys, 92.0% idle

    PID    %CPU MEM    COMMAND
    411    27.6 1017M- WindowServer
    84229  8.3  806M-  Claude Helper (R
    93575  5.3  5968K+ top
    120    1,5  2,5G   Some App
    """

    func testUsesLastSampleAndExcludesTop() {
        let rows = TopParser.parse(twoSamples, excludingPID: 93575)
        XCTAssertEqual(rows.map(\.pid), [411, 84229, 120])
        XCTAssertEqual(rows[0].cpu, 27.6, accuracy: 1e-9)
        XCTAssertEqual(rows[0].command, "WindowServer")
    }

    func testCommandWithSpacesAndSuffixes() {
        let rows = TopParser.parse(twoSamples)
        XCTAssertEqual(rows[1].command, "Claude Helper (R")
        XCTAssertEqual(rows[1].memoryBytes, 806 * 1024 * 1024)
        XCTAssertEqual(rows[2].memoryBytes, 5968 * 1024)
        XCTAssertEqual(rows[3].cpu, 1.5, accuracy: 1e-9)
        XCTAssertEqual(rows[3].memoryBytes, UInt64(2.5 * 1024 * 1024 * 1024))
        XCTAssertEqual(rows[3].command, "Some App")
    }

    func testCPUIsShareOfWholeMachine() {
        XCTAssertEqual(TopProcessesModel.machineShare(940.2, cores: 12), 78.35, accuracy: 1e-9)
        XCTAssertEqual(TopProcessesModel.machineShare(25.3, cores: 1), 25.3, accuracy: 1e-9)
        XCTAssertEqual(TopProcessesModel.machineShare(1300, cores: 12), 100, accuracy: 1e-9)
        XCTAssertEqual(TopProcessesModel.machineShare(50, cores: 0), 50, accuracy: 1e-9)
    }

    func testMemoryUnits() {
        XCTAssertEqual(TopParser.parseMemory("0B"), 0)
        XCTAssertEqual(TopParser.parseMemory("12K-"), 12 * 1024)
        XCTAssertEqual(TopParser.parseMemory("1G+"), 1 << 30)
        XCTAssertNil(TopParser.parseMemory("abc"))
        XCTAssertNil(TopParser.parseMemory(""))
    }

    func testGarbageGivesNoRows() {
        XCTAssertTrue(TopParser.parse("").isEmpty)
        XCTAssertTrue(TopParser.parse("nothing useful\nat all").isEmpty)
        XCTAssertNil(TopParser.parseRow("411 27.6"))
    }
}

// MARK: - Fans (SMC)

final class SMCTests: XCTestCase {
    func testStructLayoutMatchesTheCStruct() {
        XCTAssertEqual(MemoryLayout<SMCKeyData>.size, 80)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.stride, 80)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.key), 0)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.versMajor), 4)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.versRelease), 8)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.limitVersion), 12)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.limitLength), 14)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.cpuPLimit), 16)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.keyInfoDataSize), 28)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.keyInfoDataType), 32)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.keyInfoAttributes), 36)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.result), 40)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.status), 41)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.data8), 42)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.data32), 44)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.bytes), 48)
    }

    func testFourCC() {
        XCTAssertEqual(SMCValue.fourCC("FNum"), 0x464E756D)
    }

    func testDecodesTheSameSpeedFromEveryType() {
        XCTAssertEqual(SMCValue.decode(type: SMCValue.fourCC("flt "), bytes: [0x00, 0x40, 0xE7, 0x44]), 1850)
        XCTAssertEqual(SMCValue.decode(type: SMCValue.fourCC("fpe2"), bytes: [0x1C, 0xE8]), 1850)
        XCTAssertEqual(SMCValue.decode(type: SMCValue.fourCC("ui16"), bytes: [0x07, 0x3A]), 1850)
        XCTAssertEqual(SMCValue.decode(type: SMCValue.fourCC("ui8 "), bytes: [2]), 2)
        XCTAssertEqual(SMCValue.decode(type: SMCValue.fourCC("ui32"), bytes: [0, 0, 0x07, 0x3A]), 1850)
    }

    func testUnknownTypeOrShortBytesGiveNil() {
        XCTAssertNil(SMCValue.decode(type: SMCValue.fourCC("sp78"), bytes: [1, 2]))
        XCTAssertNil(SMCValue.decode(type: SMCValue.fourCC("flt "), bytes: [1, 2]))
        XCTAssertNil(SMCValue.decode(type: SMCValue.fourCC("flt "), bytes: [0, 0, 0xC0, 0x7F]))  // NaN
    }

    func testFanFractions() {
        let fan = FanReading(name: "Ventoinha 1", rpm: 4000, minRPM: 2000, maxRPM: 6000)
        XCTAssertEqual(fan.loadFraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(fan.historyFraction, 4000.0 / 6000.0, accuracy: 1e-9)
        XCTAssertEqual(FanReading(name: "", rpm: 0, minRPM: 2000, maxRPM: 6000).loadFraction, 0)
        XCTAssertEqual(FanReading(name: "", rpm: 9000, minRPM: 2000, maxRPM: 6000).loadFraction, 1)
        XCTAssertEqual(FanReading(name: "", rpm: 100, minRPM: 0, maxRPM: 0).loadFraction, 0)
        let slow = FanReading(name: "a", rpm: 100, minRPM: 0, maxRPM: 1000)
        XCTAssertEqual(FanMath.fastest([slow, fan])?.name, "Ventoinha 1")
        XCTAssertNil(FanMath.fastest([]))
    }
}

// MARK: - Presentation

final class PresentationTests: XCTestCase {
    func testRingBufferKeepsTheNewest() {
        var buffer = RingBuffer(capacity: 3)
        for v in [0.1, 0.2, 0.3, 0.4] { buffer.append(v) }
        XCTAssertEqual(buffer.values, [0.2, 0.3, 0.4])
        buffer.removeAll()
        XCTAssertTrue(buffer.values.isEmpty)
    }

    func testFormatters() {
        XCTAssertEqual(Format.percent(0.124), "12%")
        XCTAssertEqual(Format.percent(1.4), "100%")
        XCTAssertEqual(Format.percent(.nan), "0%")
        XCTAssertEqual(Format.percentValue(27.6), "27,6%")
        XCTAssertEqual(Format.load((1.234, 1.1, 0.95)), "1,2 · 1,1 · 1,0")
        XCTAssertEqual(Format.rpm(1849.6), "1850")
        XCTAssertEqual(Format.rpm(123_456), "9999")
    }

    func testByteFormattingIsDeterministicPtPT() {
        XCTAssertEqual(Format.bytes(0), "0 MB")
        XCTAssertEqual(Format.bytes(943 << 20), "943 MB")
        XCTAssertEqual(Format.bytes(1 << 30), "1,0 GB")
        XCTAssertEqual(Format.bytes(20_669_530_112), "19,3 GB")  // 19,25 GiB rounds half up
        XCTAssertEqual(Format.bytes(25_769_803_776), "24,0 GB")
        XCTAssertEqual(Format.bytes(1_073_000_000), "1023 MB")
        XCTAssertEqual(Format.bytes(1_073_741_000), "1,0 GB")  // never "1024 MB"
    }

    func testToneThresholds() {
        XCTAssertEqual(LoadTone.forLoad(0.59), .normal)
        XCTAssertEqual(LoadTone.forLoad(0.60), .warning)
        XCTAssertEqual(LoadTone.forLoad(0.849), .warning)
        XCTAssertEqual(LoadTone.forLoad(0.85), .critical)
        XCTAssertEqual(LoadTone.forPressure(.normal), .normal)
        XCTAssertEqual(LoadTone.forPressure(.warning), .warning)
        XCTAssertEqual(LoadTone.forPressure(.critical), .critical)
    }

    private func spec(_ metric: Metric, _ text: String, labels: Bool) -> MenuBarSpec {
        MenuBarSpec(items: [.init(metric: metric, text: text, tone: .normal)], showLabels: labels, colorize: false)
    }

    func testWidgetWidthDoesNotDependOnTheValue() {
        for labels in [true, false] {
            XCTAssertEqual(MenuBarRenderer.imageSize(for: spec(.cpu, "0%", labels: labels), height: 22),
                           MenuBarRenderer.imageSize(for: spec(.cpu, "100%", labels: labels), height: 22))
            XCTAssertEqual(MenuBarRenderer.imageSize(for: spec(.fan, "0", labels: labels), height: 22),
                           MenuBarRenderer.imageSize(for: spec(.fan, "9999", labels: labels), height: 22))
            let image = MenuBarRenderer.image(for: spec(.cpu, "7%", labels: labels), height: 22)
            XCTAssertEqual(image.size, MenuBarRenderer.imageSize(for: spec(.cpu, "100%", labels: labels), height: 22))
        }
    }

    private func fullSpec(labels: Bool) -> MenuBarSpec {
        MenuBarSpec(items: Metric.allCases.map { .init(metric: $0, text: "0", tone: .normal) },
                    showLabels: labels, colorize: false)
    }

    func testSegmentsRunLeftToRightAcrossTheImage() {
        for labels in [true, false] {
            let spec = fullSpec(labels: labels)
            let segments = MenuBarRenderer.segments(for: spec)
            XCTAssertEqual(segments.map(\.metric), Metric.allCases)
            XCTAssertEqual(segments.first?.span.lowerBound, 0)
            for (previous, next) in zip(segments, segments.dropFirst()) {
                XCTAssertEqual(next.span.lowerBound, previous.span.upperBound + MenuBarRenderer.spacing)
            }
            XCTAssertEqual(segments.last?.span.upperBound, MenuBarRenderer.imageSize(for: spec, height: 22).width)
        }
        XCTAssertTrue(MenuBarRenderer.segments(for: MenuBarSpec(items: [], showLabels: true, colorize: false)).isEmpty)
    }

    func testAClickLandsOnTheReadoutUnderIt() {
        let spec = fullSpec(labels: true)
        for segment in MenuBarRenderer.segments(for: spec) {
            let middle = (segment.span.lowerBound + segment.span.upperBound) / 2
            XCTAssertEqual(MenuBarRenderer.segment(atX: segment.span.lowerBound, in: spec), segment)
            XCTAssertEqual(MenuBarRenderer.segment(atX: middle, in: spec), segment)
            XCTAssertEqual(MenuBarRenderer.segment(atX: segment.span.upperBound, in: spec), segment)
        }
    }

    func testAClickBetweenOrBeyondGoesToTheNearestReadout() {
        let spec = fullSpec(labels: true)
        let gap = MenuBarRenderer.segments(for: spec)[0].span.upperBound
        XCTAssertEqual(MenuBarRenderer.segment(atX: gap + 1, in: spec)?.metric, .cpu)
        XCTAssertEqual(MenuBarRenderer.segment(atX: gap + MenuBarRenderer.spacing - 1, in: spec)?.metric, .memory)
        XCTAssertEqual(MenuBarRenderer.segment(atX: -20, in: spec)?.metric, .cpu)
        XCTAssertEqual(MenuBarRenderer.segment(atX: 10_000, in: spec)?.metric, .fan)
        XCTAssertNil(MenuBarRenderer.segment(atX: 5, in: MenuBarSpec(items: [], showLabels: true, colorize: false)))
    }

    func testTemplateOnlyWhenNotColoured() {
        var s = spec(.cpu, "7%", labels: true)
        XCTAssertTrue(MenuBarRenderer.image(for: s, height: 22).isTemplate)
        s.colorize = true
        // Colour on, but nothing in alert: stays monochrome.
        XCTAssertTrue(MenuBarRenderer.image(for: s, height: 22).isTemplate)
        s.items[0].tone = .warning
        XCTAssertFalse(MenuBarRenderer.image(for: s, height: 22).isTemplate)
        let empty = MenuBarSpec(items: [], showLabels: true, colorize: false)
        XCTAssertTrue(MenuBarRenderer.image(for: empty, height: 22).isTemplate)
    }

    func testAccessibilityText() {
        let s = MenuBarSpec(items: [.init(metric: .cpu, text: "12%", tone: .normal),
                                    .init(metric: .memory, text: "48%", tone: .normal),
                                    .init(metric: .fan, text: "1850", tone: .normal)],
                            showLabels: true, colorize: false)
        XCTAssertEqual(s.accessibilityText, "CPU 12%, memória 48%, ventoinhas 1850 rpm")
    }

    func testSettingsDefaultsAndPersistence() {
        let suite = "stats-tests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let settings = StatsSettings(store: store)
        XCTAssertEqual(settings.enabledMetrics, Set(Metric.allCases))
        XCTAssertTrue(settings.showLabels)
        XCTAssertFalse(settings.colorByLoad)
        XCTAssertEqual(settings.interval, .one)

        settings.setEnabled(.gpu, false)
        settings.interval = .five
        settings.colorByLoad = true
        let reloaded = StatsSettings(store: store)
        XCTAssertFalse(reloaded.enabledMetrics.contains(.gpu))
        XCTAssertEqual(reloaded.interval, .five)
        XCTAssertTrue(reloaded.colorByLoad)
    }
}

// MARK: - Real system (sanity only)

final class RealSamplerTests: XCTestCase {
    func testTwoCPUSamples() throws {
        let first = try XCTUnwrap(CPUSampler.readTicks())
        XCTAssertFalse(first.isEmpty)
        Thread.sleep(forTimeInterval: 0.2)
        let second = try XCTUnwrap(CPUSampler.readTicks())
        let usage = CPUSampler.usage(previous: first, current: second)
        XCTAssertGreaterThanOrEqual(usage.total, 0)
        XCTAssertLessThanOrEqual(usage.total, 1)
        XCTAssertEqual(usage.perCore.count, first.count)
        XCTAssertNotNil(CPUSampler.loadAverage())
    }

    func testMemory() throws {
        let memory = try XCTUnwrap(MemorySampler.read())
        XCTAssertGreaterThan(memory.used, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)
        XCTAssertTrue([1, 2, 4].contains(MemorySampler.pressure().rawValue))
        let swap = MemorySampler.swap()
        XCTAssertNotNil(swap)
    }

    func testGPUIsNilOrInRange() {
        if let gpu = GPUSampler().read() {
            XCTAssertGreaterThanOrEqual(gpu.device, 0)
            XCTAssertLessThanOrEqual(gpu.device, 1)
        }
    }

    private func requireTop() async throws -> [ProcessUsage] {
        let rows = await TopRunner.run(arguments: TopRunner.memoryArguments)
        if rows.isEmpty { throw XCTSkip("o top não correu neste ambiente") }
        return rows
    }

    func testTopMemoryCycleReturnsRows() async throws {
        let rows = try await requireTop()
        XCTAssertTrue(rows.allSatisfy { $0.pid > 0 })
    }

    func testCancellingStopsTop() async throws {
        // A normal run works first, otherwise "cancelled → empty" proves nothing.
        _ = try await requireTop()
        let task = Task { await TopRunner.run(arguments: TopRunner.cpuArguments) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let start = Date()
        task.cancel()
        let rows = await task.value
        XCTAssertTrue(rows.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testFans() throws {
        guard case .success(let smc) = SMCConnection.open() else { throw XCTSkip("SMC não abre") }
        defer { smc.close() }
        guard case .value(let count) = smc.readValue("FNum"), count > 0 else { throw XCTSkip("Sem ventoinhas") }
        guard case .value(let rpm) = smc.readValue("F0Ac"),
              case .value(let minimum) = smc.readValue("F0Mn"),
              case .value(let maximum) = smc.readValue("F0Mx") else { throw XCTSkip("Tipo SMC não suportado") }
        XCTAssertGreaterThanOrEqual(rpm, 0)
        XCTAssertLessThanOrEqual(rpm, 12_000)
        XCTAssertLessThanOrEqual(minimum, maximum)
    }
}

// MARK: - Fan availability (fake SMC)

final class FakeSMC: SMCReader {
    var values: [String: SMCRead]
    private(set) var closed = 0
    init(_ values: [String: SMCRead]) { self.values = values }
    func readValue(_ key: String) -> SMCRead { values[key] ?? .missing }
    func close() { closed += 1 }

    static func twoFans() -> FakeSMC {
        FakeSMC(["FNum": .value(2),
                 "F0Ac": .value(3000), "F0Mn": .value(2300), "F0Mx": .value(7800),
                 "F1Ac": .value(3100), "F1Mn": .value(2300), "F1Mx": .value(7800)])
    }
}

final class FanAvailabilityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testTransientOpenFailureStaysEligibleAndRecovers() {
        var opens = 0
        var canOpen = false
        let smc = FakeSMC.twoFans()
        let sampler = FanSampler(opener: {
            opens += 1
            return canOpen ? .success(smc) : .failure(SMCOpenError(code: 1, step: "test"))
        })
        XCTAssertNil(sampler.read(now: t0))
        XCTAssertEqual(sampler.availability, .unreadable)
        XCTAssertEqual(opens, 1)
        // Backoff: no new attempt right away.
        XCTAssertNil(sampler.read(now: t0.addingTimeInterval(1)))
        XCTAssertEqual(opens, 1)
        canOpen = true
        let readings = sampler.read(now: t0.addingTimeInterval(3))
        XCTAssertEqual(readings?.count, 2)
        XCTAssertEqual(sampler.availability, .available(count: 2))
        XCTAssertEqual(sampler.fanCount, 2)
    }

    func testMissingFNumIsPermanentNoFans() {
        var opens = 0
        let sampler = FanSampler(opener: { opens += 1; return .success(FakeSMC(["FNum": .missing])) })
        XCTAssertNil(sampler.read(now: t0))
        XCTAssertEqual(sampler.availability, .noFans)
        XCTAssertEqual(sampler.availability.note, "Este Mac não tem ventoinhas.")
        XCTAssertNil(sampler.read(now: t0.addingTimeInterval(1_000)))
        XCTAssertEqual(opens, 1, "a Mac without fans is never probed again")
    }

    func testZeroFansIsNoFans() {
        let sampler = FanSampler(opener: { .success(FakeSMC(["FNum": .value(0)])) })
        XCTAssertNil(sampler.read(now: t0))
        XCTAssertEqual(sampler.availability, .noFans)
    }

    func testUnreadableFNumIsTransient() {
        let sampler = FanSampler(opener: { .success(FakeSMC(["FNum": .failure])) })
        XCTAssertNil(sampler.read(now: t0))
        XCTAssertEqual(sampler.availability, .unreadable)
    }

    func testIOFailureMidReadGoesUnreadableThenRecovers() {
        let smc = FakeSMC.twoFans()
        let sampler = FanSampler(opener: { .success(smc) })
        XCTAssertEqual(sampler.read(now: t0)?.first?.rpm, 3000)
        smc.values["F1Ac"] = .failure
        XCTAssertNil(sampler.read(now: t0.addingTimeInterval(1)))
        XCTAssertEqual(sampler.availability, .unreadable)
        XCTAssertGreaterThan(smc.closed, 0, "a broken connection is closed")
        smc.values["F1Ac"] = .value(3100)
        XCTAssertNil(sampler.read(now: t0.addingTimeInterval(2)), "still backing off")
        XCTAssertEqual(sampler.read(now: t0.addingTimeInterval(5))?.count, 2)
        XCTAssertEqual(sampler.availability, .available(count: 2))
    }
}

// MARK: - Monitor scheduling and history

@MainActor
final class MonitorTests: XCTestCase {
    private func makeMonitor(_ metrics: Set<Metric>) -> SystemMonitor {
        let suite = "stats-monitor-\(UUID().uuidString)"
        let settings = StatsSettings(store: UserDefaults(suiteName: suite)!)
        settings.enabledMetrics = metrics
        return SystemMonitor(settings: settings)
    }

    func testShouldSampleRule() {
        typealias M = SystemMonitor
        XCTAssertFalse(M.shouldSample(activeMetricCount: 0, showsOwnIcon: true, visiblePanels: 1))
        XCTAssertFalse(M.shouldSample(activeMetricCount: 3, showsOwnIcon: false, visiblePanels: 0))
        XCTAssertTrue(M.shouldSample(activeMetricCount: 3, showsOwnIcon: true, visiblePanels: 0))
        XCTAssertTrue(M.shouldSample(activeMetricCount: 1, showsOwnIcon: false, visiblePanels: 1))
        XCTAssertTrue(M.shouldSample(activeMetricCount: 1, showsOwnIcon: true, visiblePanels: 2))
    }

    func testPanelCounterNeverGoesNegative() {
        let monitor = makeMonitor([.memory])
        monitor.panelDisappeared()
        XCTAssertEqual(monitor.visiblePanels, 0)
        monitor.panelAppeared()
        monitor.panelAppeared()
        monitor.panelDisappeared()
        XCTAssertEqual(monitor.visiblePanels, 1)
    }

    func testCPUHasNoValueUntilTheFirstDelta() {
        let monitor = makeMonitor([.cpu, .memory])
        monitor.sample(.tick)
        XCTAssertNil(monitor.snapshot.cpu)
        XCTAssertTrue(monitor.values(for: .cpu).isEmpty)
        Thread.sleep(forTimeInterval: 0.3)
        monitor.sample(.tick)
        XCTAssertNotNil(monitor.snapshot.cpu)
        XCTAssertEqual(monitor.values(for: .cpu).count, 1)
    }

    func testOnlyTicksAddHistory() {
        let monitor = makeMonitor([.cpu, .memory])
        monitor.sample(.tick)
        XCTAssertEqual(monitor.values(for: .memory).count, 1)
        for _ in 0..<3 { monitor.sample(.extra) }
        XCTAssertEqual(monitor.values(for: .memory).count, 1)
        XCTAssertNil(monitor.snapshot.cpu, "extra samples don't touch the CPU baseline")
        Thread.sleep(forTimeInterval: 0.3)
        monitor.sample(.cpuFollowUp)
        XCTAssertEqual(monitor.values(for: .memory).count, 1, "the CPU follow-up is CPU only")
        XCTAssertEqual(monitor.values(for: .cpu).count, 1)
        monitor.sample(.tick)
        XCTAssertEqual(monitor.values(for: .memory).count, 2)
    }
}

// MARK: - StatsTool

@MainActor
final class StatsToolTests: XCTestCase {
    private func makeStore() -> UserDefaults {
        let suite = "stats-tool-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        addTeardownBlock { store.removePersistentDomain(forName: suite) }
        return store
    }

    func testOwnIconDefaultsToShownAndPersists() {
        let store = makeStore()
        let tool = StatsTool(defaults: store)
        XCTAssertTrue(tool.showsOwnMenuBarIcon)
        tool.showsOwnMenuBarIcon = false
        XCTAssertFalse(StatsTool(defaults: store).showsOwnMenuBarIcon)
        XCTAssertFalse(tool.monitor.showsOwnIcon)
    }

    func testNotifiesOnlyWhenWhatIsDrawnChanges() {
        let tool = StatsTool(defaults: makeStore())
        var notifications = 0
        tool.onMenuBarImageChange = { notifications += 1 }
        func sample(_ total: Double) {
            var snapshot = tool.monitor.snapshot
            snapshot.cpu = CPUUsage(total: total, user: total, system: 0, idle: 1 - total, perCore: [])
            tool.monitor.snapshot = snapshot
            tool.monitor.onSample?()
        }
        sample(0.12)
        XCTAssertEqual(notifications, 1)
        sample(0.121)  // still "12%"
        XCTAssertEqual(notifications, 1)
        sample(0.13)
        XCTAssertEqual(notifications, 2)
    }

    func testAClickOnAReadoutOpensThePanelOnIt() {
        let tool = StatsTool(defaults: makeStore())
        let spec = MenuBarSpec(items: Metric.allCases.map { .init(metric: $0, text: "–", tone: .normal) },
                               showLabels: true, colorize: false)
        // Last to first: a Mac without fans drops that readout after the first
        // sample, and the ones before it must not move.
        for segment in MenuBarRenderer.segments(for: spec).reversed() {
            let middle = (segment.span.lowerBound + segment.span.upperBound) / 2
            XCTAssertEqual(tool.panelWillShow(clickedAtX: middle), segment.span)
            XCTAssertEqual(tool.panelState.selected, segment.metric)
        }
    }

    func testSwitchingTabInThePanelMovesThePopoverArrow() {
        let tool = StatsTool(defaults: makeStore())
        let spec = MenuBarSpec(items: Metric.allCases.map { .init(metric: $0, text: "–", tone: .normal) },
                               showLabels: true, colorize: false)
        _ = tool.panelWillShow(clickedAtX: MenuBarRenderer.segments(for: spec).last!.span.lowerBound)
        var parts: [ClosedRange<CGFloat>?] = []
        tool.onPanelPartChange = { parts.append($0) }
        tool.panelState.selected = .cpu
        tool.panelState.selected = .cpu  // no change, no call
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts.first ?? nil, MenuBarRenderer.segments(for: spec).first?.span)
    }
}
