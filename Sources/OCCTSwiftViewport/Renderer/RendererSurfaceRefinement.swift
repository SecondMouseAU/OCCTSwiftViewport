// RendererSurfaceRefinement.swift
// OCCTSwiftViewport
//
// The GPU surface-refinement paths (PN-triangle tessellation and mesh shaders) shared by
// ViewportRenderer and OffscreenRenderer: pipeline construction, per-body buffers, the frame's
// tessellation factor, and the draw calls.

@preconcurrency import Metal
import simd

// MARK: - Pipelines

extension RendererSharedSetup {

    /// Whether `quality` asks for PN-triangle tessellation (`.enhanced` and `.maximum`).
    nonisolated static func wantsTessellation(_ quality: RenderingQuality) -> Bool {
        quality == .enhanced || quality == .maximum
    }

    /// Whether `quality` asks for mesh shaders and `device` can run them.
    ///
    /// Mesh shaders need an Apple9 GPU (M3, A17 and later). Without one, `.maximum` falls back to
    /// tessellation.
    static func wantsMeshShaders(_ quality: RenderingQuality, device: MTLDevice) -> Bool {
        quality == .maximum && device.supportsFamily(.apple9)
    }

    /// Configures `descriptor` for the PN-triangle patch pipelines.
    ///
    /// `maxFactor` must already be clamped with `TessellationManager.clampedMaxFactor(_:)`.
    static func applyTessellation(to descriptor: MTLRenderPipelineDescriptor, maxFactor: Int) {
        descriptor.maxTessellationFactor = maxFactor
        descriptor.tessellationFactorStepFunction = .perPatch
        descriptor.tessellationPartitionMode = .fractionalEven
        descriptor.tessellationFactorFormat = .half
        descriptor.tessellationOutputWindingOrder = .counterClockwise
        descriptor.vertexDescriptor = nil  // Patch data is read from buffer 0 by patch_id.
    }

