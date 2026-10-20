import XCTest
import Darwin
@testable import StatsKit

// MARK: - SMC decoding

final class SensorDecodeTests: XCTestCase {
    func testSp78IsSignedEightPointEight() {
        let type = SMCValue.fourCC("sp78")
        XCTAssertEqual(SMCValue.decode(type: type, bytes: [0x4B, 0x80]), 75.5)
        XCTAssertEqual(SMCValue.decode(type: type, bytes: [0x00, 0x00]), 0)
        XCTAssertEqual(SMCValue.decode(type: type, bytes: [0xFF, 0x00]), -1)
        XCTAssertEqual(SMCValue.decode(type: type, bytes: [0x80, 0x00]), -128)
        XCTAssertNil(SMCValue.decode(type: type, bytes: [0x4B]))
        XCTAssertNil(SMCValue.decode(type: type, bytes: []))
    }

    func testTextIsTheInverseOfFourCC() {
        for key in ["FNum", "#KEY", "Tp01", "PSTR", "flt "] {
            XCTAssertEqual(SMCValue.text(SMCValue.fourCC(key)), key)
        }
        XCTAssertEqual(SMCValue.text(0x464E756D), "FNum")
    }
}

// MARK: - Key index

final class SMCKeyIndexTests: XCTestCase {
    private let sorted = ["TA0P", "TB0T", "TB1T", "TC0P", "Ta0P", "Te05", "Tg08", "Tg09", "Tp00", "Tp01", "Tp02", "Tz99"]

    private func find(_ prefix: String, in list: [String]? = nil) -> [String]? {
        let keys = list ?? sorted
        return SMCKeyIndex.keys(withPrefix: prefix, count: keys.count, keyAt: { keys.indices.contains($0) ? keys[$0] : nil })
    }

    func testPrefixAtTheStartMiddleAndEnd() {
        XCTAssertEqual(find("TA"), ["TA0P"])
        XCTAssertEqual(find("TB"), ["TB0T", "TB1T"])
        XCTAssertEqual(find("Tg"), ["Tg08", "Tg09"])
        XCTAssertEqual(find("Tp"), ["Tp00", "Tp01", "Tp02"])
        XCTAssertEqual(find("Tz"), ["Tz99"])
    }

    func testAbsentPrefixIsEmptyNotNil() {
        XCTAssertEqual(find("Tf"), [])      // between two present prefixes
        XCTAssertEqual(find("AA"), [])      // before everything
        XCTAssertEqual(find("Zz"), [])      // after everything
        XCTAssertEqual(find("Tp", in: []), [])
    }

    func testAFailingReadIsNilNotEmpty() {
        let keys = sorted
        var failAt: Int?
        for target in 0..<keys.count {
            failAt = target
            let found = SMCKeyIndex.keys(withPrefix: "Tg", count: keys.count, keyAt: { $0 == failAt ? nil : keys[$0] })
            // Only a failure on a key the search needs gives nil; never a wrong list.
            if let found { XCTAssertEqual(found, ["Tg08", "Tg09"]) }
        }
        XCTAssertNil(SMCKeyIndex.keys(withPrefix: "Tg", count: keys.count, keyAt: { _ in nil }))
    }

    func testFindsTheRangeInAboutLogNReads() {
        let filler = (0..<3400).map { "ABCD".map(String.init)[$0 / 1000] + String(format: "%03d", $0 % 1000) }
        let keys = filler + (0..<23).map { String(format: "Tp%02d", $0) } + ["TB0T", "TB1T", "TB2T"].sorted()
        let ordered = keys.sorted()
        var reads = 0
        let found = SMCKeyIndex.keys(withPrefix: "Tp", count: ordered.count, keyAt: { reads += 1; return ordered[$0] })
        XCTAssertEqual(found?.count, 23)
        XCTAssertLessThan(reads, 23 + 30, "two binary searches plus the range, never a full scan")
    }
}

// MARK: - Temperature maths

