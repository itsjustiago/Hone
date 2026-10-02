import XCTest
@testable import StatsKit

final class GPUProcessMathTests: XCTestCase {
    private func reading(_ uptime: UInt64, _ clients: [Int32: UInt64]) -> GPUProcessReading {
        GPUProcessReading(uptimeNanoseconds: uptime, clients: clients.mapValues { .init(name: "p", nanoseconds: $0) })
    }

    func testParseCreator() {
        XCTAssertEqual(GPUProcessMath.parseCreator("pid 411, WindowServer")?.pid, 411)
        XCTAssertEqual(GPUProcessMath.parseCreator("pid 411, WindowServer")?.name, "WindowServer")
        XCTAssertEqual(GPUProcessMath.parseCreator("pid 7, Foo, Bar")?.name, "Foo, Bar")
        XCTAssertNil(GPUProcessMath.parseCreator("WindowServer"))
        XCTAssertNil(GPUProcessMath.parseCreator("pid x, Name"))
    }

    func testAccumulatedTimeSumsEntriesAndIgnoresEmpty() {
        let usage: [[String: Any]] = [
            ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 21_083_049_815_166 as UInt64)],
            ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 1_000)],
            ["API": "Metal"],
        ]
        XCTAssertEqual(GPUProcessMath.accumulatedTime(appUsage: usage), 21_083_049_816_166)
        XCTAssertEqual(GPUProcessMath.accumulatedTime(appUsage: [[String: Any]]()), 0)
        XCTAssertEqual(GPUProcessMath.accumulatedTime(appUsage: nil), 0)
    }

    func testPercentageIsDeltaOverElapsed() {
        let a = reading(1_000_000_000, [1: 100, 2: 5_000])
        let b = reading(3_000_000_000, [1: 500_000_100, 2: 5_000])  // 0.5 s of GPU in 2 s
        let p = GPUProcessMath.percentages(previous: a, current: b)
        XCTAssertEqual(p[1] ?? -1, 25, accuracy: 1e-9)
        XCTAssertNil(p[2], "no new GPU time: left out")
    }

    func testNewClientCountsFromZero() {
        let a = reading(0, [:])
        let b = reading(1_000_000_000, [9: 300_000_000])
        XCTAssertEqual(GPUProcessMath.percentages(previous: a, current: b)[9] ?? -1, 30, accuracy: 1e-9)
    }

    func testDescendingAccumulatedIsANewBaselineAndGoneIsDropped() {
        let a = reading(0, [1: 9_000_000_000, 2: 10])
        let b = reading(1_000_000_000, [1: 1_000])  // pid 1 reused, pid 2 gone
        let p = GPUProcessMath.percentages(previous: a, current: b)
        XCTAssertTrue(p.isEmpty)
    }

    func testPercentageIsCappedAndNeedsTimeToPass() {
        let a = reading(0, [1: 0])
        XCTAssertEqual(GPUProcessMath.percentages(previous: a, current: reading(1_000, [1: 5_000]))[1], 100)
        XCTAssertTrue(GPUProcessMath.percentages(previous: a, current: reading(0, [1: 5_000])).isEmpty)
    }

    func testGroupingUsesTheOutermostApp() {
        let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)"
        let group = GPUProcessMath.group(executablePath: chrome, processName: "Google Chrome Helper (GPU)", creatorName: "x")
        XCTAssertEqual(group.name, "Google Chrome")
        XCTAssertEqual(group.bundlePath, "/Applications/Google Chrome.app")
        let main = GPUProcessMath.group(executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                                        processName: "Google Chrome", creatorName: "x")
        XCTAssertEqual(main, group, "the helper and the app share a row")
    }

    func testGroupingFallbacks() {
        let ws = GPUProcessMath.group(executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                                      processName: "WindowServer", creatorName: "Creator")
        XCTAssertEqual(ws.name, "WindowServer")
        XCTAssertNil(ws.bundlePath)
        XCTAssertEqual(GPUProcessMath.group(executablePath: nil, processName: "proc", creatorName: "Creator").name, "proc")
        XCTAssertEqual(GPUProcessMath.group(executablePath: nil, processName: nil, creatorName: "Creator").name, "Creator")
        XCTAssertEqual(GPUProcessMath.group(executablePath: "/usr/bin/x.app", processName: nil, creatorName: "C").name, "x")
    }

    func testTopAppsSumsSortsAndLimits() {
        let chrome = GPUAppGroup(key: "/A/Chrome.app", name: "Chrome", bundlePath: "/A/Chrome.app")
        var groups: [Int32: GPUAppGroup] = [1: chrome, 2: chrome]
        var shares: [Int32: Double] = [1: 10, 2: 15, 3: 20]
        groups[3] = GPUAppGroup(key: "WindowServer", name: "WindowServer", bundlePath: nil)
        for pid in 10..<16 {
            groups[Int32(pid)] = GPUAppGroup(key: "p\(pid)", name: "p\(pid)", bundlePath: nil)
            shares[Int32(pid)] = Double(pid - 9) / 10
        }
        let top = GPUProcessMath.topApps(percentages: shares, groups: groups)
        XCTAssertEqual(top.count, 5)
        XCTAssertEqual(top[0].name, "Chrome")
        XCTAssertEqual(top[0].percent, 25, accuracy: 1e-9)
        XCTAssertEqual(top[0].pid, 2, "the busiest process stands for the app")
        XCTAssertEqual(top[1].name, "WindowServer")
        XCTAssertEqual(top[2].name, "p15")
        XCTAssertEqual(GPUProcessMath.topApps(percentages: [1: 80, 2: 80], groups: [1: chrome, 2: chrome])[0].percent, 100)
    }

    func testSessionFirstReadIsOnlyABaseline() {
        var tick: UInt64 = 0
        var accumulated: UInt64 = 0
        let session = GPUUsageSession(
            read: {
                tick += 1_000_000_000
                accumulated += 250_000_000
                return GPUProcessReading(uptimeNanoseconds: tick, clients: [5: .init(name: "Foo", nanoseconds: accumulated)])
            },
            resolve: { _, creator in GPUAppGroup(key: creator, name: creator, bundlePath: nil) })
        XCTAssertNil(session.next())
        let rows = session.next()
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(rows?[0].name, "Foo")
        XCTAssertEqual(rows?[0].percent ?? -1, 25, accuracy: 1e-9)
    }
}

final class GPUProcessRealTests: XCTestCase {
    func testRealReadDoesNotCrashAndHasSaneNames() throws {
        let reading = GPUProcessSampler().read()
        if reading.clients.isEmpty { throw XCTSkip("sem acelerador ou sem AppUsage") }
        XCTAssertTrue(reading.clients.keys.allSatisfy { $0 >= 0 })
        XCTAssertTrue(reading.clients.values.allSatisfy { $0.nanoseconds > 0 })
    }
}
