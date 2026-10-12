// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import AppKit
import CoreVideo
import MetalKit
import QuartzCore

/// 48 bytes, mirrored field for field by `Uniforms` in `FoldShader.source`.
public struct FoldUniforms: Equatable {
    /// `fadeOnly` is a mode: 0 = the effect, 1 = Reduce Motion (the captured desktop
    /// fades to black, opaque), 2 = no desktop image (black at alpha = coverage).
    public static let fadeDesktop: Float = 1
    public static let fadeSourceless: Float = 2

    public var progress: Float = 0
    public var perspective: Float = 0.7
    public var blur: Float = 0.65
    public var shadow: Float = 0.65
    public var size = SIMD2<Float>(1, 1)
    public var fadeOnly: Float = 0
    public var effect: UInt32 = FoldEffect.fallback.shaderIndex
    // A negative value retains normalized-progress fixtures; app paths provide physical defocus.
    public var defocus: Float = -1
    public var coverage: Float = 1
    // Negative values keep normalized-progress fixtures convenient. App paths supply radians.
    public var tilt: Float = -1
    public var referenceAngle: Float = 105

    public init() {}

    /// The app path: every physical quantity comes from the shared visual state.
    public init(visual: FoldVisualState, effect: FoldEffect, perspective: Float = 0.7, blur: Float = 0.65,
                shadow: Float = 0.65, size: SIMD2<Float> = SIMD2(1, 1), reducedMotion: Bool = false) {
        progress = Float(visual.progress); defocus = Float(visual.defocus); tilt = Float(visual.tilt)
        referenceAngle = Float(visual.referenceAngle); coverage = Float(visual.coverage)
        self.perspective = perspective; self.blur = blur; self.shadow = shadow; self.size = size
        fadeOnly = reducedMotion ? Self.fadeDesktop : 0
        self.effect = effect.shaderIndex
    }

    public var selectedEffect: FoldEffect { FoldEffect.resolve(shaderIndex: effect) }
}

public final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var revision: UInt64 = 0
    private var acceptedStream: ObjectIdentifier?
    public init() {}
    public func put(_ value: CVPixelBuffer) {
        lock.lock(); buffer = value; revision &+= 1; lock.unlock()
    }
    public func get() -> (CVPixelBuffer?, UInt64) {
        lock.lock(); defer { lock.unlock() }; return (buffer, revision)
    }
    public var hasFrame: Bool { lock.lock(); defer { lock.unlock() }; return buffer != nil }
    public func acceptStream(_ stream: ObjectIdentifier) {
        lock.lock(); acceptedStream = stream; buffer = nil; revision &+= 1; lock.unlock()
    }
    public func invalidateStream() {
        lock.lock(); acceptedStream = nil; buffer = nil; revision &+= 1; lock.unlock()
    }
    /// Check identity and replace the frame under the same lock as stop().
    /// Nil means rejected; true means this stream has just regained a frame.
    public func put(_ value: CVPixelBuffer, from stream: ObjectIdentifier) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard acceptedStream == stream else { return nil }
        let first = buffer == nil
        buffer = value; revision &+= 1
        return first
    }
    public func clear(from stream: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard acceptedStream == stream else { return false }
        let changed = buffer != nil; buffer = nil; revision &+= 1
        return changed
    }
}

/// What can go wrong while setting up or encoding Metal work (the text reaches
/// the user through the controller's status, so PT-PT).
struct FoldRenderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Immutable pipelines are shared; command queues and mutable textures stay per renderer.
private final class FoldPipelines: @unchecked Sendable {
    private static var devices: [ObjectIdentifier: FoldPipelines] = [:]
    private static let devicesLock = NSLock()

    /// Held so the dictionary key (the device's identity) can never be reused by another device.
    let device: MTLDevice
    let downsample: MTLComputePipelineState
    private let library: MTLLibrary
    private var renders: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let rendersLock = NSLock()

    static func shared(for device: MTLDevice) throws -> FoldPipelines {
        devicesLock.lock(); defer { devicesLock.unlock() }
        let key = ObjectIdentifier(device)
        if let existing = devices[key] { return existing }
        let pipelines = try FoldPipelines(device: device)
        devices[key] = pipelines
        return pipelines
    }

    private init(device: MTLDevice) throws {
        self.device = device
        library = try device.makeLibrary(source: FoldShader.source, options: nil)
        guard let function = library.makeFunction(name: "foldDownsample") else {
            throw FoldRenderError("O shader de desfocagem não está disponível.")
        }
        downsample = try device.makeComputePipelineState(function: function)
        _ = try render(for: .bgra8Unorm) // surfaces shader errors at renderer creation
    }

