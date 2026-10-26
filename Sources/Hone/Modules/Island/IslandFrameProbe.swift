import AppKit
import QuartzCore
import SwiftUI

/// Dev tool: how smoothly the island animates, measured with no one watching. Run
/// `HONE_ISLAND_FRAME_PROBE=<file> .build/release/Hone` (see `HoneMain`). Like the
/// preview renderer it exits before anything else runs: no app delegate, no modules,
/// no music source, no defaults written, so it is safe beside the Hone that's running.
///
/// It builds a real `IslandPanel` over the built-in notch, see-through and
/// click-through (`probeAlpha`), and plays a fixed script on fake tracks: compact,
/// peek, compact, expanded, a new track, compact, hidden; once to warm up, then
/// three times. For each step it records
/// - the frames SwiftUI drew: every new outline `NotchShape` is asked for;
/// - the screens' ticks: a display link per screen at its top rate, off the main
///   thread. The notch's screen is the one that counts; the others tell whose clock
///   woke a frame;
/// - the main thread's busy time per run-loop turn, from waking to going to sleep.
/// Each step's raw data and figures are appended to the file as it goes, a table per
/// transition at the end, and the process exits 0.
///
/// `HONE_ISLAND_FRAME_PROBE_ALPHA` sets the window's opacity (0 by default: nothing
/// shows). `HONE_ISLAND_FRAME_PROBE_FLAGS`, comma-separated: `notrack` draws the shape
/// alone, `paused` shows a paused track (no equaliser, no ticking progress).
@MainActor
final class IslandFrameProbe {
    static func run(writingTo url: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Whatever happens on the main thread, the probe never outlives this.
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { exit(2) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let file = try? FileHandle(forWritingTo: url) else {
            FileHandle.standardError.write(Data("probe: can't write \(url.path)\n".utf8))
            exit(1)
        }
        guard let geometry = NotchGeometry.current(),
              let screen = NSScreen.screens.first(where: { NotchGeometry(screen: $0) == geometry }) else {
            file.write(Data("probe: no notch on a built-in screen\n".utf8))
            exit(1)
        }
        let probe = IslandFrameProbe(file: file, geometry: geometry, screen: screen)
        current = probe
        DispatchQueue.main.async { probe.start() }
        app.run()
        exit(0)
    }

    private static var current: IslandFrameProbe?

    // MARK: Setup

    private enum Step {
        case show(IslandPresentation)
        case newTrack
    }

    private static let script: [(String, Step)] = [
        ("hidden→compact", .show(.compact)),
        ("compact→peek", .show(.peek)),
        ("peek→compact", .show(.compact)),
        ("compact→expanded", .show(.expanded)),
        ("expanded: new track", .newTrack),
        ("expanded→compact", .show(.compact)),
        ("compact→hidden", .show(.hidden)),
    ]
    private static let rounds = 3
    /// Each step waits past the panel's own fallback settle, so the frame cut is in it.
    private static let hold = IslandMotion.settleFallback + 0.25
    /// Between steps, for writing: no step's window holds the probe's own work.
    private static let gap: TimeInterval = 0.3
    private static let environment = ProcessInfo.processInfo.environment
    private static let alpha = CGFloat(Double(environment["HONE_ISLAND_FRAME_PROBE_ALPHA"] ?? "") ?? 0)
    private static let flags = Set((environment["HONE_ISLAND_FRAME_PROBE_FLAGS"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })

    private let file: FileHandle
    private let geometry: NotchGeometry
    private let screen: NSScreen
    private let panel = IslandPanel(actions: IslandActions())
    private let recorder = Recorder()
    private var tracks: [(NowPlayingTrack, IslandArtwork?)] = []
    private var trackIndex = 0
    private var results: [Result] = []
    private var tickLinks: [CADisplayLink] = []

    private init(file: FileHandle, geometry: NotchGeometry, screen: NSScreen) {
        self.file = file
        self.geometry = geometry
        self.screen = screen
    }

    private func start() {
        let playing = !Self.flags.contains("paused")
        func track(_ title: String, _ from: NSColor, _ to: NSColor) -> (NowPlayingTrack, IslandArtwork?) {
            var track = PreviewRenderer.fakeTrack(title: title, artist: "M83", duration: 243, elapsed: 83)
            track.isPlaying = playing
            return (track, IslandArtwork.make(from: PreviewRenderer.fakeCover(from, to)))
        }
        tracks = [
            track("Midnight City", NSColor(srgbRed: 0.98, green: 0.52, blue: 0.24, alpha: 1),
                  NSColor(srgbRed: 0.62, green: 0.16, blue: 0.52, alpha: 1)),
            track("Outro", NSColor(srgbRed: 0.10, green: 0.30, blue: 0.55, alpha: 1),
                  NSColor(srgbRed: 0.03, green: 0.06, blue: 0.16, alpha: 1)),
        ]
        panel.probeAlpha = Self.alpha
        fill(tracks[0])

        NotchShape.probe = { [recorder] rect, ear, bottom in recorder.outline(rect.size, ear, bottom) }
        startTicks()
        observeTurns()

        let screens = NSScreen.screens.map {
            "\($0.localizedName) \($0.maximumFramesPerSecond) fps" + ($0 == NSScreen.screens.first ? " (main)" : "")
        }
        write("""
            # Island frame probe, \(Date())
            notch on: \(screen.localizedName), maximumFramesPerSecond \(screen.maximumFramesPerSecond)
            screens: \(screens.joined(separator: ", "))
            notch \(geometry.notchRect.size), canvas \(geometry.canvas.size)
            reduce motion: \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), \
            window alpha \(Self.alpha), flags: \(Self.flags.sorted().joined(separator: ",")), \
            hold \(fmt(Self.hold * 1000)) ms
            raw: t in ms from the step's start; outline = w×h ear bottom; turn = start+busy

            """)

        // Warm-up: the window is made and ordered front; round 0 draws everything once.
        panel.show(.hidden, on: geometry, keepsWindow: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            let window = NSApp.windows.first { $0 is IslandWindow }
            write("window: occlusion visible \(window?.occlusionState.contains(.visible) ?? false), "
                  + "alpha \(window?.alphaValue ?? -1), ignoresMouse \(window?.ignoresMouseEvents ?? false), "
                  + "screen \(window?.screen?.localizedName ?? "-")\n\n")
            perform(round: 0, index: 0)
        }
    }

    private func fill(_ track: (NowPlayingTrack, IslandArtwork?)) {
        let model = panel.model
        model.track = Self.flags.contains("notrack") ? nil : track.0
        model.artwork = track.1
        model.appName = "Música"
    }

    /// Every screen's ticks, on a thread of their own so the main thread only does
    /// what the island makes it do.
    private func startTicks() {
        tickLinks = NSScreen.screens.map { other in
            let ticker = Ticker(recorder: recorder, screen: other == screen ? nil : other.localizedName)
            let link = other.displayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
            let top = Float(other.maximumFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: top, maximum: top, preferred: top)
            return link
        }
        let links = tickLinks
        let thread = Thread {
            for link in links { link.add(to: .current, forMode: .common) }
            RunLoop.current.run()
        }
        thread.name = "probe ticks"
        thread.start()
    }

    /// One turn = from waking up to going back to sleep, so it holds the CA commit too.
    private func observeTurns() {
        let recorder = recorder
        var woke = 0.0
        let wake = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            woke = CACurrentMediaTime()
        }
        let sleep = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            guard woke > 0 else { return }
            recorder.turn(start: woke, end: CACurrentMediaTime())
            woke = 0
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), sleep, .commonModes)
    }

    // MARK: The script

    private func perform(round: Int, index: Int) {
        guard round <= Self.rounds else { return finish() }
        let (label, step) = Self.script[index]
        let start = CACurrentMediaTime()
        switch step {
        case .show(let presentation):
            panel.show(presentation, on: geometry, keepsWindow: true)
        case .newTrack:
            trackIndex = (trackIndex + 1) % tracks.count
            fill(tracks[trackIndex])
        }
        let called = CACurrentMediaTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold) { [self] in
            let result = Result(label: label, round: round, start: start, called: called,
                                end: CACurrentMediaTime(), recorder: recorder)
            if round > 0 { results.append(result) }
            write(result.raw)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.gap) { [self] in
                let next = index + 1
                next < Self.script.count ? perform(round: round, index: next) : perform(round: round + 1, index: 0)
            }
        }
    }

    private func finish() {
        write("## Summary, rounds 1–\(Self.rounds) (warm-up round 0 left out)\n" + Result.legend
              + Result.table(results))
        NotchShape.probe = nil
        tickLinks.forEach { $0.invalidate() }
        panel.close()
        try? file.close()
        exit(0)
    }

    private func write(_ text: String) {
        file.write(Data(text.utf8))
    }
}

