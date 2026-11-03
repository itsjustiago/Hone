import Foundation
import HandKit

/// Records the raw hand frames for a short while and saves them as JSON, so a real
/// session can be replayed in the engine's tests. Frames are kept in memory until
/// the recording ends; nothing about the camera image is stored, only the joints.
@MainActor
@Observable
final class HandRecorder {
    /// A recording stops by itself after this long.
    static let maxDuration: TimeInterval = 30

    private(set) var isRecording = false
    /// Whole seconds left in the recording; changes once a second, not once a frame.
    private(set) var secondsLeft = Int(HandRecorder.maxDuration)
    /// Where the last finished recording went; nil if none, or if saving failed.
    private(set) var lastFile: URL?
    /// The last recording had frames but the file couldn't be written.
    private(set) var saveFailed = false

    /// Called once when a recording ends, by `stop()` or by the 30 s limit.
    @ObservationIgnored var onStop: ((URL?) -> Void)?

    @ObservationIgnored private var frames: [HandFrame] = []
    @ObservationIgnored private var t0: TimeInterval?
    @ObservationIgnored private var timer: Timer?

    func start() {
        guard !isRecording else { return }
        frames = []
        frames.reserveCapacity(Int(Self.maxDuration * 31))
        t0 = nil
        secondsLeft = Int(Self.maxDuration)
        lastFile = nil
        saveFailed = false
        isRecording = true
        let timer = Timer(timeInterval: Self.maxDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.stop() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Ends the recording and writes the file. Returns nil when nothing was recording
    /// or the file couldn't be written.
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        timer?.invalidate()
        timer = nil
        let url = save(frames)
        saveFailed = url == nil && !frames.isEmpty
        frames = []
        t0 = nil
        lastFile = url
        onStop?(url)
        return url
    }

    /// `t` is absolute (the tracker's clock); it is stored relative to the first frame.
    func add(t: TimeInterval, hand: HandLandmarks?) {
        guard isRecording else { return }
        let start = t0 ?? t
        t0 = start
        let left = max(0, Int((Self.maxDuration - (t - start)).rounded(.up)))
        if left != secondsLeft { secondsLeft = left }
        frames.append(HandFrame(t: t - start, hand: hand))
    }

    // MARK: File

    private static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Hone/HandMouse/recordings", isDirectory: true)
    }

    private func save(_ frames: [HandFrame]) -> URL? {
        guard !frames.isEmpty, let folder = Self.folder else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = folder.appendingPathComponent(formatter.string(from: Date())).appendingPathExtension("json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(frames).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
