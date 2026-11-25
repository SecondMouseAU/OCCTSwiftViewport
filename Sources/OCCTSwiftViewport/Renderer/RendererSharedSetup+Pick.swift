// RendererSharedSetup+Pick.swift
// OCCTSwiftViewport
//
// The 1x GPU pick pass shared by ViewportRenderer and OffscreenRenderer: its pipelines, its
// attachments, and the one function that encodes every body kind into the RG32Uint pick texture.

@preconcurrency import Metal
import simd

// MARK: - Pipelines

/// The pipelines of the 1x pick pass (RG32Uint colour, `depth32Float`, no MSAA).
///
/// The always-built set comes from `init(device:library:)`; the tessellated and mesh-shader face
/// pipelines depend on the maximum tessellation factor and the device, so each renderer assigns
/// them when it builds its refined surface paths.
struct PickPipelines {

    /// Colour format of the pick texture.
    static let colorPixelFormat: MTLPixelFormat = .rg32Uint

    /// Depth format of the pick pass.
    static let depthPixelFormat: MTLPixelFormat = .depth32Float

    /// Face pick, interleaved vertices.
    let shaded: MTLRenderPipelineState

    /// Face pick for direct-mesh bodies: `pick_vertex` with the two-buffer descriptor (position@0,
    /// normal@2), so a body from `ViewportBody.directMesh(...)` is stamped without an interleave.
    let shadedDirect: MTLRenderPipelineState

    /// Edge pick as native lines.
    ///
    /// `pick_line_vertex` carries `wireframe_vertex`'s depth bias, so an edge wins the pick over
    /// the face it lies on (#182).
    let line: MTLRenderPipelineState?

    /// Arc pick as native lines; stamps the arc index rather than the segment index.
    let arc: MTLRenderPipelineState?

    /// Edge and arc pick as quads as wide as the visible edge.
    let quadEdge: MTLRenderPipelineState?

    /// Vertex pick as point sprites.
    let point: MTLRenderPipelineState?

    /// `.lessEqual` with depth writes: edges and points co-planar with a face win the pick.
    let edgeOrPointDepthState: MTLDepthStencilState

    /// Face pick on the PN-tessellated surface; `nil` when the render does not tessellate.
    var tessellated: MTLRenderPipelineState?

    /// Face pick on the mesh-shader surface; `nil` when the render does not use mesh shaders.
    var meshShader: MTLRenderPipelineState?

    /// Builds the pipelines every render needs. `nil` when a face pipeline or the depth state
    /// cannot be made.
    init?(device: MTLDevice, library: MTLLibrary) {
        let vertexDescriptor = RendererSharedSetup.interleavedVertexDescriptor()
        let directVertexDescriptor = RendererSharedSetup.directMeshVertexDescriptor()

        func make(
            _ label: String, _ vertexFunction: String, _ fragmentFunction: String,
            _ descriptor: MTLVertexDescriptor
        ) -> MTLRenderPipelineState? {
            RendererSharedSetup.makePipelineState(
                device: device, label: label, library: library,
                vertexFunction: vertexFunction, fragmentFunction: fragmentFunction,
                colorPixelFormat: Self.colorPixelFormat, depthPixelFormat: Self.depthPixelFormat,
                vertexDescriptor: descriptor)
        }

        guard let shaded = make("pick_shaded", "pick_vertex", "pick_fragment", vertexDescriptor),
            let shadedDirect = make(
                "pick_shaded_direct", "pick_vertex", "pick_fragment", directVertexDescriptor),
            let depthState = RendererSharedSetup.makeDepthStencilState(
                device: device, compareFunction: .lessEqual, isDepthWriteEnabled: true)
        else { return nil }
        self.shaded = shaded
        self.shadedDirect = shadedDirect
        self.edgeOrPointDepthState = depthState
        // pick_line_vertex applies wireframe_vertex's depth bias (#182); the arc fragment stamps
        // the per-draw arc index (#48).
        self.line = make("pick_line", "pick_line_vertex", "pick_line_fragment", vertexDescriptor)
        self.arc = make("pick_arc", "pick_line_vertex", "pick_arc_fragment", vertexDescriptor)
        // quad_edge_vertex expands segments to the visible width; the fragment stamps the segment
        // (or arc) index.
        self.quadEdge = RendererSharedSetup.makePipelineState(
            device: device, label: "pick_quad_edge", library: library,
            vertexFunction: "quad_edge_vertex", fragmentFunction: "pick_quad_edge_fragment",
            colorPixelFormat: Self.colorPixelFormat, depthPixelFormat: Self.depthPixelFormat,
            vertexDescriptor: RendererSharedSetup.quadEdgeVertexDescriptor())
        // pick_point_vertex sets point_size for a clickable footprint; the fragment stamps kind 2.
        self.point = make(
            "pick_point", "pick_point_vertex", "pick_point_fragment", vertexDescriptor)
    }
}

