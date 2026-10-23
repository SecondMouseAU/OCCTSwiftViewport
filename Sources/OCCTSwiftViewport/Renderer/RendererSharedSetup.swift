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

        /// Straight source-alpha blending on both the colour and alpha channels.
        case sourceAlpha

        /// Source-alpha colour blending with additive alpha accumulation (point sprites).
        case sourceAlphaAccumulatingAlpha

        /// Source-alpha colour blending only; the alpha channel keeps Metal's default factors.
        case sourceAlphaColorOnly
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

    private static func apply(
        _ blending: ColorBlending,
        to attachment: MTLRenderPipelineColorAttachmentDescriptor
    ) {
        switch blending {
        case .disabled:
            return
        case .sourceAlpha:
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .sourceAlphaAccumulatingAlpha:
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .sourceAlphaColorOnly:
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
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
            blending: .sourceAlpha,
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
            blending: .sourceAlpha,
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
            blending: .sourceAlpha,
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
            blending: .sourceAlphaAccumulatingAlpha,
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
            blending: .sourceAlphaAccumulatingAlpha
        )
    }

    /// Shadow-map pipeline (depth-only, from the light's point of view).
    ///
    /// Pass `directMeshVertexDescriptor()` for the direct-mesh sibling: the shadow shader reads only
    /// position, and the normal binding just satisfies the descriptor's attribute 1.
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
            fragmentFunction: "depth_only_fragment",
            depthPixelFormat: .depth32Float,
            vertexDescriptor: vertexDescriptor
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
                dotColor: GridAxisGeometry.dotColor
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
                window: window, subdivisions: settings.gridSubdivisions)
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

    /// Unions the bounds of every visible body, optionally in world space.
    ///
    /// - Parameters:
    ///   - bodies: Scene bodies; invisible bodies and bodies without bounds are skipped.
    ///   - applyingTransforms: `true` unions world-space bounds (each body's local box transformed by
    ///     its `transform`), `false` unions the raw local boxes. `OffscreenRenderer` passes `true`;
    ///     `ViewportRenderer`'s shadow pass has always passed `false`, so it keeps doing so here
    ///     rather than silently changing what the live viewport renders.
    /// - Returns: The unioned bounds, or `nil` when no visible body has any.
    static func sceneBounds(of bodies: [ViewportBody], applyingTransforms: Bool) -> BoundingBox? {
        var bounds: BoundingBox?
        for body in bodies where body.isVisible {
            guard let box = body.boundingBox else { continue }
            let candidate = applyingTransforms ? box.transformed(by: body.transform) : box
            bounds = bounds.map { $0.union(candidate) } ?? candidate
        }
        return bounds
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