final class TemperatureMathTests: XCTestCase {
    func testAverageIgnoresJunk() {
        XCTAssertEqual(TemperatureMath.average([60, 70, 0, -3e8, 150, 400, .nan]) ?? -1, 65, accuracy: 1e-9)
        XCTAssertEqual(TemperatureMath.average([149.9]) ?? -1, 149.9, accuracy: 1e-9)
        XCTAssertNil(TemperatureMath.average([0, -5, 150, -3e8]))
        XCTAssertNil(TemperatureMath.average([]))
        XCTAssertFalse(TemperatureMath.isPlausible(0))
        XCTAssertTrue(TemperatureMath.isPlausible(0.1))
        XCTAssertFalse(TemperatureMath.isPlausible(150))
    }

    func testSpreadPicksEvenlyAndKeepsShortLists() {
        let keys = (0..<23).map { "k\($0)" }
        XCTAssertEqual(TemperatureMath.spread(keys, limit: 6), ["k0", "k3", "k7", "k11", "k15", "k19"])
        XCTAssertEqual(TemperatureMath.spread(keys, limit: 1), ["k0"])
        XCTAssertEqual(TemperatureMath.spread(["a", "b"], limit: 6), ["a", "b"])
        XCTAssertEqual(TemperatureMath.spread(["a", "b", "c"], limit: 3), ["a", "b", "c"])
        XCTAssertEqual(TemperatureMath.spread(keys, limit: 0), [])
        XCTAssertEqual(TemperatureMath.spread([], limit: 3), [])
    }

    func testCPUKeysPerArchitecture() {
        let silicon = ["Tp": ["Tp01", "Tp00"]]
        XCTAssertEqual(TemperatureMath.cpuKeys(byPrefix: silicon, intel: false), ["Tp00", "Tp01"])
        let both = ["Tp": ["Tp00"], "Te": ["Te01"], "Tf": ["Tf00"]]
        XCTAssertEqual(TemperatureMath.cpuKeys(byPrefix: both, intel: false), ["Te01", "Tp00"], "Tf only when there is no Tp")
        let m3 = ["Tp": [], "Te": ["Te05"], "Tf": ["Tf04", "Tf09"]]
        XCTAssertEqual(TemperatureMath.cpuKeys(byPrefix: m3, intel: false), ["Te05", "Tf04", "Tf09"])
        let intel = ["TC": ["TC1C", "TC0P"], "Tp": ["Tp00"]]
        XCTAssertEqual(TemperatureMath.cpuKeys(byPrefix: intel, intel: true), ["TC0P", "TC1C"])
        XCTAssertEqual(TemperatureMath.cpuKeys(byPrefix: [:], intel: false), [])
    }
}

// MARK: - SensorSampler (fake SMC with sorted keys)

final class FakeSortedSMC: SMCReader {
    var values: [String: SMCRead] { didSet { keys = values.keys.sorted() } }
    private var keys: [String]
    var countFails = false
    var keyReadsFail = false
    private(set) var valueReads = 0
    private(set) var keyReads = 0
    private(set) var closed = 0

    init(_ values: [String: SMCRead]) {
        self.values = values
        keys = values.keys.sorted()
    }

    func readValue(_ key: String) -> SMCRead { valueReads += 1; return values[key] ?? .missing }
    func keyCount() -> Int? { countFails ? nil : keys.count }
    func key(at index: Int) -> String? {
        keyReads += 1
        return keyReadsFail || !keys.indices.contains(index) ? nil : keys[index]
    }
    func close() { closed += 1 }

    /// Shaped like the M5 Pro: 23 CPU keys, 41 GPU keys, 3 battery keys and some noise.
    static func apple() -> FakeSortedSMC {
        var values: [String: SMCRead] = ["#KEY": .value(0), "FNum": .value(2), "PSTR": .value(47.2),
                                         "Ta0P": .value(31), "TC0P": .value(0), "Th0H": .value(-3e8)]
        for i in 0..<23 { values[String(format: "Tp%02d", i)] = .value(60 + Double(i)) }
        for i in 0..<41 { values[String(format: "Tg%02d", i)] = .value(50 + Double(i)) }
        for i in 0..<3 { values["TB\(i)T"] = .value(35 + Double(i)) }
        for i in 0..<400 { values[String(format: "A%03d", i)] = .value(1) }
        return FakeSortedSMC(values)
    }
}