// MARK: - Recording

/// Everything the probe hears, from the main thread, the tick thread and wherever
/// SwiftUI asks for the outline.
private final class Recorder: @unchecked Sendable {
    struct Outline {
        let time: Double
        let size: CGSize
        let ear: CGFloat
        let bottom: CGFloat
        let onMain: Bool
    }
    struct Turn {
        let start: Double
        let end: Double
        var busy: Double { end - start }
    }
    struct Snapshot {
        var outlines: [Outline]
        /// The notch's screen.
        var ticks: [Double]
        /// The other screens', by name.
        var otherTicks: [String: [Double]]
        var turns: [Turn]
    }

    private let lock = NSLock()
    private var outlines: [Outline] = []
    private var ticks: [Double] = []
    private var otherTicks: [String: [Double]] = [:]
    private var turns: [Turn] = []

    /// The fill, the clip and the hit shape ask for the same outline in one frame:
    /// only a new one counts.
    func outline(_ size: CGSize, _ ear: CGFloat, _ bottom: CGFloat) {
        let now = CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        if let last = outlines.last, last.size == size, last.ear == ear, last.bottom == bottom { return }
        outlines.append(Outline(time: now, size: size, ear: ear, bottom: bottom, onMain: Thread.isMainThread))
    }

    func tick(_ time: Double, screen: String?) {
        lock.lock()
        if let screen { otherTicks[screen, default: []].append(time) } else { ticks.append(time) }
        lock.unlock()
    }