    /// Builds a tessellated (post-tessellation vertex function) pipeline state.
    ///
    /// Throws the device's error so a caller can report why tessellation is unavailable.
    static func makeTessellatedPipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        label: String,
        vertexFunction: String,
        fragmentFunction: String,
        colorPixelFormat: MTLPixelFormat = .invalid,
        depthPixelFormat: MTLPixelFormat,
        stencilPixelFormat: MTLPixelFormat = .invalid,
        sampleCount: Int = 1,
        blending: ColorBlending = .disabled,
        maxFactor: Int
    ) throws -> MTLRenderPipelineState {
        let descriptor = renderPipelineDescriptor(
            label: label, library: library, vertexFunction: vertexFunction,
            fragmentFunction: fragmentFunction, colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat, stencilPixelFormat: stencilPixelFormat,
            sampleCount: sampleCount, blending: blending)
        applyTessellation(to: descriptor, maxFactor: maxFactor)
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// The tessellated shaded pipeline: `tessellated_vertex` + `shaded_fragment`, alpha-blended
    /// for per-body transparency, into a colour + depth/stencil main pass.
    static func makeTessellatedShadedPipelineState(
        device: MTLDevice, library: MTLLibrary, sampleCount: Int, depthFormat: MTLPixelFormat,
        maxFactor: Int, label: String = "tessellated_shaded"
    ) throws -> MTLRenderPipelineState {
        try makeTessellatedPipelineState(
            device: device, library: library, label: label,
            vertexFunction: "tessellated_vertex", fragmentFunction: "shaded_fragment",
            colorPixelFormat: .bgra8Unorm, depthPixelFormat: depthFormat,
            stencilPixelFormat: depthFormat, sampleCount: sampleCount, blending: .sourceOver,
            maxFactor: maxFactor)
    }

    /// The tessellated shadow-map pipeline.
    ///
    /// Its fragment function honours the section clip planes (#162).
    static func makeTessellatedShadowPipelineState(
        device: MTLDevice, library: MTLLibrary, maxFactor: Int, label: String = "tessellated_shadow"
    ) throws -> MTLRenderPipelineState {
        try makeTessellatedPipelineState(
            device: device, library: library, label: label,
            vertexFunction: "tessellated_shadow_vertex", fragmentFunction: "shadow_clip_fragment",
            depthPixelFormat: .depth32Float, maxFactor: maxFactor)
    }

    /// The tessellated SSAO / silhouette depth-prepass pipeline, honouring the clip planes.
    static func makeTessellatedDepthOnlyPipelineState(
        device: MTLDevice, library: MTLLibrary, maxFactor: Int,
        label: String = "tessellated_depth_only"
    ) throws -> MTLRenderPipelineState {
        try makeTessellatedPipelineState(
            device: device, library: library, label: label,
            vertexFunction: "tessellated_depth_vertex",
            fragmentFunction: "depth_only_clip_fragment",
            depthPixelFormat: .depth32Float, maxFactor: maxFactor)
    }

    /// The tessellated GPU-pick pipeline (live renderer only).
    static func makeTessellatedPickPipelineState(
        device: MTLDevice, library: MTLLibrary, maxFactor: Int, label: String = "tessellated_pick"
    ) throws -> MTLRenderPipelineState {
        try makeTessellatedPipelineState(
            device: device, library: library, label: label,
            vertexFunction: "tessellated_pick_vertex",
            fragmentFunction: "tessellated_pick_fragment", colorPixelFormat: .r32Uint,
            depthPixelFormat: .depth32Float, maxFactor: maxFactor)
    }

    /// The per-triangle highlight on the tessellated surface (#202).
    ///
    /// `tessellated_highlight_vertex` + `tessellated_highlight_fragment`, blended over the shaded
    /// surface.
    static func makeTessellatedHighlightPipelineState(
        device: MTLDevice, library: MTLLibrary, sampleCount: Int, depthFormat: MTLPixelFormat,
        maxFactor: Int, label: String = "tessellated_highlight"
    ) throws -> MTLRenderPipelineState {
        try makeTessellatedPipelineState(
            device: device, library: library, label: label,
            vertexFunction: "tessellated_highlight_vertex",
            fragmentFunction: "tessellated_highlight_fragment", colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: depthFormat, stencilPixelFormat: depthFormat,
            sampleCount: sampleCount, blending: .sourceOver, maxFactor: maxFactor)
    }

    /// The selection outline on the tessellated surface (#202).
    ///
    /// `tessellated_outline_vertex` + `selection_outline_fragment`.
    static func makeTessellatedOutlinePipelineState(
        device: MTLDevice, library: MTLLibrary, sampleCount: Int, depthFormat: MTLPixelFormat,
        maxFactor: Int, label: String = "tessellated_outline"
    ) throws -> MTLRenderPipelineState {
        try makeTessellatedPipelineState(
            device: device, library: library, label: label,
            vertexFunction: "tessellated_outline_vertex",
            fragmentFunction: "selection_outline_fragment", colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: depthFormat, stencilPixelFormat: depthFormat,
            sampleCount: sampleCount, blending: .sourceOver, maxFactor: maxFactor)
    }

    /// The colourless selection stencil mask on the tessellated surface (#202).
    ///
    /// `tessellated_depth_vertex` + `depth_only_clip_fragment`, writing no colour.
    static func makeTessellatedStencilMaskPipelineState(
        device: MTLDevice, library: MTLLibrary, sampleCount: Int, depthFormat: MTLPixelFormat,
        maxFactor: Int, label: String = "tessellated_stencil_mask"
    ) throws -> MTLRenderPipelineState {
        let descriptor = renderPipelineDescriptor(
            label: label, library: library, vertexFunction: "tessellated_depth_vertex",
            fragmentFunction: "depth_only_clip_fragment", colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: depthFormat, stencilPixelFormat: depthFormat,
            sampleCount: sampleCount)
        descriptor.colorAttachments[0].writeMask = []
        applyTessellation(to: descriptor, maxFactor: maxFactor)
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Why a mesh-shader pipeline could not be built: its label and Metal's reason.
    struct MeshPipelineError: Error, CustomStringConvertible {
        let label: String
        let reason: String
        var description: String { "\(label): \(reason)" }
    }

    /// Builds a mesh-shader pipeline with the `meshlet_object` object function.
    ///
    /// Throws a `MeshPipelineError` when a function is missing or the device rejects the
    /// descriptor, so the caller can report it rather than fall back silently (#161).
    static func makeMeshShaderPipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        meshFunction: String,
        fragmentFunction: String,
        colorPixelFormat: MTLPixelFormat = .invalid,
        depthPixelFormat: MTLPixelFormat,
        stencilPixelFormat: MTLPixelFormat = .invalid,
        sampleCount: Int = 1,
        blending: Bool = false,
        label: String
    ) throws -> MTLRenderPipelineState {
        guard let objectFn = library.makeFunction(name: "meshlet_object"),
            let meshFn = library.makeFunction(name: meshFunction),
            let fragmentFn = library.makeFunction(name: fragmentFunction)
        else { throw MeshPipelineError(label: label, reason: "shader function not found") }
        let descriptor = MTLMeshRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.objectFunction = objectFn
        descriptor.meshFunction = meshFn
        descriptor.fragmentFunction = fragmentFn
        if colorPixelFormat != .invalid {
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            if blending, let attachment = descriptor.colorAttachments[0] {
                // Per-body surface transparency (issue #53).
                apply(.sourceOver, to: attachment)
            }
        }
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        if stencilPixelFormat != .invalid {
            descriptor.stencilAttachmentPixelFormat = stencilPixelFormat
        }
        descriptor.rasterSampleCount = sampleCount
        descriptor.maxTotalThreadsPerObjectThreadgroup = 1
        descriptor.maxTotalThreadsPerMeshThreadgroup = kMeshletMaxTriangles
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor, options: []).0
        } catch {
            throw MeshPipelineError(label: label, reason: error.localizedDescription)
        }
    }

    /// The mesh-shader shaded pipeline: `meshlet_mesh` + `shaded_fragment`, alpha-blended.
    static func makeMeshShaderShadedPipelineState(
        device: MTLDevice, library: MTLLibrary, sampleCount: Int, depthFormat: MTLPixelFormat,
        label: String = "mesh_shaded"
    ) throws -> MTLRenderPipelineState {
        try makeMeshShaderPipelineState(
            device: device, library: library, meshFunction: "meshlet_mesh",
            fragmentFunction: "shaded_fragment", colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: depthFormat, stencilPixelFormat: depthFormat,
            sampleCount: sampleCount, blending: true, label: label)
    }

    /// The mesh-shader shadow-map pipeline, honouring the section clip planes (#162).
    static func makeMeshShaderShadowPipelineState(
        device: MTLDevice, library: MTLLibrary, label: String = "mesh_shadow"
    ) throws -> MTLRenderPipelineState {
        try makeMeshShaderPipelineState(
            device: device, library: library, meshFunction: "meshlet_shadow_mesh",
            fragmentFunction: "shadow_clip_fragment", depthPixelFormat: .depth32Float,
            label: label)
    }

    /// The mesh-shader SSAO / silhouette depth-prepass pipeline, honouring the clip planes.
    static func makeMeshShaderDepthOnlyPipelineState(
        device: MTLDevice, library: MTLLibrary, label: String = "mesh_depth_only"
    ) throws -> MTLRenderPipelineState {
        try makeMeshShaderPipelineState(
            device: device, library: library, meshFunction: "meshlet_depth_mesh",
            fragmentFunction: "depth_only_clip_fragment", depthPixelFormat: .depth32Float,
            label: label)
    }

    // MARK: - Draws

    /// Draws a body's PN-triangle patches with `pipeline`.
    ///
    /// Binds the per-patch factor buffer, the patch data at vertex buffer 0 and `uniforms` at
    /// vertex buffer 1 (`Uniforms` for the shaded and depth paths, `ShadowUniformsSwift` for the
    /// shadow map). The caller sets fragment state and the depth-stencil state.
    static func encodeTessellatedDraw<U>(
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        tessellation: TessellationBuffers,
        uniforms: inout U
    ) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setTessellationFactorBuffer(
            tessellation.tessFactorBuffer, offset: 0, instanceStride: 0)
        encoder.setVertexBuffer(tessellation.patchDataBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<U>.size, index: 1)
        encoder.drawPatches(
            numberOfPatchControlPoints: 3, patchStart: 0, patchCount: tessellation.patchCount,
            patchIndexBuffer: nil, patchIndexBufferOffset: 0, instanceCount: 1, baseInstance: 0)
    }

    /// Draws a body's meshlets with the mesh-shader `pipeline`.
    ///
    /// `vertexBuffer` is the body's interleaved (stride 6) vertex buffer; `uniforms` is bound at
    /// object buffer 1 and mesh buffer 4. The caller sets fragment state.
    static func encodeMeshletDraw<U>(
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        meshlets: MeshletBuffers,
        vertexBuffer: MTLBuffer,
        uniforms: inout U
    ) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setObjectBuffer(meshlets.descriptorBuffer, offset: 0, index: 0)
        encoder.setObjectBytes(&uniforms, length: MemoryLayout<U>.size, index: 1)
        encoder.setMeshBuffer(meshlets.descriptorBuffer, offset: 0, index: 0)
        encoder.setMeshBuffer(vertexBuffer, offset: 0, index: 1)
        encoder.setMeshBuffer(meshlets.vertexIndexBuffer, offset: 0, index: 2)
        encoder.setMeshBuffer(meshlets.triangleIndexBuffer, offset: 0, index: 3)
        encoder.setMeshBytes(&uniforms, length: MemoryLayout<U>.size, index: 4)
        encoder.drawMeshThreadgroups(
            MTLSize(width: meshlets.meshletCount, height: 1, depth: 1),
            threadsPerObjectThreadgroup: MTLSize(width: 1, height: 1, depth: 1),
            threadsPerMeshThreadgroup: MTLSize(width: kMeshletMaxTriangles, height: 1, depth: 1))
    }
}