final class SensorSamplerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testDiscoversGroupsAndAveragesEachOne() {
        let smc = FakeSortedSMC.apple()
        let sampler = SensorSampler(opener: { .success(smc) })
        XCTAssertEqual(sampler.temperatureState, .unknown)
        let reading = sampler.readTemperature(now: t0)
        // Tp00 Tp03 Tp07 Tp11 Tp15 Tp19 / Tg00 Tg13 Tg27 / TB0T
        XCTAssertEqual(reading?.cpu ?? 0, (60 + 63 + 67 + 71 + 75 + 79) / 6.0, accuracy: 1e-9)
        XCTAssertEqual(reading?.gpu ?? 0, (50 + 63 + 77) / 3.0, accuracy: 1e-9)
        XCTAssertEqual(reading?.battery, 35)
        XCTAssertEqual(sampler.sensors, TemperatureSensors(gpu: true, battery: true))
        XCTAssertEqual(sampler.temperatureState, .available)
        XCTAssertLessThan(smc.keyReads, 140, "discovery stays around a hundred SMC calls")

        // Later ticks only read the chosen sensors.
        let keyReads = smc.keyReads, valueReads = smc.valueReads
        XCTAssertNotNil(sampler.readTemperature(now: t0.addingTimeInterval(1)))
        XCTAssertEqual(smc.keyReads, keyReads, "keys are discovered once")
        XCTAssertLessThanOrEqual(smc.valueReads - valueReads, 10)
    }

    func testJunkValuesDoNotSkewTheAverage() {
        let smc = FakeSortedSMC.apple()
        smc.values["Tp00"] = .value(0)
        smc.values["Tp03"] = .value(-3e8)
        let sampler = SensorSampler(opener: { .success(smc) })
        XCTAssertEqual(sampler.readTemperature(now: t0)?.cpu ?? 0, (67 + 71 + 75 + 79) / 4.0, accuracy: 1e-9)
    }

    func testOnlyCPUAndNoOptionalGroups() {
        let smc = FakeSortedSMC(["Tp00": .value(70), "Tp01": .value(72), "PSTR": .value(10)])
        let sampler = SensorSampler(opener: { .success(smc) })
        let reading = sampler.readTemperature(now: t0)
        XCTAssertEqual(reading, TemperatureReading(cpu: 71, gpu: nil, battery: nil))
        XCTAssertEqual(sampler.sensors, TemperatureSensors())
    }

    func testWithoutCPUKeysTemperatureIsAbsentForever() {
        var opens = 0
        let smc = FakeSortedSMC(["TB0T": .value(35), "PSTR": .value(12.5)])
        let sampler = SensorSampler(opener: { opens += 1; return .success(smc) })
        XCTAssertNil(sampler.readTemperature(now: t0))
        XCTAssertEqual(sampler.temperatureState, .absent)
        let reads = smc.valueReads + smc.keyReads
        XCTAssertNil(sampler.readTemperature(now: t0.addingTimeInterval(1_000)))
        XCTAssertEqual(smc.valueReads + smc.keyReads, reads, "an absent sensor is never probed again")
        XCTAssertEqual(opens, 1)
        // Power is independent.
        XCTAssertEqual(sampler.readPower(now: t0.addingTimeInterval(1_000)), 12.5)
        XCTAssertEqual(sampler.powerState, .available)
    }

    func testMissingPSTRIsAbsentButTemperatureKeepsWorking() {
        let smc = FakeSortedSMC.apple()
        smc.values["PSTR"] = nil
        let sampler = SensorSampler(opener: { .success(smc) })
        XCTAssertNil(sampler.readPower(now: t0))
        XCTAssertEqual(sampler.powerState, .absent)
        let reads = smc.valueReads
        XCTAssertNil(sampler.readPower(now: t0.addingTimeInterval(1_000)))
        XCTAssertEqual(smc.valueReads, reads, "never tries again")
        XCTAssertNotNil(sampler.readTemperature(now: t0.addingTimeInterval(1)))
        XCTAssertEqual(sampler.temperatureState, .available)
        XCTAssertEqual(sampler.powerState, .absent)
    }

    func testIOFailureMidReadGoesUnreadableThenRecovers() {
        var opens = 0
        let smc = FakeSortedSMC.apple()
        let sampler = SensorSampler(opener: { opens += 1; return .success(smc) })
        XCTAssertNotNil(sampler.readTemperature(now: t0))
        let keyReads = smc.keyReads

        smc.values["Tp00"] = .failure
        XCTAssertNil(sampler.readTemperature(now: t0.addingTimeInterval(1)))
        XCTAssertEqual(sampler.temperatureState, .unreadable)
        XCTAssertGreaterThan(smc.closed, 0, "a broken connection is closed")
        XCTAssertNil(sampler.readTemperature(now: t0.addingTimeInterval(2)), "still backing off (2 s)")
        XCTAssertEqual(opens, 1)

        // Fails again at the end of the first delay: the next one is longer (4 s).
        XCTAssertNil(sampler.readTemperature(now: t0.addingTimeInterval(3)))
        XCTAssertEqual(opens, 2)
        XCTAssertNil(sampler.readTemperature(now: t0.addingTimeInterval(6)))
        XCTAssertEqual(opens, 2)

        smc.values["Tp00"] = .value(60)
        XCTAssertNotNil(sampler.readTemperature(now: t0.addingTimeInterval(7)))
        XCTAssertEqual(opens, 3)
        XCTAssertEqual(sampler.temperatureState, .available)
        XCTAssertEqual(smc.keyReads, keyReads, "no new discovery after a reconnect")
    }

    func testBackoffGrowsThenIsCappedAtOneMinute() {
        let smc = FakeSortedSMC.apple()
        smc.values["PSTR"] = .failure
        var opens = 0
        let sampler = SensorSampler(opener: { opens += 1; return .success(smc) })
        for second in 0...200 { XCTAssertNil(sampler.readPower(now: t0.addingTimeInterval(Double(second)))) }
        // Attempts at 0, 2, 6, 14, 30, 62 s (2, 4, 8, 16, 32 s apart), then every 60 s: 122, 182.
        XCTAssertEqual(opens, 8)
        XCTAssertEqual(sampler.powerState, .unreadable)
    }

    func testPowerOutOfRangeIsNilWithoutChangingState() {
        let smc = FakeSortedSMC.apple()
        let sampler = SensorSampler(opener: { .success(smc) })
        smc.values["PSTR"] = .value(0)
        XCTAssertNil(sampler.readPower(now: t0))
        XCTAssertEqual(sampler.powerState, .unknown)
        smc.values["PSTR"] = .value(47.2)
        XCTAssertEqual(sampler.readPower(now: t0), 47.2)
        XCTAssertEqual(sampler.powerState, .available)
        for junk in [0, -3e8, 2000, 9e9] {
            smc.values["PSTR"] = .value(junk)
            XCTAssertNil(sampler.readPower(now: t0))
            XCTAssertEqual(sampler.powerState, .available)
        }
    }

    func testPowerFailureIsUnreadableThenRecovers() {
        let smc = FakeSortedSMC.apple()
        let sampler = SensorSampler(opener: { .success(smc) })
        XCTAssertEqual(sampler.readPower(now: t0), 47.2)
        smc.values["PSTR"] = .failure
        XCTAssertNil(sampler.readPower(now: t0.addingTimeInterval(1)))
        XCTAssertEqual(sampler.powerState, .unreadable)
        smc.values["PSTR"] = .value(30)
        XCTAssertNil(sampler.readPower(now: t0.addingTimeInterval(2)), "backing off")
        XCTAssertEqual(sampler.readPower(now: t0.addingTimeInterval(4)), 30)
        XCTAssertEqual(sampler.powerState, .available)
    }

    func testTransientDiscoveryFailureIsUnreadableNotAbsent() {
        let smc = FakeSortedSMC.apple()
        smc.countFails = true
        let sampler = SensorSampler(opener: { .success(smc) })
        XCTAssertNil(sampler.readTemperature(now: t0))
        XCTAssertEqual(sampler.temperatureState, .unreadable)
        smc.countFails = false
        smc.keyReadsFail = true
        XCTAssertNil(sampler.readTemperature(now: t0.addingTimeInterval(3)))
        XCTAssertEqual(sampler.temperatureState, .unreadable)
        smc.keyReadsFail = false
        XCTAssertNotNil(sampler.readTemperature(now: t0.addingTimeInterval(10)))
        XCTAssertEqual(sampler.temperatureState, .available)
    }

    func testAReaderWithoutKeyEnumerationIsUnreadable() {
        let sampler = SensorSampler(opener: { .success(FakeSMC(["Tp00": .value(70)])) })
        XCTAssertNil(sampler.readTemperature(now: t0))
        XCTAssertEqual(sampler.temperatureState, .unreadable)
    }

    func testOpenFailureMarksBothUnreadableThenRecovers() {
        var canOpen = false
        var opens = 0
        let smc = FakeSortedSMC.apple()
        let sampler = SensorSampler(opener: {
            opens += 1
            return canOpen ? .success(smc) : .failure(SMCOpenError(code: 1, step: "test"))
        })
        XCTAssertNil(sampler.readTemperature(now: t0))
        XCTAssertEqual(sampler.temperatureState, .unreadable)
        XCTAssertEqual(sampler.powerState, .unreadable)
        XCTAssertNil(sampler.readPower(now: t0.addingTimeInterval(1)))
        XCTAssertEqual(opens, 1)
        canOpen = true
        XCTAssertNotNil(sampler.readPower(now: t0.addingTimeInterval(3)))
        XCTAssertNotNil(sampler.readTemperature(now: t0.addingTimeInterval(3)))
        XCTAssertEqual(opens, 2)
    }

    func testProbeFillsBothStatesAndKeepsTheConnection() {
        let smc = FakeSortedSMC.apple()
        let sampler = SensorSampler(opener: { .success(smc) })
        sampler.probe(now: t0)
        XCTAssertEqual(sampler.temperatureState, .available)
        XCTAssertEqual(sampler.powerState, .available)
        XCTAssertEqual(sampler.sensors, TemperatureSensors(gpu: true, battery: true))
        XCTAssertEqual(smc.closed, 0)
        sampler.close()
        XCTAssertEqual(smc.closed, 1)
    }

    func testProbeOnAMacWithNoSensorsFindsBothAbsent() {
        let smc = FakeSortedSMC(["FNum": .value(0), "A000": .value(1)])
        let sampler = SensorSampler(opener: { .success(smc) })
        sampler.probe(now: t0)
        XCTAssertEqual(sampler.temperatureState, .absent)
        XCTAssertEqual(sampler.powerState, .absent)
    }

    func testIntelReadsTheTCKeysOnly() {
        let smc = FakeSortedSMC(["TC0P": .value(55), "TC1C": .value(60), "Tp00": .value(99), "TG0D": .value(40),
                                 "TB0T": .value(30), "PSTR": .value(8)])
        let sampler = SensorSampler(opener: { .success(smc) }, intel: true)
        let reading = sampler.readTemperature(now: t0)
        XCTAssertEqual(reading?.cpu, 57.5)
        XCTAssertEqual(reading?.battery, 30)
        XCTAssertNil(reading?.gpu, "Intel GPU keys are uppercase and not read")
    }

    func testM3KeepsItsPerformanceCoresInTf() {
        let smc = FakeSortedSMC(["Te05": .value(50), "Tf04": .value(60), "Tf09": .value(70)])
        let sampler = SensorSampler(opener: { .success(smc) })
        XCTAssertEqual(sampler.readTemperature(now: t0)?.cpu, 60)
    }
}