extension RendererSharedSetup {

    /// The mesh-shader face-pick pipeline: `meshlet_pick_mesh` + `meshlet_pick_fragment`.
    static func makeMeshShaderPickPipelineState(
        device: MTLDevice, library: MTLLibrary, label: String = "mesh_pick"
    ) throws -> MTLRenderPipelineState {
        try makeMeshShaderPipelineState(
            device: device, library: library, meshFunction: "meshlet_pick_mesh",
            fragmentFunction: "meshlet_pick_fragment",
            colorPixelFormat: PickPipelines.colorPixelFormat,
            depthPixelFormat: PickPipelines.depthPixelFormat, label: label)
    }

    /// A `depth32Float` attachment for the pick pass.
    static func makePickDepthTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: PickPipelines.depthPixelFormat, width: width, height: height,
            mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        descriptor.sampleCount = 1
        return device.makeTexture(descriptor: descriptor)
    }

    /// The pick pass descriptor: colour cleared to `PickEncoding.noHit` and kept, depth cleared.
    static func makePickPassDescriptor(
        color: MTLTexture, depth: MTLTexture
    ) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // R and G both 0xFFFF_FFFF: no object, no primitive (`PickEncoding.noHit`).
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(PickEncoding.noObject), green: Double(PickEncoding.noObject), blue: 0,
            alpha: 0)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1.0
        return pass
    }
}

// MARK: - What is stamped

/// Which kinds of a body the pick pass stamps in a display mode.
///
/// The one place that decides what the pass stamps. A kind is stamped only if it is in
/// `pickableKinds` (`PickingConfiguration.pickableKinds`, every kind by default) and, with
/// `followsDisplayMode` (`PickingConfiguration.followsDisplayMode`, the default), the mode draws
/// it, so a hidden one cannot win a pick; without it, every kind a body carries is stamped in
/// every mode. Vertices are stamped either way. Each renderer builds one and hands it to both the
/// arc sampling (`samplesHiddenArcs`) and the pass (`PickPassFrame.stamping`).
struct PickStampRules: Equatable, Sendable {
    var displayMode: DisplayMode
    var followsDisplayMode: Bool
    /// The kinds the app wants picked; a kind outside it is never stamped.
    var pickableKinds: Set<PrimitiveKind> = Set(PrimitiveKind.allCases)

    /// Whether the frame's arc sampling must include the arcs the mode does not draw, because
    /// the pass stamps them (`RendererSharedBuffers.sampleArcs(includeHidden:)`).
    var samplesHiddenArcs: Bool {
        !followsDisplayMode
    }

    /// Faces, and a heightfield's surface.
    var stampsSurfaces: Bool {
        pickableKinds.contains(.face) && (!followsDisplayMode || displayMode.showsSurfaces)
    }

    /// Whether a geometry body's surface is stamped as a blank occluder.
    ///
    /// A blank occluder is written with `PickEncoding.noObject`, which hides what is behind it
    /// and picks as a miss. That is a face the app left out of `pickableKinds` in a mode that
    /// draws surfaces, so the edges and vertices behind it stay hidden as they are drawn.
    var stampsBlankSurfaces: Bool {
        !pickableKinds.contains(.face) && displayMode.showsSurfaces
    }

    /// An overlay body's faces, which are stamped in every display mode.
    var stampsOverlaySurfaces: Bool {
        pickableKinds.contains(.face)
    }

