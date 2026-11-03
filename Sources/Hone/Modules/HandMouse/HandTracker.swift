import AVFoundation
import CoreImage
import HandKit
import os
import Vision

/// Webcam → Vision hand pose → `HandLandmarks`. Nothing here decides what a pose
/// means; that is `HandMouseEngine`'s job. The camera only runs between `start()`
/// and `stop()`, and the preview image is only built while `wantsPreview` is true.
///
/// Threading: frames arrive on a private serial queue; the callbacks hop to the main
/// thread. If the main thread hasn't consumed the previous frame the new one is
/// dropped before Vision runs, so a stalled UI never builds a backlog.
final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // MARK: Public API (main thread)

    /// A camera's `uniqueID`; nil = the system's default video device.
    var cameraID: String?
    /// Called on main, once per processed frame. `hand` is nil when none is seen
    /// (or wrist / index tip / middle knuckle are below 0.3 confidence).
    /// `t` = `CACurrentMediaTime()` when the frame was captured.
    var onFrame: ((_ t: TimeInterval, _ hand: HandLandmarks?) -> Void)?
    /// Mirrored, ≤ 320 px wide, ≤ 15 fps; only while `wantsPreview`. Called on main.
    var onPreview: ((CGImage) -> Void)?
    /// A user-facing failure (PT-PT). Called on main.
    var onError: ((String) -> Void)?

    /// Build and deliver preview images. Zero cost while false.
    var wantsPreview: Bool {
        get { shared.withLock { $0.wantsPreview } }
        set { shared.withLock { $0.wantsPreview = newValue } }
    }

    /// Frames per second the pipeline is really processing (exponential average).
    var fps: Double { shared.withLock { $0.fps } }

    static var authorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Built-in, external and Continuity cameras.
    static func availableCameras() -> [(id: String, name: String)] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified)
        var seen = Set<String>()
        return session.devices.compactMap { device in
            seen.insert(device.uniqueID).inserted ? (device.uniqueID, device.localizedName) : nil
        }
    }

    /// Starts the camera. Without permission it reports through `onError` instead of
    /// crashing; a first-time `.notDetermined` asks the system for access.
    func start() {
        switch Self.authorization {
        case .authorized:
            launch()
        case .notDetermined:
            Task { @MainActor [weak self] in
                if await Self.requestAccess() { self?.launch() } else { self?.fail("Sem acesso à câmara") }
            }
        default:
            fail("Sem acesso à câmara")
        }
    }

    /// Stops the camera. Frames still in flight are discarded.
    func stop() {
        resetShared()
        removeObservers()
        sessionQueue.async { [weak self] in
            guard let self, let session = self.session else { return }
            self.session = nil
            self.output?.setSampleBufferDelegate(nil, queue: nil)
            self.output = nil
            session.stopRunning()
        }
    }

    // MARK: State

    private struct Shared {
        var wantsPreview = false
        /// A frame is queued for main and not yet consumed.
        var mainBusy = false
        var fps = 0.0
        var lastFrameTime: TimeInterval = 0
        /// Bumped on every start / stop; late frames of an older run are dropped.
        var generation = 0
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    /// Only touched on `sessionQueue`.
    private let sessionQueue = DispatchQueue(label: "app.hone.hand.session")
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var observers: [NSObjectProtocol] = []

    /// Only touched on `videoQueue`.
    private let videoQueue = DispatchQueue(label: "app.hone.hand.video", qos: .userInteractive)
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()
    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastPreviewTime: TimeInterval = 0

    private static let previewWidth: CGFloat = 320
    private static let previewInterval: TimeInterval = 1.0 / 15

    // MARK: Session

    private func launch() {
        removeObservers()
        let generation = resetShared()
        let id = cameraID
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Replace a previous session that is still up.
            self.session?.stopRunning()
            self.output?.setSampleBufferDelegate(nil, queue: nil)
            self.session = nil
            self.output = nil

            switch self.makeSession(cameraID: id) {
            case .success(let (session, output)):
                // A stop() that raced this start wins.
                guard self.shared.withLock({ $0.generation }) == generation else { return }
                self.session = session
                self.output = output
                DispatchQueue.main.async { [weak self] in self?.observe(session, generation: generation) }
                session.startRunning() // blocks until the camera is up
            case .failure(.message(let message)):
                // A failure of an older run must not kill the current one.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.shared.withLock({ $0.generation }) == generation else { return }
                    self.fail(message)
                }
            }
        }
    }

    /// Starts a new run: bumps the generation and clears the per-run measurements.
    @discardableResult
    private func resetShared() -> Int {
        shared.withLock { state in
            state.generation += 1
            state.fps = 0
            state.lastFrameTime = 0
            state.mainBusy = false
            return state.generation
        }
    }

    private enum SetupError: Error { case message(String) }

    private func makeSession(cameraID: String?) -> Result<(AVCaptureSession, AVCaptureVideoDataOutput), SetupError> {
        guard let device = cameraID.flatMap({ AVCaptureDevice(uniqueID: $0) })
                ?? AVCaptureDevice.default(for: .video)
        else { return .failure(.message("Não encontrei nenhuma câmara")) }

        let session = AVCaptureSession()
        session.beginConfiguration()

        // 640×480 is plenty for hand pose and keeps Vision fast; take what works.
        for preset in [AVCaptureSession.Preset.vga640x480, .medium, .high] where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
        }

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            return .failure(.message("Não consegui abrir a câmara"))
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return .failure(.message("Não consegui abrir a câmara"))
        }
        session.addOutput(output)

        // Mirroring is done in software (x → 1 − x), so the buffer must arrive plain.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        session.commitConfiguration()
        return .success((session, output))
    }

    /// Main thread. Turns a camera that dies mid-run into an error message.
    private func observe(_ session: AVCaptureSession, generation: Int) {
        guard shared.withLock({ $0.generation }) == generation else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: session, queue: .main) { [weak self] _ in
            self?.fail("A câmara parou")
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                                            object: nil, queue: .main) { [weak self] note in
            // Only if it is the camera in use.
            guard let device = note.object as? AVCaptureDevice,
                  session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device == device })
            else { return }
            self?.fail("A câmara foi desligada")
        })
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func fail(_ message: String) {
        onError?(message)
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let t = CACurrentMediaTime()
        let (generation, busy) = shared.withLock { ($0.generation, $0.mainBusy) }
        if busy { return } // main hasn't consumed the last frame
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let hand = detectHand(in: pixels)

        let claimed = shared.withLock { state -> Bool in
            guard state.generation == generation, !state.mainBusy else { return false }
            state.mainBusy = true
            let dt = t - state.lastFrameTime
            if state.lastFrameTime > 0, dt > 0 {
                let instant = 1 / dt
                state.fps = state.fps == 0 ? instant : state.fps * 0.9 + instant * 0.1
            }
            state.lastFrameTime = t
            return true
        }
        guard claimed else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let current = self.shared.withLock { state -> Bool in
                state.mainBusy = false
                return state.generation == generation
            }
            if current { self.onFrame?(t, hand) }
        }

        if wantsPreview, t - lastPreviewTime >= Self.previewInterval {
            lastPreviewTime = t
            if let image = previewImage(from: pixels) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.shared.withLock({ $0.generation }) == generation else { return }
                    self.onPreview?(image)
                }
            }
        }
    }

    // MARK: Vision

    /// Vision's joints in MediaPipe order (0 wrist, 1–4 thumb, 5–8 index, 9–12 middle,
    /// 13–16 ring, 17–20 little).
    private static let joints: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]
    /// Without these the hand isn't trusted at all.
    private static let essentialJoints: [VNHumanHandPoseObservation.JointName] = [.wrist, .indexTip, .middleMCP]
    private static let minConfidence: Float = 0.3

    private func detectHand(in pixels: CVPixelBuffer) -> HandLandmarks? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              let found = try? observation.recognizedPoints(.all)
        else { return nil }

        for joint in Self.essentialJoints {
            guard let point = found[joint], point.confidence >= Self.minConfidence else { return nil }
        }
        // Low-confidence joints keep their reported spot; a joint that is missing
        // altogether makes the frame unusable.
        var points: [HandPoint] = []
        points.reserveCapacity(HandLandmarks.count)
        for joint in Self.joints {
            guard let p = found[joint] else { return nil }
            // Vision: bottom-left origin, camera orientation. Ours: top-left, mirrored.
            points.append(HandPoint(x: 1 - Double(p.location.x), y: 1 - Double(p.location.y)))
        }
        return HandLandmarks(points: points)
    }

    // MARK: Preview

    private func previewImage(from pixels: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixels)
        let width = image.extent.width
        guard width > 0 else { return nil }
        let scale = min(1, Self.previewWidth / width)
        let size = CGSize(width: (width * scale).rounded(), height: (image.extent.height * scale).rounded())
        // Scale down, then flip left-right so it reads like a mirror.
        let transform = CGAffineTransform(scaleX: -scale, y: scale).translatedBy(x: -width, y: 0)
        let mirrored = image.transformed(by: transform)
        return ciContext.createCGImage(mirrored, from: CGRect(origin: .zero, size: size))
    }
}