// MARK: - Network

final class NetworkSamplerTests: XCTestCase {
    private func ifinfo(index: UInt16, type: Int32, flags: Int32, received: UInt64, sent: UInt64) -> [UInt8] {
        var message = if_msghdr2()
        message.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        message.ifm_version = UInt8(RTM_VERSION)
        message.ifm_type = UInt8(RTM_IFINFO2)
        message.ifm_flags = flags
        message.ifm_index = index
        message.ifm_data.ifi_type = UInt8(type)
        message.ifm_data.ifi_ibytes = received
        message.ifm_data.ifi_obytes = sent
        return withUnsafeBytes(of: &message) { Array($0) }
    }

    /// Any other routing message (address added…), `length` bytes long.
    private func other(length: Int, type: Int32 = RTM_NEWADDR) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = UInt8(length & 0xFF)
        bytes[1] = UInt8(length >> 8)
        bytes[2] = UInt8(RTM_VERSION)
        bytes[3] = UInt8(type)
        return bytes
    }

    private func parse(_ bytes: [UInt8]) -> [UInt16: InterfaceCounters] {
        bytes.withUnsafeBytes { NetworkSampler.parse($0) }
    }

    private let up = IFF_UP | IFF_BROADCAST | IFF_RUNNING

    func testOnlyEthernetTypeInterfacesCount() {
        let big: UInt64 = 5_000_000_000_000   // beyond 32 bits
        let bytes = ifinfo(index: 1, type: IFT_LOOP, flags: up | IFF_LOOPBACK, received: 111, sent: 222)
            + other(length: 28)                // misaligns what follows
            + ifinfo(index: 4, type: IFT_ETHER, flags: up, received: big, sent: 7_000)
            + ifinfo(index: 15, type: IFT_OTHER, flags: up, received: 333, sent: 444)    // utun
            + other(length: 24, type: RTM_IFINFO)
            + ifinfo(index: 20, type: IFT_BRIDGE, flags: up, received: 555, sent: 666)
            + ifinfo(index: 5, type: IFT_ETHER, flags: up | IFF_LOOPBACK, received: 777, sent: 888)
            + ifinfo(index: 6, type: IFT_ETHER, flags: up, received: 10, sent: 20)
        XCTAssertEqual(parse(bytes), [4: InterfaceCounters(received: big, sent: 7_000),
                                      6: InterfaceCounters(received: 10, sent: 20)])
    }

    func testMalformedBuffersNeverCrashOrLoop() {
        let one = ifinfo(index: 4, type: IFT_ETHER, flags: up, received: 1, sent: 2)
        XCTAssertEqual(parse([]), [:])
        XCTAssertEqual(parse([UInt8](repeating: 0, count: 200)), [:], "length 0 stops the walk")
        XCTAssertEqual(parse(Array(one.dropLast(10))), [:], "a cut message is ignored")
        XCTAssertEqual(parse(one + [1, 2, 3]), [4: InterfaceCounters(received: 1, sent: 2)])
        var short = other(length: 20, type: RTM_IFINFO2)    // IFINFO2 too small to be one
        short[0] = 20
        XCTAssertEqual(parse(short + one), [4: InterfaceCounters(received: 1, sent: 2)])
    }

    func testRatesSumTheDeltasPerSecond() {
        let before = [4: InterfaceCounters(received: 1_000, sent: 500), 6: InterfaceCounters(received: 0, sent: 0)]
            .reduce(into: [UInt16: InterfaceCounters]()) { $0[UInt16($1.key)] = $1.value }
        let after = [4: InterfaceCounters(received: 3_000, sent: 1_500), 6: InterfaceCounters(received: 1_000, sent: 100)]
            .reduce(into: [UInt16: InterfaceCounters]()) { $0[UInt16($1.key)] = $1.value }
        XCTAssertEqual(NetworkSampler.rates(previous: before, current: after, seconds: 2),
                       NetworkRates(download: 1_500, upload: 550))
    }

    func testRatesIgnoreRegressionsNewAndGoneInterfaces() {
        let before: [UInt16: InterfaceCounters] = [4: .init(received: 5_000, sent: 1_000),
                                                    9: .init(received: 10, sent: 10)]
        let after: [UInt16: InterfaceCounters] = [4: .init(received: 100, sent: 3_000),    // download counter went back
                                                   12: .init(received: 9_999, sent: 9_999)] // new, 9 is gone
        XCTAssertEqual(NetworkSampler.rates(previous: before, current: after, seconds: 1),
                       NetworkRates(download: 0, upload: 2_000))
        XCTAssertEqual(NetworkSampler.rates(previous: [:], current: after, seconds: 1),
                       NetworkRates(download: 0, upload: 0))
    }

    func testRatesNeedPositiveTime() {
        let counters: [UInt16: InterfaceCounters] = [4: .init(received: 1, sent: 1)]
        XCTAssertNil(NetworkSampler.rates(previous: counters, current: counters, seconds: 0))
        XCTAssertNil(NetworkSampler.rates(previous: counters, current: counters, seconds: -1))
        XCTAssertNil(NetworkSampler.rates(previous: counters, current: counters, seconds: .nan))
    }
}