    /// bgra8 is the screen path; other formats exist so offscreen checks can read
    /// back floats and tell a NaN apart from black.
    func render(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        rendersLock.lock(); defer { rendersLock.unlock() }
        if let existing = renders[format] { return existing }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "foldVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "foldFragment")
        descriptor.colorAttachments[0].pixelFormat = format
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        renders[format] = state
        return state
    }
}

public final class FoldRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipelines: FoldPipelines
    /// The screen (bgra8) pipeline. Renderers on one device share it.
    let pipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private var blurPyramid: MTLTexture?
    private var blurLevels: [MTLTexture] = []
    private var blurredRevision: UInt64?
    private var renderedRevision: UInt64?
    private var renderedUniforms: FoldUniforms?
    private var cache: CVMetalTextureCache?
    private var importedBuffer: CVPixelBuffer?
    private var importedTexture: CVMetalTexture?
    private var importedRevision: UInt64?
    /// Bound in place of the desktop when there is none; the shader never reads it.
    private var placeholder: MTLTexture?
    private let inFlight = DispatchSemaphore(value: 3)
    /// Captured desktop frames. Without one the view draws `fallback`, or the Fade.
    public var frames: FrameStore?
    public var fallback: MTLTexture?
    /// With no frame and no fallback, draw the sourceless Fade (black at alpha =
    /// coverage) instead of waiting for a capture. A frame always wins when present.
    public var fadeWithoutCapture = false
    public var parameters: () -> FoldUniforms = { FoldUniforms() }
    public var animatedState: (() -> FoldVisualState?)?
    public var blendsWithDesktop = false
    private var animation = FoldVisualAnimation()
    private var presentationGeneration: UInt64 = 0
    private var needsPresentationCallback = true
    public var reportsEveryPresentation = false
    public var pausesWhenSettled = false
    public var keepsAnimating: () -> Bool = { false }
    public var onFailure: ((String) -> Void)?
    public var onPresented: (() -> Void)?
    public private(set) var progress: Double = 0
    private var lastTime = ProcessInfo.processInfo.systemUptime
    public private(set) var drawnFrames = 0
    public private(set) var skippedFrames = 0
    public private(set) var blurBuildCount = 0
    public private(set) var textureImportCount = 0
    public private(set) var lastGPUTimeMS: Double = 0
    public var transientTextureBytes: Int { blurPyramid?.allocatedSize ?? 0 }

    /// Nil when Metal, the shader or the texture cache is unavailable. Use
    /// `makeDefault()` for the system default device.
    public convenience init?(device: MTLDevice) {
        do { try self.init(creating: device) } catch { return nil }
    }

    /// On the system default device. (`init?()` would clash with NSObject's `init()`.)
    public static func makeDefault() -> FoldRenderer? {
        MTLCreateSystemDefaultDevice().flatMap { FoldRenderer(device: $0) }
    }

    init(creating device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw FoldRenderError("A fila de comandos do Metal não está disponível.") }
        self.queue = queue
        let pipelines = try FoldPipelines.shared(for: device)
        self.pipelines = pipelines
        pipeline = try pipelines.render(for: .bgra8Unorm)
        downsamplePipeline = pipelines.downsample
        super.init()
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw FoldRenderError("A cache de texturas do Metal não está disponível.")
        }
    }

    /// The view is transparent because the sourceless Fade is black with alpha;
    /// the captured paths write alpha 1 everywhere, so they are unaffected.
    /// The hosting window must also be non-opaque with a clear background.
    public func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.delegate = self
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        (view.layer as? CAMetalLayer)?.isOpaque = false
    }

    public func resetProgress(to value: Double) {
        progress = value; lastTime = ProcessInfo.processInfo.systemUptime
        renderedUniforms = nil
        animation.reset()
        invalidatePresentation()
    }

    public func invalidatePresentation() { presentationGeneration &+= 1; needsPresentationCallback = true }

    /// Completed or queued Metal commands retain their own resources. Clearing
    /// our references lets the desktop's full-size buffers retire after the last
    /// command, while keeping the compiled pipelines ready for the next movement.
    public func releaseTransientResources() {
        invalidatePresentation()
        blurLevels.removeAll(); blurPyramid = nil; blurredRevision = nil
        importedTexture = nil; importedBuffer = nil; importedRevision = nil
        renderedUniforms = nil; renderedRevision = nil
        if let cache { CVMetalTextureCacheFlush(cache,0) }
    }

    /// The same captured frame can be presented at several lid angles. Import it
    /// once, retaining both its pixel buffer and Core Video texture until replaced.
    func importFrame(_ pixelBuffer: CVPixelBuffer, revision: UInt64) throws -> CVMetalTexture {
        if importedRevision == revision, importedBuffer === pixelBuffer, let importedTexture { return importedTexture }
        guard let cache else { throw FoldRenderError("A cache de texturas do Metal não está disponível.") }
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,pixelBuffer,
            nil,.bgra8Unorm,CVPixelBufferGetWidth(pixelBuffer),CVPixelBufferGetHeight(pixelBuffer),0,&cvTexture)
        guard result == kCVReturnSuccess, let cvTexture, CVMetalTextureGetTexture(cvTexture) != nil else {
            throw FoldRenderError("Não foi possível preparar a imagem atual do ecrã para o Metal.")
        }
        importedBuffer = pixelBuffer; importedTexture = cvTexture; importedRevision = revision
        textureImportCount += 1
        return cvTexture
    }

    public func wake(_ view: MTKView) {
        guard view.window?.occlusionState.contains(.visible) == true else { return }
        if view.isPaused { lastTime = ProcessInfo.processInfo.systemUptime; animation.prime(at:lastTime) }
        view.isPaused = false
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { renderedUniforms = nil }

    /// What reaches the shader once the animated state is known. The sourceless Fade
    /// carries coverage in its alpha; with a frame it only matters when the view
    /// blends with the live desktop (otherwise the window's own alpha does it).
    static func finalized(_ base: FoldUniforms, visual: FoldVisualState, size: SIMD2<Float>,
                          sourceless: Bool, blendsWithDesktop: Bool) -> FoldUniforms {
        var u = base
        u.progress = Float(visual.progress)
        u.defocus = Float(visual.defocus)
        u.tilt = Float(visual.tilt)
        u.referenceAngle = Float(visual.referenceAngle)
        u.coverage = sourceless || blendsWithDesktop ? Float(visual.coverage) : 1
        u.size = size
        if sourceless { u.fadeOnly = FoldUniforms.fadeSourceless }
        return u
    }

    public func draw(in view: MTKView) {
        dispatchPrecondition(condition:.onQueue(.main))
        guard view.window?.isVisible == true, inFlight.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlight.signal() } }
        let frame = frames?.get()
        let pixelBuffer = frame?.0
        let revision = pixelBuffer == nil ? 0 : frame!.1
        let sourceless = pixelBuffer == nil && fallback == nil
        guard !sourceless || fadeWithoutCapture else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let base = parameters()
        let target = base.progress > 0 ? FoldVisualState(progress:Double(base.progress),
            defocus:Double(max(0,base.defocus)),
            tilt:Double(base.tilt >= 0 ? base.tilt : base.progress * .pi/2),
            referenceAngle:Double(base.referenceAngle)) : .clear
        let visual = animatedState?() ?? animation.sample(target:target,at:now)
        progress = visual.progress
        lastTime = now
        let uniforms = Self.finalized(base, visual:visual,
            size:SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            sourceless:sourceless, blendsWithDesktop:blendsWithDesktop)
        let settled = visual.isNear(target) && !keepsAnimating()
        if renderedRevision == revision && renderedUniforms == uniforms {
            skippedFrames += 1
            if pausesWhenSettled && settled { view.isPaused = true }
            return
        }
        var cvTexture: CVMetalTexture?
        var texture = fallback
        if let pixelBuffer {
            do {
                cvTexture = try importFrame(pixelBuffer,revision:revision)
                texture = cvTexture.flatMap { CVMetalTextureGetTexture($0) }
            } catch { onFailure?(error.localizedDescription); return }
        }
        guard texture != nil || sourceless else { return }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        do { try encode(command: command, pass: pass, texture: texture, uniforms: uniforms, sourceRevision:revision) }
        catch { blurredRevision = nil; renderedUniforms = nil; onFailure?(error.localizedDescription); return }
        let retainedTexture = cvTexture
        let generation = presentationGeneration
        let reportsPresentation = onPresented != nil && (needsPresentationCallback || reportsEveryPresentation)
        command.addCompletedHandler { [weak self, inFlight, pixelBuffer, retainedTexture] buffer in
            withExtendedLifetime((pixelBuffer, retainedTexture)) {}
            inFlight.signal()
            // Normal successful frames need no UI work after the first reveal.
            // Errors always return to main; synthetic checks retain every callback.
            guard reportsPresentation || buffer.status == .error else { return }
            DispatchQueue.main.async {
                guard let self, self.presentationGeneration == generation else { return }
                if buffer.status == .error {
                    self.blurredRevision = nil; self.renderedUniforms = nil
                    self.onFailure?(buffer.error?.localizedDescription ?? "A renderização Metal falhou.")
                }
                self.lastGPUTimeMS = max(0, (buffer.gpuEndTime-buffer.gpuStartTime)*1000)
                if buffer.status == .completed { self.onPresented?() }
            }
        }
        command.present(drawable)
        committed = true
        command.commit()
        needsPresentationCallback = false
        drawnFrames += 1
        renderedRevision = revision; renderedUniforms = uniforms
        if pausesWhenSettled && settled { view.isPaused = true }
    }

    /// Rebuild on each new source frame. Reuse it when only the fold angle changes.
    /// All passes use this renderer's serial queue and tracked resources. Ending each
    /// encoder orders writes before the next level reads the same texture allocation.
    private func prepareBlur(command: MTLCommandBuffer, input: MTLTexture, revision: UInt64?) throws -> MTLTexture {
        if blurPyramid?.width != input.width || blurPyramid?.height != input.height || blurPyramid?.pixelFormat != input.pixelFormat {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: input.pixelFormat,
                width: input.width, height: input.height, mipmapped: true)
            descriptor.mipmapLevelCount = min(9, descriptor.mipmapLevelCount)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw FoldRenderError("Falhou a alocação da textura de desfocagem.")
            }
            var levels: [MTLTexture] = []
            for level in 0..<texture.mipmapLevelCount {
                guard let view = texture.makeTextureView(pixelFormat: texture.pixelFormat, textureType: .type2D,
                    levels: level..<(level+1), slices: 0..<1) else { throw FoldRenderError("O nível de desfocagem não está disponível.") }
                levels.append(view)
            }
            blurPyramid = texture; blurLevels = levels
            blurredRevision = nil
        }
        if let revision, blurredRevision == revision, let pyramid = blurPyramid { return pyramid }
        guard let pyramid = blurPyramid, let blit = command.makeBlitCommandEncoder() else {
            throw FoldRenderError("O codificador de cópia da desfocagem não está disponível.")
        }
        blit.copy(from: input, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: input.width, height: input.height, depth: 1),
            to: pyramid, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        for level in 1..<blurLevels.count {
            guard let encoder = command.makeComputeCommandEncoder() else { throw FoldRenderError("O codificador da desfocagem não está disponível.") }
            encoder.setComputePipelineState(downsamplePipeline)
            encoder.setTexture(blurLevels[level-1], index: 0)
            encoder.setTexture(blurLevels[level], index: 1)
            encoder.dispatchThreads(MTLSize(width: blurLevels[level].width, height: blurLevels[level].height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }
        blurredRevision = revision
        blurBuildCount += 1
        return pyramid
    }

    private func placeholderTexture() throws -> MTLTexture {
        if let placeholder { return placeholder }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw FoldRenderError("A textura de substituição não está disponível.")
        }
        placeholder = texture
        return texture
    }

    /// A nil texture is the sourceless Fade: no pyramid, no desktop read.
    func encode(command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, texture: MTLTexture?, uniforms: FoldUniforms, sourceRevision: UInt64? = nil) throws {
        var uniforms = uniforms
        if texture == nil { uniforms.fadeOnly = FoldUniforms.fadeSourceless }
        let moving = uniforms.progress > 0.00001 && uniforms.progress < 1 && uniforms.fadeOnly < 0.5
        // Duo skips the pyramid at zero Softness. Geometrically minified effects,
        // including Ghost, still need it to keep fine source pixels stable.
        let needsBlur = moving && (uniforms.blur > 0 || uniforms.selectedEffect.needsPrefilteredSource)
        let source = try texture ?? placeholderTexture()
        let blurred = needsBlur ? try prepareBlur(command: command, input: source, revision:sourceRevision) : source
        let pipeline = try pipelines.render(for: pass.colorAttachments[0].texture?.pixelFormat ?? .bgra8Unorm)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw FoldRenderError("O codificador de renderização não está disponível.") }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(blurred, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
