import AVFoundation
import CoreImage
import HandKit
import os
import Vision

/// Webcam → hand joints (Apple Vision or MediaPipe, see `engine`) → `HandLandmarks`.
/// Nothing here decides what a pose means; that is `HandMouseEngine`'s job. The camera
/// only runs between `start()` and `stop()`, and the preview image is only built while
/// `wantsPreview` is true.
///
/// Threading: frames arrive on a private serial queue; the callbacks hop to the main
/// thread. If the main thread hasn't consumed the previous frame the new one is
/// dropped before the detector runs, so a stalled UI never builds a backlog.
final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // MARK: Public API (main thread)

    /// A camera's `uniqueID`; nil = the system's default video device.
    var cameraID: String?
    /// What finds the hand. Read when the camera starts; to change it, `stop()` then `start()`.
    var engine: HandTrackingEngine = .vision
    /// Called on main, once per processed frame. `hand` is nil when none is seen
    /// (or wrist / index tip / middle knuckle are below 0.3 confidence).
    /// `t` = `CACurrentMediaTime()` when the frame was captured.
    var onFrame: ((_ t: TimeInterval, _ hand: HandLandmarks?) -> Void)?
    /// Mirrored, ≤ 320 px wide, ≤ 15 fps; only while `wantsPreview`. Called on main.
    var onPreview: ((CGImage) -> Void)?
    /// A user-facing failure (PT-PT): the camera is not usable. Called on main.
    var onError: ((String) -> Void)?
    /// A user-facing problem the run survives (PT-PT), e.g. a fallback to Vision. Called on main.
    var onNotice: ((String) -> Void)?

    /// Build and deliver preview images. Zero cost while false.
    var wantsPreview: Bool {
        get { shared.withLock { $0.wantsPreview } }
        set { shared.withLock { $0.wantsPreview = newValue } }
    }

    /// Frames per second the pipeline is really processing (exponential average).
    var fps: Double { shared.withLock { $0.fps } }
    /// Average detector time per frame in ms (exponential average; with Vision, both passes
    /// when the crop missed); diagnostics only.
    var modelMs: Double { shared.withLock { $0.modelMs } }
    /// The engine that really ran the last frame: `engine`, unless MediaPipe couldn't load.
    var engineInUse: HandTrackingEngine { shared.withLock { $0.engineInUse } }
    /// Pixel size of the frames the camera really delivers; (0, 0) until the first one.
    var frameSize: (width: Int, height: Int) { shared.withLock { ($0.frameWidth, $0.frameHeight) } }
    /// The detector is following the hand (Vision: looking at a crop around it, not the whole
    /// frame; MediaPipe: palm detector skipped) as of the last frame.
    var roiActive: Bool { shared.withLock { $0.roiActive } }

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
        var modelMs = 0.0
        /// Chosen for this run (set with `generation`) and what actually ran.
        var engine = HandTrackingEngine.vision
        var engineInUse = HandTrackingEngine.vision
        var frameWidth = 0
        var frameHeight = 0
        var roiActive = false
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
        // Revision 1 is the only (so the latest) hand pose revision; the default is right.
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()
    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastPreviewTime: TimeInterval = 0
    /// Where Vision looks next frame: a crop around the hand just seen (nil = whole frame).
    /// Valid for `roiGeneration` only, so a new run always starts on the whole frame
    /// without `start()` / `stop()` having to reach into this queue.
    private var roi: HandRegion?
    private var roiGeneration = -1
    /// Frames the crop has been used since the last whole-frame pass.
    private var framesSinceAnchor = 0
    /// MediaPipe's detector: loaded on the first frame of a MediaPipe run, kept for the next
    /// run, dropped by the first Vision run. `mediaPipeGeneration` marks the run it belongs to.
    private var mediaPipe: MediaPipeHandDetector?
    private var mediaPipeGeneration = -1
    /// Loading failed in this run: Vision takes over until the next one.
    private var mediaPipeFailed = false

    /// A steady frame rate keeps the filters' timing predictable.
    private static let frameRate: Double = 30
    private static let previewWidth: CGFloat = 320
    private static let previewInterval: TimeInterval = 1.0 / 15
    /// With a crop active, every this many frames Vision gets the whole frame again so
    /// the crop can't drift away from the hand.
    private static let reanchorInterval = 60

    // MARK: Session

    private func launch() {
        removeObservers()
        let generation = resetShared(engine: engine)
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

    /// Starts a new run: bumps the generation, sets its engine (nil = keep the last one, so
    /// frames still in flight after a `stop()` don't unload MediaPipe) and clears the per-run
    /// measurements.
    @discardableResult
    private func resetShared(engine: HandTrackingEngine? = nil) -> Int {
        shared.withLock { state in
            state.generation += 1
            if let engine { state.engine = engine }
            state.engineInUse = state.engine
            state.fps = 0
            state.modelMs = 0
            state.frameWidth = 0
            state.frameHeight = 0
            state.roiActive = false
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

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            return .failure(.message("Não consegui abrir a câmara"))
        }
        session.addInput(input)

        // 720p gives Vision finer joints (the hand is small in the frame) and the crop
        // around the hand keeps it fast; fall back to what the camera offers. Checked
        // after the input is in, so `canSetSessionPreset` answers for this camera.
        for preset in [AVCaptureSession.Preset.hd1280x720, .vga640x480, .medium, .high]
        where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
        }

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
        capFrameRate(of: device)
        return .success((session, output))
    }

    /// Caps the camera at `frameRate` when its current format allows it; otherwise
    /// leaves it as it is.
    private func capFrameRate(of device: AVCaptureDevice) {
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= Self.frameRate && Self.frameRate <= $0.maxFrameRate
        }
        guard supported, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(Self.frameRate))
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

    private func notice(_ message: String) {
        onNotice?(message)
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let t = CACurrentMediaTime()
        let (generation, busy, engine) = shared.withLock { ($0.generation, $0.mainBusy, $0.engine) }
        if busy { return } // main hasn't consumed the last frame
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let frameWidth = CVPixelBufferGetWidth(pixels), frameHeight = CVPixelBufferGetHeight(pixels)
        // Loading the models takes a while: kept out of the timing and the frame rate.
        let loading = engine == .mediapipe && mediaPipe == nil && mediaPipeGeneration != generation
        let detector = mediaPipeDetector(for: engine, generation: generation)
        let modelStart = CACurrentMediaTime()
        let detection = detector.map { detectHand(with: $0, in: pixels) }
            ?? detectHand(in: pixels, generation: generation)
        let hand = detection.hand
        let modelMs = (CACurrentMediaTime() - modelStart) * 1000
        let engineInUse: HandTrackingEngine = detector == nil ? .vision : .mediapipe

        let claimed = shared.withLock { state -> Bool in
            guard state.generation == generation, !state.mainBusy else { return false }
            state.mainBusy = true
            let dt = t - state.lastFrameTime
            if state.lastFrameTime > 0, dt > 0 {
                let instant = 1 / dt
                state.fps = state.fps == 0 ? instant : state.fps * 0.9 + instant * 0.1
            }
            state.lastFrameTime = loading ? 0 : t
            state.modelMs = state.modelMs == 0 ? modelMs : state.modelMs * 0.9 + modelMs * 0.1
            state.engineInUse = engineInUse
            state.frameWidth = frameWidth
            state.frameHeight = frameHeight
            state.roiActive = detection.cropping
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

    // MARK: MediaPipe

    /// The detector for this frame's run, or nil when Vision should run: Vision is chosen,
    /// or the models couldn't load (the user is told once, and Vision takes over until the
    /// next run). Loads on the first MediaPipe frame of a run.
    private func mediaPipeDetector(for engine: HandTrackingEngine, generation: Int) -> MediaPipeHandDetector? {
        if mediaPipeGeneration != generation { // a new run: nothing carries over but the models
            mediaPipeGeneration = generation
            mediaPipeFailed = false
            if engine == .vision { mediaPipe = nil } else { mediaPipe?.reset() }
        }
        guard engine == .mediapipe, !mediaPipeFailed else { return nil }
        if mediaPipe == nil {
            do {
                mediaPipe = try MediaPipeHandDetector()
            } catch {
                mediaPipeFailed = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.shared.withLock({ $0.generation }) == generation else { return }
                    self.notice("Não consegui carregar o modelo MediaPipe. A usar o Apple Vision.")
                }
            }
        }
        return mediaPipe
    }

    private func detectHand(with detector: MediaPipeHandDetector, in pixels: CVPixelBuffer) -> Detection {
        let result = detector.detect(pixels)
        return Detection(hand: result.hand, cropping: result.tracking)
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

    /// What one frame gave: the hand (nil = none) and whether the detector is following it
    /// (Vision: the next frame is cropped; MediaPipe: this frame skipped the palm detector).
    private struct Detection {
        var hand: HandLandmarks?
        var cropping: Bool
    }

    /// One observation, already mapped to the whole image. `vision` = the 21 joints in
    /// Vision's own space (bottom-left origin, not mirrored), for the next crop.
    private struct Found {
        var hand: HandLandmarks
        var mean: Double
        var vision: [HandPoint]
    }

    /// Looks in the crop around where the hand was; no hand there (or none yet, or a
    /// periodic re-anchor) → the whole frame, in the same frame. A hand found sets the
    /// crop for the next one.
    private func detectHand(in pixels: CVPixelBuffer, generation: Int) -> Detection {
        if roiGeneration != generation { // a new run: the old crop means nothing
            roiGeneration = generation
            roi = nil
            framesSinceAnchor = 0
        }
        var found: Found?
        if let region = roi, framesSinceAnchor < Self.reanchorInterval {
            framesSinceAnchor += 1
            found = detect(in: pixels, region: region)
        }
        if found == nil {
            framesSinceAnchor = 0
            found = detect(in: pixels, region: .full)
        }
        roi = found.map {
            HandRegion.around(points: $0.vision,
                              imageWidth: Double(CVPixelBufferGetWidth(pixels)),
                              imageHeight: Double(CVPixelBufferGetHeight(pixels)))
        }
        return Detection(hand: found?.hand, cropping: roi.map { $0 != .full } ?? false)
    }

    private func detect(in pixels: CVPixelBuffer, region: HandRegion) -> Found? {
        // Vision wants the rect in the image's own space (bottom-left origin, not mirrored).
        request.regionOfInterest = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil, let observations = request.results else { return nil }
        // Normally one hand (maximumHandCount); if more come back, the surest one wins.
        return observations
            .compactMap { Self.landmarks(from: $0, in: region) }
            .max { $0.mean < $1.mean }
    }

    /// The 21 joints of one observation with their confidences, or nil if the hand
    /// can't be trusted. `mean` = average joint confidence, to rank several hands.
    /// With a crop, Vision's points are relative to it: they go back to the whole
    /// image first, then get mirrored.
    private static func landmarks(from observation: VNHumanHandPoseObservation, in region: HandRegion) -> Found? {
        guard let found = try? observation.recognizedPoints(.all) else { return nil }
        for joint in essentialJoints {
            guard let point = found[joint], point.confidence >= minConfidence else { return nil }
        }
        // Low-confidence joints keep their reported spot (the engine reads `confidence`);
        // a joint that is missing altogether makes the frame unusable.
        var points: [HandPoint] = []
        var vision: [HandPoint] = []
        var confidence: [Double] = []
        points.reserveCapacity(HandLandmarks.count)
        vision.reserveCapacity(HandLandmarks.count)
        confidence.reserveCapacity(HandLandmarks.count)
        for joint in joints {
            guard let p = found[joint] else { return nil }
            let global = region.unmap(HandPoint(x: Double(p.location.x), y: Double(p.location.y)))
            vision.append(global)
            // Vision: bottom-left origin, camera orientation. Ours: top-left, mirrored.
            points.append(HandPoint(x: 1 - global.x, y: 1 - global.y))
            confidence.append(Double(p.confidence))
        }
        guard let hand = HandLandmarks(points: points, confidence: confidence) else { return nil }
        return Found(hand: hand, mean: confidence.reduce(0, +) / Double(confidence.count), vision: vision)
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