// MARK: - Formatting

final class SensorFormatTests: XCTestCase {
    func testTemperature() {
        XCTAssertEqual(Format.degrees(73.4), "73°")
        XCTAssertEqual(Format.degrees(72.5), "73°")
        XCTAssertEqual(Format.degrees(-4), "0°")
        XCTAssertEqual(Format.degrees(1_000), "199°")
        XCTAssertEqual(Format.degrees(.nan), "0°")
        XCTAssertEqual(Format.celsius(73.4), "73 °C")
    }

    func testPower() {
        XCTAssertEqual(Format.watts(4.2), "4,2 W")
        XCTAssertEqual(Format.watts(47.2), "47 W")
        XCTAssertEqual(Format.watts(9.94), "9,9 W")
        XCTAssertEqual(Format.watts(9.96), "10 W")
        XCTAssertEqual(Format.watts(99.6), "100 W")
        XCTAssertEqual(Format.watts(0), "0,0 W")
        XCTAssertEqual(Format.watts(-3), "0,0 W")
        XCTAssertEqual(Format.watts(.nan), "0,0 W")
        XCTAssertEqual(Format.watts(12_345), "999 W")
        XCTAssertEqual(Format.wattsNumber(4.2), "4,2")
        XCTAssertEqual(Format.wattsNumber(47.2), "47")
    }