// MARK: - Buffers and factors

extension RendererSharedBuffers {

    /// Builds the tessellation patches and meshlets a body needs for the refined surface paths.
    ///
    /// Direct-mesh bodies and edge-only bodies get neither: both builders consume the interleaved
    /// stride-6 buffer. `faceIndices` plays no part, so STL/OBJ imports and primitives without it
    /// are refined too (#161). Patches are read from `vertexBuffer` (so they see the smoothed normals) and
    /// meshlets from `smoothedVertexData` when smoothing ran, so both describe the same mesh.
    ///
    /// - Parameters:
    ///   - body: The body the buffers are for.
    ///   - smoothedVertexData: The auto-smoothed interleaved data, or `nil` when none ran.
    ///   - mesh: The body's uploaded mesh buffers.
    ///   - tessellationManager: Builds the patches; `nil` skips tessellation.
    ///   - buildMeshlets: Whether the mesh-shader path is in use.
    ///   - creaseAngle: `normalSmoothingCreaseAngle`; PN patches keep edges sharper than this flat.
    ///   - device: Device for the meshlet buffers.
    ///   - commandQueue: Queue for the synchronous patch-building compute pass.
    /// - Returns: The patches and meshlets, each `nil` when not built.
    @MainActor
    static func makeRefinementBuffers(
        for body: ViewportBody,
        smoothedVertexData: [Float]?,
        mesh: MeshBuffers,
        tessellationManager: TessellationManager?,
        buildMeshlets: Bool,
        creaseAngle: Float,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) -> (tessellation: TessellationBuffers?, meshlets: MeshletBuffers?) {
        var tessellation: TessellationBuffers?
        if let tessellationManager, !body.usesDirectMesh,
            let vb = mesh.vertexBuffer, let ib = mesh.indexBuffer, mesh.indexCount > 0
        {
            tessellation = tessellationManager.buildPatches(
                vertexBuffer: vb, indexBuffer: ib,
                triangleCount: mesh.indexCount / 3, creaseAngle: creaseAngle,
                commandQueue: commandQueue)
        }
        var meshlets: MeshletBuffers?
        if buildMeshlets,
            let source = ViewportRenderer.meshletSourceVertexData(
                for: body, smoothedVertexData: smoothedVertexData)
        {
            meshlets = MeshletBuilder.build(
                vertexData: source, indices: body.indices, device: device)
        }
        return (tessellation, meshlets)
    }