    /// A body's edge polylines and arcs; `bodyHasMesh` is whether it has a triangle mesh.
    func stampsEdges(bodyHasMesh: Bool) -> Bool {
        pickableKinds.contains(.edge)
            && (!followsDisplayMode || displayMode.drawsEdges(bodyHasMesh: bodyHasMesh))
    }

    /// One of the frame's sampled arcs: any arc the frame sampled when the setting is off, and
    /// the drawn ones otherwise.
    func stampsArc(_ arc: RendererSharedBuffers.SampledArcDraw) -> Bool {
        pickableKinds.contains(.edge) && (!followsDisplayMode || arc.isDrawn)
    }

    /// A body's vertices and a point-cloud body's points.
    var stampsVertices: Bool {
        pickableKinds.contains(.vertex)
    }

    /// A heightfield's lattice lines, which stand for its surface where the surface is not
    /// stamped (`.wireframe`); with the surface stamped they would add nothing.
    var stampsHeightfieldLattice: Bool {
        pickableKinds.contains(.face) && followsDisplayMode
            && HeightfieldDrawSet.drawsLattice(in: displayMode)
    }

    /// These rules for `body`: a body on `PickLayer.widget` is outside `pickableKinds`, as it is
    /// outside `selectionFilter`, so a manipulator keeps its edges and vertices when the app
    /// picks faces only.
    func rules(for body: ViewportBody) -> PickStampRules {
        guard body.pickLayer == .widget else { return self }
        var rules = self
        rules.pickableKinds = Set(PrimitiveKind.allCases)
        return rules
    }
}

// MARK: - Pass inputs

/// The GPU buffers of one body that the pick pass draws, whichever renderer cached them.
struct PickPassBuffers {
    var vertexBuffer: MTLBuffer?
    /// De-interleaved normals; non-nil only for a direct-mesh body (`vertexBuffer` is then
    /// positions alone).
    var normalBuffer: MTLBuffer?
    var indexBuffer: MTLBuffer?
    var indexCount = 0
    var edgeVertexBuffer: MTLBuffer?
    /// Native line segments in `edgeVertexBuffer`.
    var edgePrimitiveCount = 0
    var quadEdgeVertexBuffer: MTLBuffer?
    var quadEdgeVertexCount = 0
    /// `body.vertices` as stride-6 point-sprite vertices (position + zeroed normal).
    var pointVertexBuffer: MTLBuffer?
    var pointVertexCount = 0
    var tessellation: TessellationBuffers?
    var meshlets: MeshletBuffers?

    /// Whether the body has a triangle mesh to stamp.
    var hasMesh: Bool {
        vertexBuffer != nil && indexBuffer != nil && indexCount > 0
    }
}

/// One visible body of the pick pass, with the draw-order index its texels carry.
struct PickPassBody {
    let body: ViewportBody
    /// Ordinal among the visible bodies in draw order; what `PickResult.bodyIndex` reports.
    let objectIndex: UInt32
    let buffers: PickPassBuffers
    /// The planned tiles of a heightfield body, which has no mesh buffers.
    var heightfield: HeightfieldDrawSet?
}

/// Everything the pick pass reads besides the bodies.
struct PickPassFrame {
    var pipelines: PickPipelines
    /// `.less` with depth writes: the face stamps.
    var depthState: MTLDepthStencilState
    /// Always-pass without writes: overlay bodies win over the geometry they are drawn on.
    var overlayDepthState: MTLDepthStencilState
    /// What the pass stamps for the frame's display mode.
    var stamping: PickStampRules
    /// Stamp faces through the mesh-shader pipeline where a body has meshlets.
    var useMeshShaders: Bool
    /// Stamp faces through the tessellated pipeline where a body has patches.
    var useTessellation: Bool
    var edgeConfiguration: EdgeLineConfiguration
    /// Render-target size in pixels.
    var viewportSize: SIMD2<Float>
    /// Drawable pixels per point; scales the vertex sprite and the minimum edge width.
    var contentScale: Float
    /// The frame's sampled arcs, with the buffers their vertex ranges index.
    var arcs: [RendererSharedBuffers.SampledArcDraw] = []
    var arcLineBuffer: MTLBuffer?
    var arcQuadBuffer: MTLBuffer?
    /// The frame's scene uniforms; the pass sets `modelMatrix` per draw.
    var makeUniforms: () -> Uniforms
}