    func testRateParts() {
        func parts(_ bytes: Double) -> String { let p = Format.rateParts(bytes); return "\(p.value)|\(p.unit)" }
        XCTAssertEqual(parts(0), "0|KB/s")
        XCTAssertEqual(parts(40), "0|KB/s")                      // 0,04 KB/s
        XCTAssertEqual(parts(100), "0,1|KB/s")
        XCTAssertEqual(parts(1_024), "1,0|KB/s")
        XCTAssertEqual(parts(9.94 * 1_024), "9,9|KB/s")
        XCTAssertEqual(parts(9.96 * 1_024), "10|KB/s")
        XCTAssertEqual(parts(340 * 1_024), "340|KB/s")
        XCTAssertEqual(parts(999.4 * 1_024), "999|KB/s")
        XCTAssertEqual(parts(999.6 * 1_024), "1,0|MB/s")
        XCTAssertEqual(parts(1.2 * 1_048_576), "1,2|MB/s")
        XCTAssertEqual(parts(55 * 1_048_576), "55|MB/s")
        XCTAssertEqual(parts(999.6 * 1_048_576), "1,0|GB/s")
        XCTAssertEqual(parts(5 * 1_073_741_824), "5,0|GB/s")
        XCTAssertEqual(parts(2_000 * 1_073_741_824), "2000|GB/s")
        XCTAssertEqual(parts(.nan), "0|KB/s")
        XCTAssertEqual(parts(-5), "0|KB/s")
        XCTAssertEqual(parts(.infinity), "99999|GB/s")
        XCTAssertEqual(parts(1e300), "99999|GB/s")
    }

