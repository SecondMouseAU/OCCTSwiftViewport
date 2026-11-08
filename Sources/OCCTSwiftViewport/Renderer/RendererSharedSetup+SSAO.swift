// RendererSharedSetup+SSAO.swift
// OCCTSwiftViewport
//
// The SSAO occlusion and blur passes shared by ViewportRenderer and OffscreenRenderer (issue
// #188). `ssao_fragment` used to compute the occlusion inline, so the 4x4 ordered dither of its
// kernel rotation went straight onto the image. The term now has its own full-screen pass into an
// R16Float texture, a depth-aware 4x4 blur of that texture, and the composite reads the result.

@preconcurrency import Metal

/// The pipelines of the SSAO occlusion pass and its blur.
struct SSAOOcclusionPipelines {
    /// `ssao_occlusion_fragment`: depth in, raw occlusion term out.
    let occlusion: MTLRenderPipelineState
    /// `ssao_blur_fragment`: raw term + depth in, blurred term out.
    let blur: MTLRenderPipelineState
}

/// The two full-resolution textures the SSAO term passes through, sized like the drawable.
///
/// Allocated the first frame SSAO runs, rebuilt when the size changes, and released as soon as a
/// frame doesn't run SSAO, so a viewport with SSAO off holds no AO memory and encodes no AO pass.
struct SSAOOcclusionTargets {

    /// One channel of half-float: the term is `1 - occlusion * intensity`, and the blur averages
    /// 16 of them, which an 8-bit target would quantise visibly in dark creases.
    static let pixelFormat = MTLPixelFormat.r16Float

    /// The occlusion pass's output.
    private(set) var raw: MTLTexture?
    /// The blur's output, which the composite reads.
    private(set) var blurred: MTLTexture?
    /// Occlusion passes encoded over this value's lifetime; tests use it to check that SSAO off
    /// encodes none.
    private(set) var passesEncoded = 0

    /// Whether the textures are currently allocated.
    var isAllocated: Bool { raw != nil && blurred != nil }

    /// Both textures at `width` x `height`, allocating them if absent or sized differently.
    mutating func ensure(device: MTLDevice, width: Int, height: Int) -> (
        raw: MTLTexture, blurred: MTLTexture
    )? {
        guard width > 0, height > 0 else { return nil }
        if let raw, let blurred, raw.width == width, raw.height == height {
            return (raw, blurred)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let newRaw = device.makeTexture(descriptor: descriptor),
            let newBlurred = device.makeTexture(descriptor: descriptor)
        else {
            release()
            return nil
        }
        newRaw.label = "ssao_occlusion"
        newBlurred.label = "ssao_occlusion_blurred"
        raw = newRaw
        blurred = newBlurred
        return (newRaw, newBlurred)
    }

    /// Drops both textures.
    mutating func release() {
        raw = nil
        blurred = nil
    }

    fileprivate mutating func countPass() {
        passesEncoded += 1
    }
}

extension RendererSharedSetup {

    /// Whether `lighting` asks for the SSAO term.
    ///
    /// The composite multiplies it in only when this holds, so the occlusion and blur passes are
    /// skipped (and their textures released) when it doesn't, including when the composite runs
    /// for silhouettes alone.
    static func ssaoOcclusionActive(_ lighting: LightingConfiguration) -> Bool {
        lighting.enableSSAO && lighting.ssaoIntensity > 0.001
    }

    /// The occlusion and blur pipelines (single sample, one `r16Float` colour target, no depth).
    static func makeSSAOOcclusionPipelines(
        device: MTLDevice,
        library: MTLLibrary,
        labelPrefix: String
    ) -> SSAOOcclusionPipelines? {
        func pipeline(_ fragment: String) -> MTLRenderPipelineState? {
            makePipelineState(
                device: device,
                label: "\(labelPrefix)_\(fragment)",
                library: library,
                vertexFunction: "fullscreen_vertex",
                fragmentFunction: fragment,
                colorPixelFormat: SSAOOcclusionTargets.pixelFormat,
                depthPixelFormat: .invalid
            )
        }
        guard let occlusion = pipeline("ssao_occlusion_fragment"),
            let blur = pipeline("ssao_blur_fragment")
        else { return nil }
        return SSAOOcclusionPipelines(occlusion: occlusion, blur: blur)
    }

    /// Encodes the SSAO occlusion pass and its blur.
    ///
    /// Call between the depth prepass and the composite.
    ///
    /// - Parameters:
    ///   - commandBuffer: The frame's command buffer.
    ///   - pipelines: The occlusion and blur pipelines.
    ///   - targets: The occlusion textures, allocated or resized to match `depth` as needed.
    ///   - device: The device that allocates the textures.
    ///   - depth: The single-sample depth the prepass wrote; also sets the target size.
    ///   - params: Must carry the intensity the composite will use (`SSAOParamsSwift.intensity`)
    ///     and the projection terms for `depth`.
    ///   - blur: `false` skips the blur and hands back the raw term. Only tests turn this off, to
    ///     see the dither the blur removes.
    /// - Returns: The texture `ssao_fragment` should read as its occlusion term, or `nil` if the
    ///   targets couldn't be allocated (the caller then sets the composite's intensity to 0).
    static func encodeSSAOOcclusion(
        commandBuffer: MTLCommandBuffer,
        pipelines: SSAOOcclusionPipelines,
        targets: inout SSAOOcclusionTargets,
        device: MTLDevice,
        depth: MTLTexture,
        params: SSAOParamsSwift,
        blur: Bool = true
    ) -> MTLTexture? {
        guard
            let (raw, blurred) = targets.ensure(
                device: device, width: depth.width, height: depth.height)
        else { return nil }
        var params = params

        func fullScreenPass(
            into target: MTLTexture, pipeline: MTLRenderPipelineState, textures: [MTLTexture]
        ) -> Bool {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            // The triangle covers every pixel, so there is nothing to load.
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
            else { return false }
            encoder.setRenderPipelineState(pipeline)
            for (index, texture) in textures.enumerated() {
                encoder.setFragmentTexture(texture, index: index)
            }
            encoder.setFragmentBytes(
                &params, length: MemoryLayout<SSAOParamsSwift>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            return true
        }

        guard fullScreenPass(into: raw, pipeline: pipelines.occlusion, textures: [depth])
        else { return nil }
        targets.countPass()
        guard blur else { return raw }
        guard fullScreenPass(into: blurred, pipeline: pipelines.blur, textures: [raw, depth])
        else { return raw }
        return blurred
    }
}
