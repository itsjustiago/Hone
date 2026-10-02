import XCTest
import SwiftUI
import AppKit
@testable import StatsKit

/// The popover resizes between tabs while it animates, so the hosting view is
/// often taller or shorter than the panel. The panel must stay pinned to the top
/// (otherwise SwiftUI centres it and the tiles slide). Rendered off-screen in a
/// borderless window that is never shown.
@MainActor
final class PanelLayoutTests: XCTestCase {
    private func makeHost(_ metric: Metric) -> NSHostingView<AnyView> {
        let settings = StatsSettings(store: UserDefaults(suiteName: "layout-\(UUID().uuidString)")!)
        let monitor = SystemMonitor(settings: settings)
        var snapshot = StatsSnapshot()
        snapshot.cpu = CPUUsage(total: 0.12, user: 0.08, system: 0.04, idle: 0.88, perCore: Array(repeating: 0.3, count: 15))
        snapshot.memory = MemorySampler.breakdown(
            counters: VMCounters(internalPages: 634_842, purgeable: 6_718, wired: 219_287,
                                 compressor: 414_007, external: 239_276, free: 5_646),
            pageSize: 16_384, total: 25_769_803_776)
        snapshot.gpu = GPUReading(device: 0.03, renderer: 0.03, tiler: 0.01, inUseMemory: 1 << 30, name: "GPU", cores: 20)
        snapshot.fans = [FanReading(name: "Ventoinha 1", rpm: 3417, minRPM: 2317, maxRPM: 7826)]
        monitor.snapshot = snapshot
        monitor.fanCount = 1
        // Every metric on and available (the real GPU/fan state is irrelevant here).
        monitor.unavailable = [:]
        let state = PanelState()
        state.selected = metric
        // The panel paints its own black canvas and forces the dark scheme.
        let panel = StatsPanel(monitor: monitor, state: state, processes: TopProcessesModel(),
                               onSettings: {}, onBack: nil, onToggleOwnIcon: {})
        return NSHostingView(rootView: AnyView(panel))
    }

    private func idealHeight(_ metric: Metric) -> CGFloat { makeHost(metric).fittingSize.height }

    /// y (pt, from the top) of the first green pixel in the left 100 pt: the header's mascot.
    private func iconTop(_ metric: Metric, frameHeight: CGFloat) throws -> CGFloat {
        let host = makeHost(metric)
        let width = host.fittingSize.width
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: frameHeight),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: frameHeight)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / width
        for y in 0..<rep.pixelsHigh {
            for x in 0..<Int(100 * scale) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.greenComponent > 0.55, c.greenComponent - c.redComponent > 0.25,
                   c.greenComponent - c.blueComponent > 0.15 { return CGFloat(y) / scale }
            }
        }
        return -1
    }

    func testIdealHeightPerTab() {
        XCTAssertEqual(idealHeight(.cpu), idealHeight(.memory), "CPU and Memory share a height")
        XCTAssertEqual(idealHeight(.gpu), idealHeight(.cpu), "GPU has a list too and shares the height")
        XCTAssertLessThan(idealHeight(.fan), idealHeight(.cpu), "fans keep their natural height")
    }

    func testPanelStaysPinnedToTheTop() throws {
        let tall = idealHeight(.cpu), short = idealHeight(.fan)
        let reference = try iconTop(.fan, frameHeight: short)
        XCTAssertGreaterThan(reference, 0)
        // Host taller than the content (popover growing)…
        XCTAssertEqual(try iconTop(.fan, frameHeight: tall), reference)
        // …and shorter than the content (popover shrinking): clipped at the bottom, not the top.
        XCTAssertEqual(try iconTop(.cpu, frameHeight: short), reference)
    }
}