    /// The configured maximum factor, clamped as the pipelines clamp it and capped to the
    /// `maxTessellationFactor` they were built with.
    ///
    /// A later `tessellationMaxFactor` raise cannot exceed the pipelines' cap.
    ///
    /// - Parameters:
    ///   - requested: The configured `tessellationMaxFactor`, before clamping.
    ///   - pipelineMaxFactor: The `maxTessellationFactor` the pipelines were built with.
    /// - Returns: The largest factor this frame may use.
    nonisolated static func cappedMaxTessellationFactor(
        requested: Int, pipelineMaxFactor: Int
    ) -> Float {
        Float(min(TessellationManager.clampedMaxFactor(requested), pipelineMaxFactor))
    }

    /// The factor the tessellation kernel caps (adaptive) or fills (uniform) patches with when no
    /// load governor runs: off-screen frames and `OffscreenRenderer`.
    ///
    /// - Parameters:
    ///   - requestedMaxFactor: The configured `tessellationMaxFactor`, before clamping.
    ///   - pipelineMaxFactor: The `maxTessellationFactor` the pipelines were built with.
    ///   - adaptive: `adaptiveTessellation`.
    ///   - policy: `uniformTessellationFactor`, used when not adaptive.
    /// - Returns: The factor passed as `maxFactor` to `TessellationManager.updateTessFactors`.
    nonisolated static func deterministicTessellationFactor(
        requestedMaxFactor: Int, pipelineMaxFactor: Int, adaptive: Bool,
        policy: UniformTessellationFactor
    ) -> Float {
        let maxFactor = cappedMaxTessellationFactor(
            requested: requestedMaxFactor, pipelineMaxFactor: pipelineMaxFactor)
        if adaptive { return maxFactor }
        return TessellationLoadGovernor.uniformFactor(
            policy: policy, maxFactor: maxFactor, governed: nil)
    }
}