    func turn(start: Double, end: Double) {
        lock.lock()
        turns.append(Turn(start: start, end: end))
        lock.unlock()
    }

    func snapshot(from start: Double, to end: Double) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(outlines: outlines.filter { $0.time >= start && $0.time <= end },
                        ticks: ticks.filter { $0 >= start && $0 <= end },
                        otherTicks: otherTicks.mapValues { $0.filter { $0 >= start && $0 <= end } },
                        turns: turns.filter { $0.end >= start && $0.start <= end })
    }
}

private final class Ticker: NSObject {
    let recorder: Recorder
    /// `nil` for the notch's screen.
    let screen: String?
    init(recorder: Recorder, screen: String?) {
        self.recorder = recorder
        self.screen = screen
    }
    @objc func tick(_ link: CADisplayLink) { recorder.tick(CACurrentMediaTime(), screen: screen) }
}

// MARK: - Figures

private struct Result {
    let label: String
    let round: Int
    /// The `show` call (or the model change) itself.
    let callMs: Double
    /// From the call to the first new outline.
    let firstFrameMs: Double?
    let frames: Int
    let fps: Double?
    let p50: Double?
    let p95: Double?
    let maxInterval: Double?
    let tickMs: Double?
    /// Tick-to-tick slots inside the motion with no new outline (a repeated frame)…
    let missedPct: Double?
    /// …and with two or more (all but the last are thrown away).
    let doublePct: Double?
    /// How far apart in time the outlines that reach the glass (the last one of each
    /// slot) were sampled. Even motion is one tick apart at both ends.
    let shownP5: Double?
    let shownP95: Double?
    /// Outlines that did not come within a few ms of a notch-screen tick: frames
    /// woken by some other clock (another screen's, a timer). A heuristic: the other
    /// screens' ticks are in the raw data to check it against.
    let offClockPct: Double?
    let maxTurnMs: Double
    let busyPct: Double
    let turnsOverTick: Int
    let raw: String

    init(label: String, round: Int, start: Double, called: Double, end: Double, recorder: Recorder) {
        let data = recorder.snapshot(from: start, to: end)
        let ticks = data.ticks, turns = data.turns
        let times = data.outlines.map(\.time)
        self.label = label
        self.round = round
        callMs = (called - start) * 1000
        frames = times.count
        let intervals = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }
        let tick = Self.percentile(zip(ticks.dropFirst(), ticks).map { ($0 - $1) * 1000 }, 0.5)
        tickMs = tick
        firstFrameMs = times.first.map { ($0 - start) * 1000 }
        let spanMs = ((times.last ?? start) - (times.first ?? start)) * 1000
        fps = frames > 1 && spanMs > 0 ? Double(frames - 1) / (spanMs / 1000) : nil
        p50 = Self.percentile(intervals, 0.5)
        p95 = Self.percentile(intervals, 0.95)
        maxInterval = intervals.max()

        // Each tick-to-tick slot inside the motion: how many new outlines landed in it?
        var missed: Double?, double: Double?, shownP5: Double?, shownP95: Double?
        if let first = times.first, let last = times.last, last > first {
            let inside = ticks.filter { $0 >= first && $0 <= last }
            let slots = Array(zip(inside, inside.dropFirst()))
            let landed = slots.map { slot in times.filter { $0 > slot.0 && $0 <= slot.1 } }
            if !slots.isEmpty {
                missed = Double(landed.filter(\.isEmpty).count) / Double(slots.count) * 100
                double = Double(landed.filter { $0.count > 1 }.count) / Double(slots.count) * 100
            }
            let shown = landed.compactMap(\.last)
            let spacing = zip(shown.dropFirst(), shown).map { ($0 - $1) * 1000 }
            shownP5 = Self.percentile(spacing, 0.05)
            shownP95 = Self.percentile(spacing, 0.95)
        }
        missedPct = missed
        doublePct = double
        self.shownP5 = shownP5
        self.shownP95 = shownP95

