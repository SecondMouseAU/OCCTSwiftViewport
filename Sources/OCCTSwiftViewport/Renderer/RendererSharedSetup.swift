// RendererSharedSetup.swift
// OCCTSwiftViewport
//
// Metal pipeline / state construction shared by ViewportRenderer and OffscreenRenderer.

@preconcurrency import Metal
import simd

/// Metal setup shared by the live (`ViewportRenderer`) and headless (`OffscreenRenderer`) paths.
///
/// Both renderers build the same shaded / direct-mesh / wireframe / grid / axis / point / shadow
/// pipelines, the same procedural matcap, and the same adaptive grid and shadow-frustum math. See
/// `docs/metal-architecture.md` for how the passes fit together.
enum RendererSharedSetup {

    /// Colour-attachment blend presets used by the renderers' pipelines.
    enum ColorBlending {
        /// No blending: the fragment replaces the destination.
        case disabled

        /// Straight-alpha "over": colour is blended by the source alpha, and the target's alpha
        /// accumulates coverage (`srcA + dstA × (1 − srcA)`), so a translucent draw over an opaque
        /// background leaves it opaque.
        ///
        /// Every blended colour pipeline uses this. Blending the alpha channel by the source alpha
        /// too (`srcA² + dstA × (1 − srcA)`), as the shaded, edge, highlight and outline
        /// pipelines used to, lowered the target's alpha under every translucent surface. The
        /// readback is a premultiplied-alpha image, so those pixels came out with colour above
        /// their alpha and un-premultiplied to near-white: `PBRMaterial.glass` rendered as a flat
        /// white disc (#187).
        case sourceOver
    }

    // MARK: - Vertex Descriptors