    func testRate() {
        XCTAssertEqual(Format.rate(0), "0 KB/s")
        XCTAssertEqual(Format.rate(1.2 * 1_048_576), "1,2 MB/s")
        XCTAssertEqual(Format.rate(999.6 * 1_024), "1,0 MB/s")
        XCTAssertEqual(Format.rate(340 * 1_024), "340 KB/s")
    }
}

// MARK: - Real system (sanity only)

final class RealSensorTests: XCTestCase {
    func testTemperatureAndPower() throws {
        let sampler = SensorSampler()
        defer { sampler.close() }
        guard let reading = sampler.readTemperature() else { throw XCTSkip("Sem sensores de temperatura neste ambiente") }
        XCTAssertTrue(TemperatureMath.isPlausible(reading.cpu), "CPU \(reading.cpu) °C")
        if let gpu = reading.gpu { XCTAssertTrue(TemperatureMath.isPlausible(gpu)) }
        if let battery = reading.battery { XCTAssertTrue(TemperatureMath.isPlausible(battery)) }
        XCTAssertEqual(sampler.temperatureState, .available)
        guard let watts = sampler.readPower() else { throw XCTSkip("Sem leitura de energia neste ambiente") }
        XCTAssertGreaterThan(watts, 0)
        XCTAssertLessThan(watts, 2000)
    }

    func testNetworkCounters() throws {
        XCTAssertNotNil(NetworkSampler.read())
    }
}