// MARK: - Encoding

extension RendererSharedSetup {

    /// Encodes the 1x pick pass into `encoder`.
    ///
    /// Every pickable body's faces, edges, arcs and vertices are stamped into the RG32Uint
    /// attachment as `PickEncoding` packs them, the faces and edges that `frame.stamping` allows
    /// for the display mode.
    ///
    /// Both renderers call this, so a headless pick and a live one cannot drift apart. `bodies`
    /// lists every visible body in draw order, including ones with no mesh, so arc-only bodies
    /// still stamp their arcs; a body that is not pickable keeps its `objectIndex` but stamps
    /// nothing. The caller owns the encoder and ends it.
    static func encodePickPass(
        encoder pickEncoder: MTLRenderCommandEncoder, bodies: [PickPassBody],
        frame: PickPassFrame
    ) {
        let pipelines = frame.pipelines
        let stamping = frame.stamping
        let makeUniforms = frame.makeUniforms
        pickEncoder.setDepthStencilState(frame.depthState)

        // Faces. By default only when the display mode draws surfaces, so hidden ones
        // (`.wireframe`) can't win a pick. Overlay bodies are stamped in the overlay loop below.
        // A face the app left out of `pickableKinds` is stamped as a blank occluder where the mode
        // draws surfaces: it hides what is behind it and picks as a miss.
        for entry in bodies where entry.body.isPickable && entry.body.renderLayer != .overlay {
            let body = entry.body
            let buffers = entry.buffers
            let rules = stamping.rules(for: body)
            guard rules.stampsSurfaces || rules.stampsBlankSurfaces else { continue }
            let faceObjectIndex = rules.stampsSurfaces ? entry.objectIndex : PickEncoding.noObject
            if let heightfield = entry.heightfield {
                // A heightfield stamps its cell index. `.wireframe` draws no surface, so by
                // default only its lattice is stamped, below.
                guard let pipeline = heightfield.pickPipeline.value else { continue }
                var uniforms = makeUniforms()
                uniforms.modelMatrix = body.transform
                var bodyUniforms = BodyUniforms(body: body, objectIndex: faceObjectIndex)
                heightfield.encodePick(
                    encoder: pickEncoder, pipeline: pipeline, uniforms: &uniforms,
                    bodyUniforms: &bodyUniforms)
                continue
            }
            guard buffers.hasMesh, let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer
            else { continue }
            var uniforms = makeUniforms()
            uniforms.modelMatrix = body.transform
            var bodyUniforms = BodyUniforms(body: body, objectIndex: faceObjectIndex)

            if frame.useMeshShaders, let ml = buffers.meshlets,
                let msPipeline = pipelines.meshShader
            {
                pickEncoder.setFragmentBytes(
                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                pickEncoder.setFragmentBytes(
                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                encodeMeshletDraw(
                    encoder: pickEncoder, pipeline: msPipeline, meshlets: ml, uniforms: &uniforms)
            } else if frame.useTessellation, let tess = buffers.tessellation,
                let tessPipeline = pipelines.tessellated
            {
                pickEncoder.setFragmentBytes(
                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                pickEncoder.setFragmentBytes(
                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                encodeTessellatedDraw(
                    encoder: pickEncoder, pipeline: tessPipeline, tessellation: tess,
                    uniforms: &uniforms)
            } else {
                encodeFaceStamp(
                    pickEncoder, pipelines: pipelines, vertexBuffer: vb,
                    normalBuffer: buffers.normalBuffer, indexBuffer: ib,
                    indexCount: buffers.indexCount, uniforms: &uniforms,
                    bodyUniforms: &bodyUniforms)
            }
        }

        // Edge, arc and vertex stamps. Geometry bodies stamp them depth-tested (`.lessEqual`, so
        // edges co-planar with a face and vertices on an edge win the tie); overlay bodies stamp
        // them in the overlay loop below. With quad expansion on, edges and arcs are picked as
        // quads as wide as the visible edge (at least 1 pt), not as 1 px lines. The fragments
        // encode kind=1 with the line-segment (or arc) index, and kind=2 with the vertex index.
        let edgeConfig = frame.edgeConfiguration
        let quadPickPipeline = edgeConfig.useQuadExpansion ? pipelines.quadEdge : nil
        let pickEdgeWidth = max(edgeConfig.width, frame.contentScale)

        /// Stamps a body's edge polylines, as the visible edge pass draws them.
        func stampEdges(_ entry: PickPassBody) {
            let body = entry.body
            let buffers = entry.buffers
            guard let edgeVB = buffers.edgeVertexBuffer, buffers.edgePrimitiveCount > 0
            else { return }
            // Only the segments `edgeDrawRange` shows can be picked (#140).
            let edgeSegments = EdgeSegmentStyle.drawnRange(
                body.edgeDrawRange, segmentCount: buffers.edgePrimitiveCount)
            guard !edgeSegments.isEmpty else { return }
            var uniforms = makeUniforms()
            uniforms.modelMatrix = body.transform
            var bodyUniforms = BodyUniforms(body: body, objectIndex: entry.objectIndex)
            if let quadPickPipeline, let quadEdgeVB = buffers.quadEdgeVertexBuffer,
                buffers.quadEdgeVertexCount > 0
            {
                var edgeUniforms = EdgeUniforms(
                    uniforms: uniforms, configuration: edgeConfig,
                    viewportSize: frame.viewportSize, width: pickEdgeWidth)
                // Segment = the slice's first segment + triangle / 6.
                var primSource = SIMD2<UInt32>(UInt32(edgeSegments.lowerBound), 0)
                pickEncoder.setRenderPipelineState(quadPickPipeline)
                pickEncoder.setVertexBuffer(quadEdgeVB, offset: 0, index: 0)
                pickEncoder.setVertexBytes(
                    &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                pickEncoder.setFragmentBytes(
                    &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                pickEncoder.setFragmentBytes(
                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                pickEncoder.setFragmentBytes(
                    &primSource, length: MemoryLayout<SIMD2<UInt32>>.size, index: 3)
                let slice = EdgeSegmentStyle.quadVertexSlice(edgeSegments)
                pickEncoder.drawPrimitives(
                    type: .triangleStrip, vertexStart: slice.start, vertexCount: slice.count)
                return
            }
            guard let pickLinePipeline = pipelines.line else { return }
            pickEncoder.setRenderPipelineState(pickLinePipeline)
            pickEncoder.setVertexBuffer(edgeVB, offset: 0, index: 0)
            pickEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            pickEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            pickEncoder.setFragmentBytes(
                &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
            var firstSegment = UInt32(edgeSegments.lowerBound)
            pickEncoder.setFragmentBytes(
                &firstSegment, length: MemoryLayout<UInt32>.size, index: 3)
            let slice = EdgeSegmentStyle.nativeVertexSlice(edgeSegments)
            pickEncoder.drawPrimitives(
                type: .line, vertexStart: slice.start, vertexCount: slice.count)
        }

        /// Re-draws one of the frame's sampled arcs (from `arcQuadBuffer` or `arcLineBuffer`,
        /// ranges in `arcs`), stamping the ARC index.
        func stampArc(_ d: RendererSharedBuffers.SampledArcDraw) {
            var uniforms = makeUniforms()
            uniforms.modelMatrix = d.body.transform
            var bodyUniforms = BodyUniforms(body: d.body, objectIndex: d.objectIndex)
            let arcIndex = UInt32(truncatingIfNeeded: d.arcIndex)
            if let quadPickPipeline, let quadBuf = frame.arcQuadBuffer {
                // Quad arcs: same footprint as the visible arc (the samples drawn above).
                var edgeUniforms = EdgeUniforms(
                    uniforms: uniforms, configuration: edgeConfig,
                    viewportSize: frame.viewportSize, width: pickEdgeWidth)
                var primSource = SIMD2<UInt32>(arcIndex, 1)  // fixed arc index
                pickEncoder.setRenderPipelineState(quadPickPipeline)
                pickEncoder.setVertexBuffer(quadBuf, offset: 0, index: 0)
                pickEncoder.setVertexBytes(
                    &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                pickEncoder.setFragmentBytes(
                    &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                pickEncoder.setFragmentBytes(
                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                pickEncoder.setFragmentBytes(
                    &primSource, length: MemoryLayout<SIMD2<UInt32>>.size, index: 3)
                pickEncoder.drawPrimitives(
                    type: .triangleStrip, vertexStart: d.quadStart, vertexCount: d.quadCount)
            } else if let pickArcPipeline = pipelines.arc, let arcBuf = frame.arcLineBuffer {
                var arcPrimID = arcIndex
                pickEncoder.setRenderPipelineState(pickArcPipeline)
                pickEncoder.setVertexBuffer(arcBuf, offset: 0, index: 0)
                pickEncoder.setVertexBytes(
                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                pickEncoder.setFragmentBytes(
                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                pickEncoder.setFragmentBytes(
                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                pickEncoder.setFragmentBytes(
                    &arcPrimID, length: MemoryLayout<UInt32>.size, index: 3)
                pickEncoder.drawPrimitives(
                    type: .line, vertexStart: d.start, vertexCount: d.count)
            }
        }

        /// Stamps a body's `vertices` as point sprites with an 8 pt footprint.
        func stampVertices(_ entry: PickPassBody) {
            let buffers = entry.buffers
            guard let pickPointPipeline = pipelines.point,
                let pointVB = buffers.pointVertexBuffer, buffers.pointVertexCount > 0
            else { return }
            var uniforms = makeUniforms()
            uniforms.modelMatrix = entry.body.transform
            var bodyUniforms = BodyUniforms(body: entry.body, objectIndex: entry.objectIndex)
            // 8 pt clickable footprint, in drawable pixels.
            var pointSpriteSize = 8 * frame.contentScale
            pickEncoder.setRenderPipelineState(pickPointPipeline)
            pickEncoder.setVertexBuffer(pointVB, offset: 0, index: 0)
            pickEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            pickEncoder.setVertexBytes(
                &pointSpriteSize, length: MemoryLayout<Float>.size, index: 2)
            pickEncoder.setFragmentBytes(
                &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            pickEncoder.setFragmentBytes(
                &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
            pickEncoder.drawPrimitives(
                type: .point, vertexStart: 0, vertexCount: buffers.pointVertexCount)
        }

        // Geometry-layer edges: bodies with `edgeIndices` set, when the display mode draws their
        // edges (`.shaded` hides them, so by default they can't win a pick).
        pickEncoder.setDepthStencilState(pipelines.edgeOrPointDepthState)
        for entry in bodies
        where entry.body.renderLayer == .geometry && entry.body.isPickable
            && !entry.body.edgeIndices.isEmpty
            && stamping.rules(for: entry.body)
                .stampsEdges(bodyHasMesh: entry.buffers.indexCount > 0)
        {
            stampEdges(entry)
        }
        // Geometry-layer heightfield lattices: in `.wireframe`, a heightfield has no surface to
        // stamp, but its lattice lines are its edges. They stamp the cell under the pixel as a face
        // pick, so `PickResult.heightfield` and `refinePick` work as for a surface, and only where
        // a line is drawn, as a mesh in `.wireframe` is picked at its edges and not its faces.
        if stamping.stampsHeightfieldLattice {
            for entry in bodies
            where entry.body.renderLayer == .geometry && entry.body.isPickable {
                guard let heightfield = entry.heightfield,
                    let pipeline = heightfield.latticePickPipeline.value
                else { continue }
                var uniforms = makeUniforms()
                uniforms.modelMatrix = entry.body.transform
                var edgeUniforms = HeightfieldDrawSet.latticeEdgeUniforms(
                    uniforms: uniforms, configuration: edgeConfig,
                    viewportSize: frame.viewportSize,
                    width: edgeConfig.useQuadExpansion ? pickEdgeWidth : frame.contentScale)
                var bodyUniforms = BodyUniforms(body: entry.body, objectIndex: entry.objectIndex)
                heightfield.encodeLattice(
                    encoder: pickEncoder, pipeline: pipeline, edgeUniforms: &edgeUniforms,
                    bodyUniforms: &bodyUniforms)
            }
        }
        // Geometry-layer arcs (issue #48), each drawn separately so the fragment stamps its arc
        // index. The frame's arcs are the drawn ones, plus the hidden ones when the setting is off.
        for d in frame.arcs
        where d.body.renderLayer == .geometry && d.body.isPickable
            && stamping.rules(for: d.body).stampsArc(d)
        {
            stampArc(d)
        }
        // Geometry-layer vertices: bodies with `vertices` set.
        for entry in bodies
        where entry.body.renderLayer == .geometry && entry.body.isPickable
            && !entry.body.vertices.isEmpty && stamping.rules(for: entry.body).stampsVertices
        {
            stampVertices(entry)
        }

        // Overlay pick pass (#170): RenderLayer.overlay bodies stamp everything the overlay pass
        // draws (surfaces in every display mode, the edges and arcs the mode shows, and
        // vertices) with always-pass depth, so a widget wins the pick over geometry in front of
        // it, as it is drawn over it. With the setting off its edges and arcs are stamped in
        // every mode. Edges are stamped whether or not `edgeIndices` is set: a gizmo ring drawn
        // as a polyline is grabbed by its edges. Within a body, edges and vertices are stamped
        // after its faces so they win; a later overlay body wins over an earlier one, as it is
        // drawn over it.
        pickEncoder.setDepthStencilState(frame.overlayDepthState)
        for entry in bodies where entry.body.renderLayer == .overlay && entry.body.isPickable {
            let body = entry.body
            let buffers = entry.buffers
            let rules = stamping.rules(for: body)
            if let heightfield = entry.heightfield {
                // An overlay heightfield stamps its surface in every display mode, over the rest.
                if rules.stampsOverlaySurfaces, let pipeline = heightfield.pickPipeline.value {
                    var uniforms = makeUniforms()
                    uniforms.modelMatrix = body.transform
                    var bodyUniforms = BodyUniforms(body: body, objectIndex: entry.objectIndex)
                    heightfield.encodePick(
                        encoder: pickEncoder, pipeline: pipeline, uniforms: &uniforms,
                        bodyUniforms: &bodyUniforms)
                }
                continue
            }
            if body.primitiveKind != .point, rules.stampsOverlaySurfaces, buffers.hasMesh,
                let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer
            {
                var uniforms = makeUniforms()
                uniforms.modelMatrix = body.transform
                var bodyUniforms = BodyUniforms(body: body, objectIndex: entry.objectIndex)
                encodeFaceStamp(
                    pickEncoder, pipelines: pipelines, vertexBuffer: vb,
                    normalBuffer: buffers.normalBuffer, indexBuffer: ib,
                    indexCount: buffers.indexCount, uniforms: &uniforms,
                    bodyUniforms: &bodyUniforms)
            }
            if body.primitiveKind != .point,
                rules.stampsEdges(bodyHasMesh: buffers.hasMesh)
            {
                stampEdges(entry)
            }
            for d in frame.arcs where d.body.id == body.id && rules.stampsArc(d) {
                stampArc(d)
            }
            if rules.stampsVertices { stampVertices(entry) }
        }
    }

    /// Stamps one body's triangles as faces through the plain (untessellated) pick pipelines:
    /// `shadedDirect` for a direct-mesh body (position@0 + normal@2), `shaded` otherwise.
    private static func encodeFaceStamp(
        _ encoder: MTLRenderCommandEncoder, pipelines: PickPipelines, vertexBuffer: MTLBuffer,
        normalBuffer: MTLBuffer?, indexBuffer: MTLBuffer, indexCount: Int,
        uniforms: inout Uniforms, bodyUniforms: inout BodyUniforms
    ) {
        if let normalBuffer {
            // Direct-mesh body (Option A): position@0 + normal@2.
            encoder.setRenderPipelineState(pipelines.shadedDirect)
            encoder.setVertexBuffer(normalBuffer, offset: 0, index: 2)
        } else {
            encoder.setRenderPipelineState(pipelines.shaded)
        }
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setFragmentBytes(
            &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
        encoder.drawIndexedPrimitives(
            type: .triangle, indexCount: indexCount, indexType: .uint32,
            indexBuffer: indexBuffer, indexBufferOffset: 0)
    }
}