// MARK: - Offscreen pipeline sets

/// Which refined surface paths a render uses, and so which per-body buffers it needs.
struct SurfaceRefinement: Hashable {
    /// PN-triangle tessellation (`.enhanced`, and `.maximum` without mesh shaders).
    var tessellation = false
    /// Mesh shaders (`.maximum` on Apple9).
    var meshShaders = false

    static let none = SurfaceRefinement()
}

/// The tessellated and mesh-shader pipelines `OffscreenRenderer` uses for one sample count.
///
/// One set exists per sample count, maximum factor and mesh-shader choice (#165). Built through
/// `RendererSharedSetup` exactly as the live renderer builds them. A path whose shaded pipeline
/// fails is reported as unavailable, and its bodies draw their plain mesh.
struct RefinedPipelines {
    struct Key: Hashable {
        let sampleCount: Int
        let maxFactor: Int
        let meshShaders: Bool
    }

    let tessellatedShaded: MTLRenderPipelineState?
    let tessellatedShadow: MTLRenderPipelineState?
    let tessellatedDepthOnly: MTLRenderPipelineState?
    /// Highlight, outline and stencil mask on the tessellated surface (#202).
    let tessellatedHighlight: MTLRenderPipelineState?
    let tessellatedOutline: MTLRenderPipelineState?
    let tessellatedStencilMask: MTLRenderPipelineState?
    let meshShaded: MTLRenderPipelineState?
    let meshShadow: MTLRenderPipelineState?
    let meshDepthOnly: MTLRenderPipelineState?

    init(device: MTLDevice, library: MTLLibrary, key: Key) {
        let depthFormat: MTLPixelFormat = .depth32Float_stencil8
        tessellatedShaded = try? RendererSharedSetup.makeTessellatedShadedPipelineState(
            device: device, library: library, sampleCount: key.sampleCount,
            depthFormat: depthFormat, maxFactor: key.maxFactor,
            label: "offscreen_tessellated_shaded")
        tessellatedShadow = try? RendererSharedSetup.makeTessellatedShadowPipelineState(
            device: device, library: library, maxFactor: key.maxFactor,
            label: "offscreen_tessellated_shadow")
        tessellatedDepthOnly = try? RendererSharedSetup.makeTessellatedDepthOnlyPipelineState(
            device: device, library: library, maxFactor: key.maxFactor,
            label: "offscreen_tessellated_depth_only")
        tessellatedHighlight = try? RendererSharedSetup.makeTessellatedHighlightPipelineState(
            device: device, library: library, sampleCount: key.sampleCount,
            depthFormat: depthFormat, maxFactor: key.maxFactor,
            label: "offscreen_tessellated_highlight")
        tessellatedOutline = try? RendererSharedSetup.makeTessellatedOutlinePipelineState(
            device: device, library: library, sampleCount: key.sampleCount,
            depthFormat: depthFormat, maxFactor: key.maxFactor,
            label: "offscreen_tessellated_outline")
        tessellatedStencilMask = try? RendererSharedSetup.makeTessellatedStencilMaskPipelineState(
            device: device, library: library, sampleCount: key.sampleCount,
            depthFormat: depthFormat, maxFactor: key.maxFactor,
            label: "offscreen_tessellated_stencil_mask")
        if key.meshShaders {
            meshShaded = try? RendererSharedSetup.makeMeshShaderShadedPipelineState(
                device: device, library: library, sampleCount: key.sampleCount,
                depthFormat: depthFormat, label: "offscreen_mesh_shaded")
            meshShadow = try? RendererSharedSetup.makeMeshShaderShadowPipelineState(
                device: device, library: library, label: "offscreen_mesh_shadow")
            meshDepthOnly = try? RendererSharedSetup.makeMeshShaderDepthOnlyPipelineState(
                device: device, library: library, label: "offscreen_mesh_depth_only")
        } else {
            meshShaded = nil
            meshShadow = nil
            meshDepthOnly = nil
        }
    }

    /// The paths these pipelines can actually draw; tessellation also needs a
    /// `TessellationManager` (`canTessellate`) to build patches and factors.
    func refinement(canTessellate: Bool) -> SurfaceRefinement {
        SurfaceRefinement(
            tessellation: canTessellate && tessellatedShaded != nil,
            meshShaders: meshShaded != nil)
    }
}
