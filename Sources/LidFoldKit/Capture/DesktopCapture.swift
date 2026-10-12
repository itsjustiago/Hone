// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import AppKit
import CoreMedia
import OSLog
import ScreenCaptureKit

/// What can go wrong before a stream exists (the text reaches the user, so PT-PT).
/// Anything the system throws while starting is passed through untouched.
struct CaptureError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Live pixels of the built-in display for the fold overlay, via ScreenCaptureKit.
///
/// It never asks for permission: SCShareableContent would trigger the system
/// prompt, so the owner checks `CGPreflightScreenCaptureAccess()` before `start`.
/// The stream is alive only between `start` and `stop`; the owner keeps that
/// window as short as the lid movement it serves, because the system shows its
/// recording indicator for as long as a stream runs.
final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let frames = FrameStore()
    private let logger = Logger(subsystem: "com.tiagof.hone", category: "lidfold-capture")
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "hone.lidfold.frames", qos: .userInteractive)
    private var generation = 0
    private var starting = false
    private var cachedDisplays: [CGDirectDisplayID: SCDisplay] = [:]
    // This identity belongs to our process, not a window or Space, so every new
    // stream excludes us and the overlay can never be captured recursively.
    private var ownApplication: SCRunningApplication?
    var onFailure: ((String) -> Void)?
    var onUnavailable: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    var isRunning: Bool { stream != nil || starting }

    @MainActor private func refreshAvailableContent() async throws -> SCShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        if let own = content.applications.first(where: { $0.processID == getpid() }) { ownApplication = own }
        cachedDisplays = Dictionary(content.displays.map { ($0.displayID, $0) }, uniquingKeysWith: { first, _ in first })
        return content
    }

    /// Display topology changed: the cached SCDisplay objects may be stale.
    @MainActor func invalidateDisplayCache() { cachedDisplays.removeAll() }

    @MainActor func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        guard !isRunning else { return }
        generation += 1
        let token = generation
        starting = true
        defer { if token == generation { starting = false } }
        var forceRefresh = cachedDisplays[displayID] == nil || ownApplication == nil
        for attempt in 0..<2 {
            let usedCache = !forceRefresh
            if forceRefresh {
                do { _ = try await refreshAvailableContent() }
                catch { guard token == generation else { return }; throw error }
            }
            guard token == generation else { return }
            guard let display = cachedDisplays[displayID] else {
                throw CaptureError("O ecrã integrado não está disponível.")
            }
            // Exclude our own application explicitly, avoiding recursive capture of the overlay.
            guard let ownApplication else { throw CaptureError("Não foi possível excluir o Hone da captura com segurança.") }
            let filter = SCContentFilter(display: display, excludingApplications: [ownApplication], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = width; config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(1, fps)))
            config.queueDepth = 3
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false
            config.colorSpaceName = CGColorSpace.sRGB
            config.scalesToFit = true
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                stream = newStream
                frames.acceptStream(ObjectIdentifier(newStream))
                try await newStream.startCapture()
                if token == generation {
                    logger.notice("Live screen stream started (cached display: \(usedCache, privacy: .public)).")
                } else { try? await newStream.stopCapture() }
                return
            } catch {
                guard token == generation else { return }
                if stream === newStream { stream = nil; frames.invalidateStream() }
                if usedCache && attempt == 0 {
                    // A cached SCDisplay can go stale; refresh the list once and retry.
                    cachedDisplays.removeValue(forKey: displayID)
                    forceRefresh = true
                    continue
                }
                throw error
            }
        }
    }

    @MainActor func stop() {
        generation += 1; starting = false
        let previous = stream; stream = nil
        frames.invalidateStream()
        if let previous { Task { try? await previous.stopCapture() } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        guard let rawStatus = attachments?.first?[.status] as? Int, let status = SCFrameStatus(rawValue: rawStatus) else { return }
        let identity = ObjectIdentifier(stream)
        if status == .complete, let buffer = sampleBuffer.imageBuffer {
            // No per-frame main-queue block or buffer backlog. Identity and put
            // are atomic with stop(), so old callbacks cannot resurrect frames.
            if frames.put(buffer, from: identity) == true {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.stream === stream else { return }
                    self.onFirstFrame?()
                }
            }
        } else if status == .blank || status == .suspended || status == .stopped {
            if frames.clear(from: identity) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.stream === stream else { return }
                    self.onUnavailable?()
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil; self.frames.invalidateStream()
            self.onFailure?(error.localizedDescription)
        }
    }
}