        let wakeWindow = 0.003
        offClockPct = frames > 0 && !ticks.isEmpty
            ? Double(times.filter { time in !ticks.contains { $0 <= time && time - $0 < wakeWindow } }.count)
                / Double(frames) * 100
            : nil

        let motionEnd = times.last.map { max($0, start + 0.05) } ?? start + 0.35
        let during = turns.filter { $0.end >= start && $0.start <= motionEnd }
        maxTurnMs = (during.map(\.busy).max() ?? 0) * 1000
        busyPct = during.map(\.busy).reduce(0, +) / max(motionEnd - start, 0.001) * 100
        turnsOverTick = during.filter { $0.busy * 1000 > (tick ?? 8.33) }.count

        func ms(_ time: Double) -> String { fmt((time - start) * 1000) }
        func opt(_ value: Double?) -> String { value.map(fmt) ?? "-" }
        let offMain = data.outlines.filter { !$0.onMain }.count
        var raw = "### \(label), round \(round)\n"
        raw += "call \(fmt(callMs)) ms · first frame \(opt(firstFrameMs)) ms · frames \(frames) in \(fmt(spanMs)) ms "
            + "· fps \(opt(fps)) · interval p50 \(opt(p50)) p95 \(opt(p95)) max \(opt(maxInterval)) "
            + "· tick \(opt(tickMs)) · missed \(opt(missedPct)) % double \(opt(doublePct)) % "
            + "· shown spacing p5 \(opt(shownP5)) p95 \(opt(shownP95)) · off clock \(opt(offClockPct)) % "
            + "· max turn \(fmt(maxTurnMs)) ms · busy \(fmt(busyPct)) % · turns over a tick \(turnsOverTick)"
            + (offMain > 0 ? " · off-main outlines \(offMain)" : "") + "\n"
        raw += "outlines: " + data.outlines.map {
            "\(ms($0.time)):\(fmt($0.size.width))×\(fmt($0.size.height)) \(fmt($0.ear)) \(fmt($0.bottom))"
        }.joined(separator: ", ") + "\n"
        raw += "ticks: " + ticks.map(ms).joined(separator: " ") + "\n"
        for (name, times) in data.otherTicks.sorted(by: { $0.key < $1.key }) {
            raw += "ticks \(name): " + times.map(ms).joined(separator: " ") + "\n"
        }
        raw += "turns: " + turns.filter { $0.busy > 0.0005 }
            .map { "\(ms($0.start))+\(fmt($0.busy * 1000))" }.joined(separator: " ") + "\n\n"
        self.raw = raw
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }

    static let legend = """
        ms unless %; medians of the rounds, worst for call, max and turn. fps = new outlines
        per second; missed/double = notch-screen ticks with 0 / 2+ new outlines; shown = spacing
        of the outlines that reach the glass (even motion: one tick at both ends); off clock = not
        within 3 ms of a notch-screen tick; turn = main-thread busy time per run-loop turn.

        """

    /// One row per transition, the rounds pooled.
    static func table(_ results: [Result]) -> String {
        var labels: [String] = []
        for result in results where !labels.contains(result.label) { labels.append(result.label) }
        func median(_ values: [Double?]) -> String { percentile(values.compactMap { $0 }, 0.5).map(fmt) ?? "-" }
        func worst(_ values: [Double?]) -> String { values.compactMap { $0 }.max().map(fmt) ?? "-" }
        let header = ["transition", "n", "call", "1st", "frames", "fps", "p50", "p95", "max", "tick",
                      "missed%", "double%", "shown p5", "shown p95", "off clock%", "turn", "busy%", "turns>tick"]
        var rows = [header]
        for label in labels {
            let rs = results.filter { $0.label == label }
            rows.append([label, "\(rs.count)", worst(rs.map(\.callMs)), median(rs.map(\.firstFrameMs)),
                         median(rs.map { Double($0.frames) }), median(rs.map(\.fps)), median(rs.map(\.p50)),
                         median(rs.map(\.p95)), worst(rs.map(\.maxInterval)), median(rs.map(\.tickMs)),
                         median(rs.map(\.missedPct)), median(rs.map(\.doublePct)), median(rs.map(\.shownP5)),
                         median(rs.map(\.shownP95)), median(rs.map(\.offClockPct)), worst(rs.map(\.maxTurnMs)),
                         median(rs.map(\.busyPct)), median(rs.map { Double($0.turnsOverTick) })])
        }
        let widths = header.indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { column, cell in
                column == 0 ? cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
                    : String(repeating: " ", count: widths[column] - cell.count) + cell
            }.joined(separator: "  ")
        }.joined(separator: "\n") + "\n"
    }
}

private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }
private func fmt(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }
