// Adapted from MacDuo (MIT) — see THIRD_PARTY_NOTICES.md
import Metal

/// Renders without a view, a window or a drawable, so tests (and any future
/// still-image export) can look at the pixels. Not used by the live path.
extension FoldRenderer {
    /// One frame into a shared-storage texture, completed before returning.
    /// A nil `source` is the sourceless Fade. bgra8 is what the screen gets;
    /// rgba32Float keeps NaN and infinity visible, which 8 bits would flatten to 0.
    func renderOffscreen(_ uniforms: FoldUniforms, source: MTLTexture?, width: Int? = nil, height: Int? = nil,
                         pixelFormat: MTLPixelFormat = .bgra8Unorm, revision: UInt64? = nil) throws -> MTLTexture {
        let width = width ?? source?.width ?? 640, height = height ?? source?.height ?? 400
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else {
            throw FoldRenderError("O destino fora do ecrã não está disponível.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        var uniforms = uniforms
        uniforms.size = SIMD2(Float(width), Float(height))
        try encode(command: command, pass: pass, texture: source, uniforms: uniforms, sourceRevision: revision)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw FoldRenderError(command.error?.localizedDescription ?? "A renderização fora do ecrã falhou.")
        }
        return target
    }
}

extension MTLTexture {
    /// Bytes in B, G, R, A order, row by row from the top.
    func readBGRA8() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width*height*4)
        getBytes(&bytes, bytesPerRow: width*4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    /// Floats in R, G, B, A order, row by row from the top (rgba32Float textures).
    func readRGBA32Float() -> [Float] {
        var values = [Float](repeating: 0, count: width*height*4)
        getBytes(&values, bytesPerRow: width*16, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return values
    }
}