    /// Interleaved position + normal in buffer 0, stride 6 floats.
    static func interleavedVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[1].format = .float3
        descriptor.attributes[1].offset = MemoryLayout<Float>.size * 3
        descriptor.attributes[1].bufferIndex = 0
        descriptor.layouts[0].stride = MemoryLayout<Float>.size * 6
        return descriptor
    }

    /// Position, arc length, quad corner, and segment direction for expanded edges.
    static func quadEdgeVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[1].format = .float
        descriptor.attributes[1].offset = MemoryLayout<Float>.size * 3
        descriptor.attributes[1].bufferIndex = 0
        descriptor.attributes[2].format = .float2
        descriptor.attributes[2].offset = MemoryLayout<Float>.size * 4
        descriptor.attributes[2].bufferIndex = 0
        descriptor.attributes[3].format = .float3
        descriptor.attributes[3].offset = MemoryLayout<Float>.size * 6
        descriptor.attributes[3].bufferIndex = 0
        descriptor.layouts[0].stride = MemoryLayout<Float>.size * 9
        return descriptor
    }

    /// De-interleaved direct-mesh layout: position in buffer 0, normal in buffer 2, stride 3 floats
    /// each.
    ///
    /// Vertex-stage buffer 1 carries the uniforms and the fragment table is separate, so buffer 2 is
    /// free in the vertex stage. The shaded / shadow / pick / depth shaders are reused unchanged
    /// because the attributes still arrive via `[[stage_in]]`.
    static func directMeshVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[1].format = .float3
        descriptor.attributes[1].offset = 0
        descriptor.attributes[1].bufferIndex = 2
        descriptor.layouts[0].stride = MemoryLayout<Float>.size * 3
        descriptor.layouts[2].stride = MemoryLayout<Float>.size * 3
        return descriptor
    }

    /// Position + RGBA colour in buffer 0, stride 7 floats, for the coordinate-axis lines.
    static func axisVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[1].format = .float4
        descriptor.attributes[1].offset = MemoryLayout<Float>.size * 3
        descriptor.attributes[1].bufferIndex = 0
        descriptor.layouts[0].stride = MemoryLayout<Float>.size * 7
        return descriptor
    }

    // MARK: - Pipeline Descriptors

    /// Builds a render pipeline descriptor from the parameters the renderers actually vary.
    ///
    /// Pass `.invalid` for `colorPixelFormat` to build a depth-only pipeline (shadow map, SSAO
    /// depth prepass), and `.invalid` for `stencilPixelFormat` when the pass has no stencil.
    static func renderPipelineDescriptor(
        label: String? = nil,
        library: MTLLibrary,
        vertexFunction: String,
        fragmentFunction: String,
        colorPixelFormat: MTLPixelFormat = .invalid,
        depthPixelFormat: MTLPixelFormat,
        stencilPixelFormat: MTLPixelFormat = .invalid,
        sampleCount: Int = 1,
        blending: ColorBlending = .disabled,
        vertexDescriptor: MTLVertexDescriptor? = nil
    ) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        // Assigning `nil` trips a Metal assertion, so only set a label when one is supplied.
        if let label { descriptor.label = label }
        descriptor.vertexFunction = library.makeFunction(name: vertexFunction)
        descriptor.fragmentFunction = library.makeFunction(name: fragmentFunction)
        if colorPixelFormat != .invalid {
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            descriptor.colorAttachments[1].pixelFormat = .invalid
            apply(blending, to: descriptor.colorAttachments[0])
        }
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        if stencilPixelFormat != .invalid {
            descriptor.stencilAttachmentPixelFormat = stencilPixelFormat
        }
        descriptor.rasterSampleCount = sampleCount
        descriptor.vertexDescriptor = vertexDescriptor
        return descriptor
    }

    static func apply(
        _ blending: ColorBlending,
        to attachment: MTLRenderPipelineColorAttachmentDescriptor
    ) {
        switch blending {
        case .disabled:
            return
        case .sourceOver:
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
    }

    /// Builds a render pipeline state, returning `nil` if the device rejects the descriptor.
    static func makePipelineState(
        device: MTLDevice,
        label: String? = nil,
        library: MTLLibrary,
        vertexFunction: String,
        fragmentFunction: String,
        colorPixelFormat: MTLPixelFormat = .invalid,
        depthPixelFormat: MTLPixelFormat,
        stencilPixelFormat: MTLPixelFormat = .invalid,
        sampleCount: Int = 1,
        blending: ColorBlending = .disabled,
        vertexDescriptor: MTLVertexDescriptor? = nil
    ) -> MTLRenderPipelineState? {
        let descriptor = renderPipelineDescriptor(
            label: label,
            library: library,
            vertexFunction: vertexFunction,
            fragmentFunction: fragmentFunction,
            colorPixelFormat: colorPixelFormat,
            depthPixelFormat: depthPixelFormat,
            stencilPixelFormat: stencilPixelFormat,
            sampleCount: sampleCount,
            blending: blending,
            vertexDescriptor: vertexDescriptor
        )
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - Shared Pipelines

    /// Shaded-surface pipeline; pass `directMeshVertexDescriptor()` for the direct-mesh sibling.
    ///
    /// Per-body surface transparency (issue #53) honours `bodyUniforms.color.a`; opaque bodies
    /// (alpha = 1) are unchanged by the source-alpha blending.
    static func makeShadedPipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        sampleCount: Int,
        depthFormat: MTLPixelFormat,
        vertexDescriptor: MTLVertexDescriptor,
        label: String? = nil
    ) -> MTLRenderPipelineState? {
        makePipelineState(
            device: device,
            label: label,
            library: library,
            vertexFunction: "shaded_vertex",
            fragmentFunction: "shaded_fragment",
            colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: depthFormat,
            stencilPixelFormat: depthFormat,
            sampleCount: sampleCount,
            blending: .sourceOver,
            vertexDescriptor: vertexDescriptor
        )
    }

    /// Wireframe / edge line pipeline.
    static func makeWireframePipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        sampleCount: Int,
        depthFormat: MTLPixelFormat,
        vertexDescriptor: MTLVertexDescriptor,
        label: String? = nil
    ) -> MTLRenderPipelineState? {
        makePipelineState(
            device: device,
            label: label,
            library: library,
            vertexFunction: "wireframe_vertex",
            fragmentFunction: "wireframe_fragment",
            colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: depthFormat,
            stencilPixelFormat: depthFormat,
            sampleCount: sampleCount,
            blending: .sourceOver,
            vertexDescriptor: vertexDescriptor
        )
    }

    /// Quad-expanded wireframe pipeline (variable width + dash patterns).
    ///
    /// Uses a dedicated descriptor for endpoint, arc-length, corner, and direction attributes
    /// with the `quad_edge_vertex` / `quad_edge_fragment` shaders.
    static func makeQuadEdgePipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        sampleCount: Int,
        depthFormat: MTLPixelFormat,
        vertexDescriptor: MTLVertexDescriptor,
        label: String? = nil
    ) -> MTLRenderPipelineState? {
        makePipelineState(
            device: device,
            label: label,
            library: library,
            vertexFunction: "quad_edge_vertex",
            fragmentFunction: "quad_edge_fragment",
            colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: depthFormat,
            stencilPixelFormat: depthFormat,
            sampleCount: sampleCount,
            blending: .sourceOver,
            vertexDescriptor: vertexDescriptor
        )
    }

    /// Adaptive instanced dot-grid pipeline (no vertex descriptor: instanced from `[[vertex_id]]`).
    static func makeGridPipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        sampleCount: Int,
        depthFormat: MTLPixelFormat,
        label: String? = nil
    ) -> MTLRenderPipelineState? {
        makePipelineState(
            device: device,
            label: label,
            library: library,
            vertexFunction: "grid_vertex",
            fragmentFunction: "grid_fragment",
            colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: depthFormat,
            stencilPixelFormat: depthFormat,
            sampleCount: sampleCount
        )
    }

    /// Coordinate-axis and `.plane` grid pipeline: unlit position + colour vertices.
    ///
    /// Source-alpha blended with "over" alpha so the `.plane` grid's translucent fill composites
    /// without punching a hole in the target's alpha; opaque colours (the axes, the grid lines)
    /// are unaffected.
    static func makeAxisPipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        sampleCount: Int,
        depthFormat: MTLPixelFormat,
        label: String? = nil
    ) -> MTLRenderPipelineState? {
        makePipelineState(
            device: device,
            label: label,
            library: library,
            vertexFunction: "axis_vertex",
            fragmentFunction: "axis_fragment",
            colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: depthFormat,
            stencilPixelFormat: depthFormat,
            sampleCount: sampleCount,
            blending: .sourceOver,
            vertexDescriptor: axisVertexDescriptor()
        )
    }

    /// Visible point-cloud pipeline (issue #28).
    ///
    /// No vertex descriptor: the shader reads positions and per-point colours via `[[vertex_id]]`
    /// so the position buffer stays tightly packed (stride 12).
    static func makeVisiblePointPipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        sampleCount: Int,
        depthFormat: MTLPixelFormat,
        label: String? = nil
    ) -> MTLRenderPipelineState? {
        makePipelineState(
            device: device,
            label: label,
            library: library,
            vertexFunction: "visible_point_vertex",
            fragmentFunction: "visible_point_fragment",
            colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: depthFormat,
            stencilPixelFormat: depthFormat,
            sampleCount: sampleCount,
            blending: .sourceOver
        )
    }

    /// Shadow-map pipeline (depth-only, from the light's point of view).
    ///
    /// Pass `directMeshVertexDescriptor()` for the direct-mesh sibling: the shadow shader reads only
    /// position, and the normal binding just satisfies the descriptor's attribute 1.
    ///
    /// The fragment stage discards geometry behind the section clip planes (#162), so the shadow
    /// pass must bind the frame's `Uniforms` at fragment buffer 1.
    static func makeShadowPipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        vertexDescriptor: MTLVertexDescriptor,
        label: String? = nil
    ) -> MTLRenderPipelineState? {
        makePipelineState(
            device: device,
            label: label,
            library: library,
            vertexFunction: "shadow_vertex",
            fragmentFunction: "shadow_clip_fragment",
            depthPixelFormat: .depth32Float,
            vertexDescriptor: vertexDescriptor
        )
    }

    /// Per-triangle highlight pipeline (issue #25): composites `ViewportBody.triangleStyles` over
    /// the shaded surface.
    ///
    /// Pass `directMeshVertexDescriptor()` for direct-mesh bodies.
    static func makeHighlightPipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        sampleCount: Int,
        depthFormat: MTLPixelFormat,
        vertexDescriptor: MTLVertexDescriptor,
        label: String? = nil
    ) -> MTLRenderPipelineState? {
        makePipelineState(
            device: device,
            label: label,
            library: library,
            vertexFunction: "highlight_vertex",
            fragmentFunction: "highlight_fragment",
            colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: depthFormat,
            stencilPixelFormat: depthFormat,
            sampleCount: sampleCount,
            blending: .sourceOver,
            vertexDescriptor: vertexDescriptor
        )
    }

    /// Stencil-only mask pipeline: rasterises a body into the main pass without writing colour.
    ///
    /// Paired with `makeStencilMarkState(device:)` it marks each selected or hovered body's whole
    /// silhouette, in every display mode and at any opacity, so the selection outline rings it.
    /// Honours section planes; bind `Uniforms` at vertex and
    /// fragment buffer 1. Pass `directMeshVertexDescriptor()` for direct-mesh bodies.
    static func makeStencilMaskPipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        sampleCount: Int,
        depthFormat: MTLPixelFormat,
        vertexDescriptor: MTLVertexDescriptor,
        label: String? = nil
    ) -> MTLRenderPipelineState? {
        let descriptor = renderPipelineDescriptor(
            label: label,
            library: library,
            vertexFunction: "depth_only_vertex",
            fragmentFunction: "depth_only_clip_fragment",
            colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: depthFormat,
            stencilPixelFormat: depthFormat,
            sampleCount: sampleCount,
            vertexDescriptor: vertexDescriptor
        )
        descriptor.colorAttachments[0].writeMask = []
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// HDR skybox background pipeline (full-screen triangle sampling the environment cube map).
    static func makeSkyboxPipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        sampleCount: Int,
        depthFormat: MTLPixelFormat,
        label: String? = nil
    ) -> MTLRenderPipelineState? {
        makePipelineState(
            device: device,
            label: label,
            library: library,
            vertexFunction: "skybox_vertex",
            fragmentFunction: "skybox_fragment",
            colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: depthFormat,
            stencilPixelFormat: depthFormat,
            sampleCount: sampleCount
        )
    }

    /// Encodes the skybox background; the caller restores its own depth state afterwards.
    ///
    /// `depthState` should be always-pass with no depth writes, so later geometry overwrites it.
    static func encodeSkybox(
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        depthState: MTLDepthStencilState,
        viewProjection: simd_float4x4,
        lighting: LightingConfiguration,
        cubeMap: MTLTexture
    ) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        var skyUniforms = SkyboxUniformsSwift(
            inverseViewProjection: simd_inverse(viewProjection),
            // z = mip level: 0 for a sharp background. w = tone-map scale (exposure / whitePoint).
            params: SIMD4<Float>(
                lighting.environmentRotationY, lighting.backgroundExposure, 0,
                lighting.exposure / max(lighting.whitePoint, 0.01))
        )
        encoder.setVertexBytes(
            &skyUniforms, length: MemoryLayout<SkyboxUniformsSwift>.size, index: 0)
        encoder.setFragmentBytes(
            &skyUniforms, length: MemoryLayout<SkyboxUniformsSwift>.size, index: 0)
        encoder.setFragmentTexture(cubeMap, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Single-sample depth-only pipeline for the SSAO / silhouette depth prepass.
    ///
    /// Pass `directMeshVertexDescriptor()` for the direct-mesh sibling.
    static func makeDepthOnlyPipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        vertexDescriptor: MTLVertexDescriptor,
        label: String? = nil
    ) -> MTLRenderPipelineState? {
        makePipelineState(
            device: device,
            label: label,
            library: library,
            vertexFunction: "depth_only_vertex",
            // Discards fragments behind section planes; bind `Uniforms` at fragment buffer 1.
            fragmentFunction: "depth_only_clip_fragment",
            depthPixelFormat: .depth32Float,
            vertexDescriptor: vertexDescriptor
        )
    }

    /// Full-screen SSAO + silhouette composite pipeline (single sample, no depth attachment).
    ///
    /// `ssao_fragment` also applies depth of field and ACES tone mapping, so whatever this pass
    /// writes is the frame's final colour.
    static func makeSSAOCompositePipelineState(
        device: MTLDevice,
        library: MTLLibrary,
        label: String? = nil
    ) -> MTLRenderPipelineState? {
        makePipelineState(
            device: device,
            label: label,
            library: library,
            vertexFunction: "fullscreen_vertex",
            fragmentFunction: "ssao_fragment",
            colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: .invalid
        )
    }

    // MARK: - Depth States

    /// Builds a depth-stencil state with no stencil operations.
    static func makeDepthStencilState(
        device: MTLDevice,
        compareFunction: MTLCompareFunction,
        isDepthWriteEnabled: Bool
    ) -> MTLDepthStencilState? {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = compareFunction
        descriptor.isDepthWriteEnabled = isDepthWriteEnabled
        return device.makeDepthStencilState(descriptor: descriptor)
    }

    /// Depth always-pass without writes, drawing only where stencil differs from the reference.
    ///
    /// That is the ring the selection outline occupies around a stencil-marked body.
    static func makeStencilTestState(device: MTLDevice) -> MTLDepthStencilState? {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = false
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .notEqual
        stencil.stencilFailureOperation = .keep
        stencil.depthStencilPassOperation = .keep
        stencil.depthFailureOperation = .keep
        descriptor.frontFaceStencil = stencil
        descriptor.backFaceStencil = stencil
        return device.makeDepthStencilState(descriptor: descriptor)
    }

    /// Depth always-pass without writes, setting stencil to the reference value wherever a body
    /// rasterises: marks a selected body's whole silhouette for the outline without occluding
    /// anything.
    ///
    /// The mask ignores depth so it also covers the parts of the body hidden behind nearer
    /// geometry (another body, grid dots). Depth-tested, it left those parts unmarked, and the
    /// outline, which is drawn wherever the stencil is unmarked, painted over the occluder across
    /// the whole hidden area instead of a ring (#177).
    static func makeStencilMarkState(device: MTLDevice) -> MTLDepthStencilState? {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = false
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .always
        stencil.depthStencilPassOperation = .replace
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        descriptor.frontFaceStencil = stencil
        descriptor.backFaceStencil = stencil
        return device.makeDepthStencilState(descriptor: descriptor)
    }

    // MARK: - Clip Planes

    /// Packs the planes `ClipPlane.activePlanes(in:)` applies into the shader's four uniform slots.
    ///
    /// - Returns: The four plane slots (unused ones zero) and how many are active.
    static func packClipPlanes(
        _ planes: [ClipPlane]
    ) -> (planes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>), count: UInt32) {
        var active = ClipPlane.activePlanes(in: planes).applied.map(\.asFloat4)
        let count = UInt32(active.count)
        while active.count < 4 { active.append(.zero) }
        return ((active[0], active[1], active[2], active[3]), count)
    }

    // MARK: - Shared Resources

    /// Generates the procedural studio matcap texture (RGBA8) both renderers sample.
    static func makeMatcapTexture(device: MTLDevice, size: Int = 256) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                // Map pixel to [-1, 1] UV space.
                let u = (Float(x) + 0.5) / Float(size) * 2.0 - 1.0
                let v = (Float(y) + 0.5) / Float(size) * 2.0 - 1.0
                let r2 = u * u + v * v

                var r: Float = 0.1
                var g: Float = 0.1
                var b: Float = 0.1

                if r2 <= 1.0 {
                    // Reconstruct the view-space normal from UV.
                    let nz = sqrt(1.0 - r2)
                    let normal = SIMD3<Float>(u, -v, nz)

                    // Studio lighting: key from upper-left, fill from right.
                    let keyDir = simd_normalize(SIMD3<Float>(-0.5, 0.7, 0.5))
                    let fillDir = simd_normalize(SIMD3<Float>(0.6, 0.2, 0.7))
                    let keyDiff = max(simd_dot(normal, keyDir), 0.0) * 0.8
                    let fillDiff = max(simd_dot(normal, fillDir), 0.0) * 0.3

                    let rim = pow(1.0 - nz, 3.0) * 0.25
                    let ambient: Float = 0.18
                    let brightness = min(keyDiff + fillDiff + rim + ambient, 1.0)

                    // Slight warm-cool tint.
                    r = brightness * 1.0
                    g = brightness * 0.97
                    b = brightness * 0.95
                }

                let idx = (y * size + x) * 4
                pixels[idx + 0] = UInt8(min(max(r * 255.0, 0), 255))
                pixels[idx + 1] = UInt8(min(max(g * 255.0, 0), 255))
                pixels[idx + 2] = UInt8(min(max(b * 255.0, 0), 255))
                pixels[idx + 3] = 255
            }
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: size * 4
        )
        return texture
    }

    // MARK: - Grid and Axes

    /// Number of grid divisions the adaptive spacing aims to keep across the visible width.
    private static let gridTargetDivisions: Float = 15.0

    /// Snaps the ground grid to the `subdivisions`-power spacing level closest to the visible width.
    ///
    /// - Parameters:
    ///   - cameraState: Camera supplying the distance and field of view.
    ///   - baseSpacing: Fundamental grid unit in world units (`ViewportConfiguration.gridBaseSpacing`).
    ///   - subdivisions: Subdivision factor between levels (`ViewportConfiguration.gridSubdivisions`),
    ///     clamped to at least 2.
    /// - Returns: The world-unit spacing for the current zoom level.
    static func adaptiveGridSpacing(
        cameraState: CameraState,
        baseSpacing: Float,
        subdivisions: Int
    ) -> Float {
        let distance = cameraState.distance
        let fovRadians = cameraState.fieldOfView * .pi / 180.0
        let visibleWidth = 2.0 * distance * tan(fovRadians / 2.0)
        let idealSpacing = visibleWidth / gridTargetDivisions
        let levelBase = Float(max(subdivisions, 2))

        guard baseSpacing > 0, idealSpacing > 0 else {
            return baseSpacing > 0 ? baseSpacing : 1.0
        }

        let level = (log(idealSpacing / baseSpacing) / log(levelBase)).rounded()
        return baseSpacing * pow(levelBase, level)
    }

    /// Encodes the ground grid on the XY plane (Z-up world) in the configured `GridStyle`.
    ///
    /// The grid window centres on the camera pivot at the current adaptive spacing level and is
    /// clipped to the `gridSize` square around the world origin. `.dots` draws instanced point
    /// sprites; `.plane` draws a translucent fill (depth-tested, no depth write, so it only tints
    /// what lies behind it) plus minor/major grid lines.
    ///
    /// `dotPipeline` is the `grid_vertex` point-sprite pipeline (`.dots`); `linePipeline` the
    /// alpha-blended `axis_vertex` pipeline (`.plane`). `fillDepthState` (depth test on, write
    /// off) is used for the `.plane` fill only, after which `depthState` is restored.
    static func encodeGrid(
        encoder: MTLRenderCommandEncoder,
        dotPipeline: MTLRenderPipelineState,
        linePipeline: MTLRenderPipelineState,
        fillDepthState: MTLDepthStencilState,
        depthState: MTLDepthStencilState,
        buffers: GridAxisBuffers,
        viewProjection: simd_float4x4,
        cameraState: CameraState,
        settings: GridAxisSettings
    ) {
        let spacing = adaptiveGridSpacing(
            cameraState: cameraState,
            baseSpacing: settings.gridBaseSpacing,
            subdivisions: settings.gridSubdivisions
        )

        switch settings.gridStyle {
        case .dots:
            guard
                let window = GridAxisGeometry.gridWindow(
                    pivot: cameraState.pivot,
                    spacing: spacing,
                    halfCount: GridAxisGeometry.dotHalfCount,
                    gridSize: settings.gridSize
                )
            else { return }
            var gridUniforms = GridUniforms(
                viewProjectionMatrix: viewProjection,
                gridOrigin: window.origin,
                spacing: spacing,
                columns: window.columns,
                dotSize: max(2.0, 4.0 / cameraState.distance),
                rows: window.rows,
                dotColor: settings.gridColors.dot
            )
            encoder.setRenderPipelineState(dotPipeline)
            encoder.setVertexBytes(
                &gridUniforms, length: MemoryLayout<GridUniforms>.size, index: 0)
            encoder.setFragmentBytes(
                &gridUniforms, length: MemoryLayout<GridUniforms>.size, index: 0)
            encoder.drawPrimitives(
                type: .point,
                vertexStart: 0,
                vertexCount: 1,
                instanceCount: Int(window.columns) * Int(window.rows)
            )

        case .plane:
            guard
                let window = GridAxisGeometry.gridWindow(
                    pivot: cameraState.pivot,
                    spacing: spacing,
                    halfCount: GridAxisGeometry.lineHalfCount,
                    gridSize: settings.gridSize
                )
            else { return }
            var axisUniforms = AxisUniforms(viewProjectionMatrix: viewProjection)
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBytes(
                &axisUniforms, length: MemoryLayout<AxisUniforms>.size, index: 1)

            var fill = GridAxisGeometry.gridFillVertices(window: window)
            encoder.setDepthStencilState(fillDepthState)
            encoder.setVertexBytes(
                &fill, length: fill.count * MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.setDepthStencilState(depthState)

            if let lines = buffers.gridLines(
                window: window, subdivisions: settings.gridSubdivisions,
                colors: settings.gridColors)
            {
                encoder.setVertexBuffer(lines.buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lines.vertexCount)
            }
        }
    }

    /// Encodes the world axes from the origin: X red, Y green, Z blue, `axisLength` long.
    ///
    /// Each axis is a cylinder of `GridAxisGeometry.axisWorldRadius(...)` (fixed for `.cylinder`,
    /// zoom-compensated for `.constantScreenWidth`) plus a 1 px centre line, so an axis whose
    /// radius falls below a pixel stays visible.
    static func encodeAxes(
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        buffers: GridAxisBuffers,
        viewProjection: simd_float4x4,
        cameraState: CameraState,
        settings: GridAxisSettings
    ) {
        let length = settings.axisLength
        guard length > 0, length.isFinite else { return }
        let radius = GridAxisGeometry.axisWorldRadius(
            style: settings.axisStyle,
            baseRadius: settings.axisRadius,
            cameraState: cameraState
        )
        encoder.setRenderPipelineState(pipeline)

        if radius > 0, radius.isFinite {
            encoder.setVertexBuffer(buffers.axisCylinders, offset: 0, index: 0)
            let count = GridAxisGeometry.verticesPerAxis
            for axis in 0..<3 {
                let model = GridAxisGeometry.axisModelMatrix(
                    axis: axis, length: length, radius: radius)
                var axisUniforms = AxisUniforms(viewProjectionMatrix: viewProjection * model)
                encoder.setVertexBytes(
                    &axisUniforms, length: MemoryLayout<AxisUniforms>.size, index: 1)
                encoder.drawPrimitives(
                    type: .triangle, vertexStart: axis * count, vertexCount: count)
            }
        }

        var lines = GridAxisGeometry.axisCenterLineVertices(length: length)
        var axisUniforms = AxisUniforms(viewProjectionMatrix: viewProjection)
        encoder.setVertexBytes(&axisUniforms, length: MemoryLayout<AxisUniforms>.size, index: 1)
        encoder.setVertexBytes(&lines, length: lines.count * MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 6)
    }

    // MARK: - Shadow Frustum

    /// World-space union of the bounds of every visible `.geometry`-layer body.
    ///
    /// Both renderers fit their near/far clip planes and the shadow frustum to this one box.
    /// `.overlay` bodies (gizmos, widgets) are left out, so one can neither stretch the depth
    /// range nor enlarge the shadow frustum and lower shadow resolution (issue #183).
    ///
    /// - Parameters:
    ///   - bodies: Scene bodies; invisible bodies, overlay bodies and bodies without bounds are
    ///     skipped.
    ///   - localBounds: A body's **local-space** box, before `transform`. Defaults to
    ///     `ViewportBody.boundingBox`, which scans the body's geometry; `ViewportRenderer` passes
    ///     its per-generation cache so a frame does not rescan every vertex.
    /// - Returns: The unioned bounds, or `nil` when no included body has any.
    static func sceneBounds(
        of bodies: [ViewportBody],
        localBounds: (ViewportBody) -> BoundingBox? = { $0.boundingBox }
    ) -> BoundingBox? {
        var bounds: BoundingBox?
        for body in bodies where body.isVisible && body.renderLayer == .geometry {
            guard let box = localBounds(body)?.transformed(by: body.transform) else { continue }
            bounds = bounds.map { $0.union(box) } ?? box
        }
        return bounds
    }

    /// Widens the camera clip-fit bounds by the visible overlay-layer bodies.
    ///
    /// The near and far planes are fitted to these bounds. Without the overlays, a widget lying
    /// in front of or behind the model (a gizmo over a flat part, a ring behind it) fell outside
    /// the fitted range and was clipped away, though it is drawn on top of everything (#170).
    /// Overlays stay out of `sceneBounds(of:localBounds:)`, which also frames the grid, the axes
    /// and the shadow map. Only overlays inside `view` count, so one parked off-screen doesn't
    /// stretch the depth range of everything that is visible, and each overlay counts only up to
    /// four model diagonals past the model.
    ///
    /// - Parameters:
    ///   - bounds: The clip-fit bounds so far (model, grid and axes).
    ///   - bodies: Scene bodies; only visible overlay-layer ones are read.
    ///   - view: The camera's frustum, with any near and far planes that enclose the scene (see
    ///     `wideViewFrustum(cameraState:aspectRatio:)`); only its sides matter.
    ///   - localBounds: A body's local-space box, before `transform`.
    /// - Returns: `bounds` widened by every in-view overlay body.
    static func clipFitBounds(
        _ bounds: BoundingBox?,
        includingOverlaysOf bodies: [ViewportBody],
        in view: Frustum,
        localBounds: (ViewportBody) -> BoundingBox? = { $0.boundingBox }
    ) -> BoundingBox? {
        // An overlay may reach at most a few model sizes past the model, so a huge widget (an
        // axis line 1e5 long) can't push `far`, and with it the `far * 1e-4` floor under `near`,
        // out until the model itself is clipped.
        let limit: BoundingBox? = bounds.map { model in
            let pad = SIMD3<Float>(repeating: max(model.diagonalLength, 1e-3) * 4)
            return BoundingBox(min: model.min - pad, max: model.max + pad)
        }
        var result = bounds
        for body in bodies where body.isVisible && body.renderLayer == .overlay {
            guard var box = localBounds(body)?.transformed(by: body.transform),
                view.intersects(box)
            else { continue }
            if let limit {
                box = BoundingBox(
                    min: simd_clamp(box.min, limit.min, limit.max),
                    max: simd_clamp(box.max, limit.min, limit.max))
            }
            result = result.map { $0.union(box) } ?? box
        }
        return result
    }

    /// The camera's view frustum with near and far planes far enough apart to hold any scene,
    /// for deciding what lies in view before the clip planes are fitted.
    static func wideViewFrustum(cameraState: CameraState, aspectRatio: Float) -> Frustum {
        Frustum(
            viewProjection: cameraState.projectionMatrix(
                aspectRatio: aspectRatio, near: 1e-3, far: 1e7) * cameraState.viewMatrix)
    }

    /// Computes an orthographic light view-projection matrix that encompasses the scene.
    ///
    /// - Parameters:
    ///   - lightDirection: Direction the key light points in (need not be normalized).
    ///   - sceneBounds: Bounds to cover; `nil` falls back to a ±5 world-unit box so an empty scene
    ///     still produces a usable matrix.
    /// - Returns: `lightProjection * lightView` for the shadow pass.
    static func lightViewProjection(
        lightDirection: SIMD3<Float>,
        sceneBounds: BoundingBox?
    ) -> simd_float4x4 {
        let bounds =
            sceneBounds
            ?? BoundingBox(min: SIMD3<Float>(-5, -5, -5), max: SIMD3<Float>(5, 5, 5))
        let center = (bounds.min + bounds.max) * 0.5
        let extents = bounds.max - bounds.min
        let radius = simd_length(extents) * 0.5

        // Look at the scene centre from along the light direction.
        let dir = simd_normalize(lightDirection)
        let lightPos = center - dir * (radius * 2.0)

        // Pick an up vector that isn't parallel to the light direction.
        let tentativeUp = SIMD3<Float>(0, 1, 0)
        let up: SIMD3<Float> =
            abs(simd_dot(dir, tentativeUp)) > 0.99 ? SIMD3<Float>(0, 0, 1) : tentativeUp

        let lightView = simd_float4x4.lookAt(eye: lightPos, target: center, up: up)

        // Orthographic projection covering the scene sphere.
        let orthoSize = radius * 1.5
        let lightProj = simd_float4x4.orthographic(
            left: -orthoSize,
            right: orthoSize,
            bottom: -orthoSize,
            top: orthoSize,
            near: 0.01,
            far: radius * 4.0
        )

        return lightProj * lightView
    }
}
