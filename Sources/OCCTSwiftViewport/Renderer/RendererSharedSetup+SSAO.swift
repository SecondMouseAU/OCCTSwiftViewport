// RendererSharedSetup+SSAO.swift
// OCCTSwiftViewport
//
// The SSAO occlusion and blur passes shared by ViewportRenderer and OffscreenRenderer (issue
// #188). `ssao_fragment` used to compute the occlusion inline, so the 4x4 ordered dither of its
// kernel rotation went straight onto the image. The term now has its own full-screen pass into an
// R32Float texture, a depth-aware 4x4 blur of that texture into an R16Float one, and the
// composite reads the result.

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

    /// Full float for the occlusion pass's output.
    ///
    /// `ssaoBlur = false` then composites exactly the value the shader used to compute inline;
    /// half-float storage would round it by up to one level of 255. The term is
    /// `1 - occlusion * intensity`.
    static let rawPixelFormat = MTLPixelFormat.r32Float
    /// Half-float for the blur's output: the blur averages 16 terms, which an 8-bit target would
    /// quantise visibly in dark creases, and half-float precision is well below one level.
    static let blurredPixelFormat = MTLPixelFormat.r16Float

    /// The occlusion pass's output.
    private(set) var raw: MTLTexture?
    /// The blur's output, which the composite reads.
    private(set) var blurred: MTLTexture?
    /// Occlusion passes encoded over this value's lifetime; tests use it to check that SSAO off
    /// encodes none.
    private(set) var passesEncoded = 0
    /// Blur passes encoded over this value's lifetime; tests use it to check that
    /// `LightingConfiguration.ssaoBlur = false` encodes none.
    private(set) var blurPassesEncoded = 0

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
        func descriptor(_ format: MTLPixelFormat) -> MTLTextureDescriptor {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return descriptor
        }
        guard let newRaw = device.makeTexture(descriptor: descriptor(Self.rawPixelFormat)),
            let newBlurred = device.makeTexture(descriptor: descriptor(Self.blurredPixelFormat))
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

    fileprivate mutating func countBlurPass() {
        blurPassesEncoded += 1
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

    /// The occlusion and blur pipelines (single sample, one single-channel float colour target
    /// each, no depth).
    static func makeSSAOOcclusionPipelines(
        device: MTLDevice,
        library: MTLLibrary,
        labelPrefix: String
    ) -> SSAOOcclusionPipelines? {
        func pipeline(_ fragment: String, _ format: MTLPixelFormat) -> MTLRenderPipelineState? {
            makePipelineState(
                device: device,
                label: "\(labelPrefix)_\(fragment)",
                library: library,
                vertexFunction: "fullscreen_vertex",
                fragmentFunction: fragment,
                colorPixelFormat: format,
                depthPixelFormat: .invalid
            )
        }
        guard
            let occlusion = pipeline(
                "ssao_occlusion_fragment", SSAOOcclusionTargets.rawPixelFormat),
            let blur = pipeline("ssao_blur_fragment", SSAOOcclusionTargets.blurredPixelFormat)
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
    ///   - blur: `LightingConfiguration.ssaoBlur`. `false` skips the blur pass and hands back the
    ///     raw, dithered term.
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
        targets.countBlurPass()
        return blurred
    }
}
