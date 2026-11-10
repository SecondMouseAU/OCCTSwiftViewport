// HeightfieldRenderer.swift
// OCCTSwiftViewport
//
// GPU side of `Heightfield`: the height pyramid, dirty-tile uploads, per-tile level of detail and
// the instanced tile draws. Shared by the live and offscreen renderers.

import Foundation
@preconcurrency import Metal
import os
import simd

// MARK: - Layout

enum HeightfieldLayout {
    /// Cells along one side of a tile.
    static let tileCells = 64
    /// The coarsest level of detail: stride `1 << maxLevel` cells, one quad per tile.
    static let maxLevel = 6
    static let levelCount = maxLevel + 1

    static func tileCount(cells: Int) -> Int { (cells + tileCells - 1) / tileCells }

    /// Tiles drawn along a side: one quad spans two vertices, so `cells - 1` quads.
    static func drawTileCount(cells: Int) -> Int { max(1, (cells - 1 + tileCells - 1) / tileCells) }

    /// The level of detail whose cell stride is the largest not wider than `targetPixels` on
    /// screen, given how wide one cell is (`cellPixels`).
    static func level(cellPixels: Float, targetPixels: Float) -> Int {
        guard cellPixels > 0, targetPixels > 0 else { return maxLevel }
        let ratio = targetPixels / cellPixels
        guard ratio >= 1 else { return 0 }
        return min(maxLevel, Int(log2(ratio).rounded(.down)))
    }
}

// MARK: - Shader mirrors

/// Mirrors `HeightfieldParams` in Shaders.metal.
///
/// Stride 48.
struct HeightfieldDrawParams {
    var size: SIMD2<UInt32>
    var level: UInt32
    var quads: UInt32
    var cellSize: SIMD2<Float>
    var origin: SIMD2<Float>
    var rampMode: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

/// Mirrors `HeightfieldTile`.
///
/// Stride 16.
struct HeightfieldTileInstance {
    var origin: SIMD2<UInt32>
    var levels: UInt32
    var pad: UInt32 = 0
}

/// Mirrors `HeightfieldPyramidParams`.
///
/// Stride 32.
struct HeightfieldPyramidParams {
    var size: SIMD2<UInt32>
    var level: UInt32
    var tileTexels: UInt32
    var tileCount: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

// MARK: - Shared resources

/// What every heightfield of one renderer shares: the pyramid kernel and the per-level index
/// buffers of a tile.
final class HeightfieldShared {
    let pyramidPipeline: MTLComputePipelineState
    /// `uint16` triangle indices of an `n x n`-quad tile grid, per level (`n = 64 >> level`).
    let indexBuffers: [MTLBuffer]
    let indexCounts: [Int]

    init?(device: MTLDevice, library: MTLLibrary) {
        guard let function = library.makeFunction(name: "heightfield_build_pyramid"),
            let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        pyramidPipeline = pipeline
        var buffers: [MTLBuffer] = []
        var counts: [Int] = []
        for level in 0..<HeightfieldLayout.levelCount {
            let n = HeightfieldLayout.tileCells >> level
            var indices: [UInt16] = []
            indices.reserveCapacity(n * n * 6)
            for j in 0..<n {
                for i in 0..<n {
                    let v00 = UInt16(j * (n + 1) + i)
                    let v10 = v00 + 1
                    let v01 = v00 + UInt16(n + 1)
                    let v11 = v01 + 1
                    indices += [v00, v10, v11, v00, v11, v01]
                }
            }
            guard
                let buffer = indices.withUnsafeBytes({
                    device.makeBuffer(
                        bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                })
            else { return nil }
            buffers.append(buffer)
            counts.append(indices.count)
        }
        indexBuffers = buffers
        indexCounts = counts
    }
}

/// The render pipelines of the heightfield passes for one sample count.
struct HeightfieldPipelines {
    let shaded: MTLRenderPipelineState

    init?(device: MTLDevice, library: MTLLibrary, sampleCount: Int, depthFormat: MTLPixelFormat) {
        guard
            let shaded = RendererSharedSetup.makePipelineState(
                device: device, label: "heightfield_shaded", library: library,
                vertexFunction: "heightfield_vertex", fragmentFunction: "heightfield_fragment",
                colorPixelFormat: .bgra8Unorm, depthPixelFormat: depthFormat,
                stencilPixelFormat: depthFormat, sampleCount: sampleCount, blending: .sourceOver)
        else { return nil }
        self.shaded = shaded
    }
}

// MARK: - Frame plan

/// How the camera sees a heightfield body, for choosing each tile's level of detail.
struct HeightfieldView {
    var model: simd_float4x4
    var view: simd_float4x4
    var projection: simd_float4x4
    var viewportHeight: Float
    /// A mesh cell is at most about this wide on screen.
    var targetPixels: Float = 4
    /// Draws every tile at this level (tests).
    var forcedLevel: Int?
    /// Skips tiles outside the view frustum.
    var cull = true
    /// World-space section planes (`dot(n, p) + w < 0` is clipped); a tile wholly behind one is
    /// not drawn.
    var clipPlanes: [SIMD4<Float>] = []
}

/// The light's view of the scene, for choosing which tiles cast shadows the camera can see.
struct HeightfieldShadowView {
    var lightViewProjection: simd_float4x4
    /// The direction the light travels.
    var lightDirection: SIMD3<Float>
    /// The shadow map's side, in texels.
    var mapSize: Int
    /// How far a shadow can fall: the scene's diagonal.
    var reach: Float
    /// World bounds of the scene, which a shadow cannot leave; `nil` for unbounded.
    var sceneBounds: BoundingBox?
}

/// The tiles of one heightfield to draw this frame, grouped by level.
struct HeightfieldDrawPlan {
    var instanceBuffer: MTLBuffer?
    /// First instance and instance count per level.
    var ranges: [(first: Int, count: Int)]
    var levelHistogram: [Int]
    var tileCount: Int { levelHistogram.reduce(0, +) }
}

/// The level of detail of every tile of a heightfield for one camera, before any culling.
struct HeightfieldTileLevels {
    let cols: Int
    let rows: Int
    /// Per tile, row-major.
    var levels: [UInt8]
    /// Whether the camera's frustum reaches each tile and no section plane clips it away.
    var cameraVisible: [Bool]
    /// Whether the camera's frustum reaches each tile.
    var inFrustum: [Bool]
    /// Whether the tile is not wholly behind a section plane.
    var unclipped: [Bool]
    /// Each tile's world-space bounds.
    var worldBoxes: [BoundingBox]
    /// World size of one cell, the larger axis.
    let worldCell: Float
}

/// Everything the encoders need to draw one planned heightfield, as plain values.
///
/// Built on the main actor by `HeightfieldGPU.drawSet(plan:)`; the encoders, including the shared
/// pick pass, which is not main-actor isolated, only read it.
struct HeightfieldDrawSet {
    let plan: HeightfieldDrawPlan
    let heights: MTLTexture
    let attributes: MTLTexture
    let ramp: MTLBuffer
    let params: HeightfieldDrawParams
    let indexBuffers: [MTLBuffer]
    let indexCounts: [Int]

    /// Draws every planned tile with the shaded pipeline.
    ///
    /// The caller binds the matcap, shadow map and image-based-lighting textures (fragment
    /// slots 0 to 4) and the depth-stencil state; this binds the pipeline, the uniforms, the
    /// field's textures and ramp.
    func encodeShaded(
        encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState,
        uniforms: inout Uniforms, bodyUniforms: inout BodyUniforms
    ) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setFragmentBytes(&bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
        encoder.setVertexTexture(heights, index: 0)
        encoder.setFragmentTexture(heights, index: 5)
        encoder.setFragmentTexture(attributes, index: 6)
        encoder.setFragmentBuffer(ramp, offset: 0, index: 4)
        encodeDraws(encoder: encoder, setFragmentParams: true)
    }

    /// Stamps every planned tile into the pick target with the pick pipeline.
    ///
    /// The caller sets the depth-stencil state.
    func encodePick(
        encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState,
        uniforms: inout Uniforms, bodyUniforms: inout BodyUniforms
    ) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setFragmentBytes(&bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
        encoder.setVertexTexture(heights, index: 0)
        encodeDraws(encoder: encoder, setFragmentParams: true)
    }

    /// Draws every planned tile into the shadow map with the shadow pipeline.
    ///
    /// The fragment stage reads the scene uniforms at buffer 1, which the caller has bound for the
    /// pass.
    func encodeShadow(
        encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState,
        uniforms: inout ShadowUniformsSwift
    ) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ShadowUniformsSwift>.size, index: 1)
        encoder.setVertexTexture(heights, index: 0)
        encodeDraws(encoder: encoder, setFragmentParams: false)
    }

    /// Draws every planned tile into the SSAO and silhouette depth target.
    func encodeDepth(
        encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState,
        uniforms: inout Uniforms
    ) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setVertexTexture(heights, index: 0)
        encodeDraws(encoder: encoder, setFragmentParams: false)
    }

    /// Issues one instanced indexed draw per level of detail present, with the vertex stage's
    /// height texture and the pipeline already bound.
    func encodeDraws(encoder: MTLRenderCommandEncoder, setFragmentParams: Bool) {
        guard let instances = plan.instanceBuffer else { return }
        let stride = MemoryLayout<HeightfieldTileInstance>.stride
        for level in 0..<HeightfieldLayout.levelCount where plan.ranges[level].count > 0 {
            var drawParams = params
            drawParams.level = UInt32(level)
            drawParams.quads = UInt32(HeightfieldLayout.tileCells >> level)
            encoder.setVertexBuffer(
                instances, offset: plan.ranges[level].first * stride, index: 2)
            encoder.setVertexBytes(
                &drawParams, length: MemoryLayout<HeightfieldDrawParams>.size, index: 3)
            if setFragmentParams {
                encoder.setFragmentBytes(
                    &drawParams, length: MemoryLayout<HeightfieldDrawParams>.size, index: 3)
            }
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: indexCounts[level], indexType: .uint16,
                indexBuffer: indexBuffers[level], indexBufferOffset: 0,
                instanceCount: plan.ranges[level].count)
        }
    }
}

/// One deferred translucent surface of the sorted transparent pass: a mesh body or a heightfield.
enum TransparentSurface<Buffers> {
    case mesh(body: ViewportBody, buffers: Buffers, objectIndex: UInt32)
    case heightfield(HeightfieldRenderCache.Entry)

    /// The world position the surfaces are depth-sorted by.
    func worldCenter(meshBounds: (ViewportBody, Buffers) -> BoundingBox?) -> SIMD3<Float> {
        switch self {
        case .mesh(let body, let buffers, _):
            return RendererSharedSetup.worldCenter(
                of: meshBounds(body, buffers), transform: body.transform)
        case .heightfield(let entry):
            return RendererSharedSetup.worldCenter(
                of: entry.body.boundingBox, transform: entry.body.transform)
        }
    }
}

// MARK: - Per-renderer cache

/// What one renderer keeps for all of its heightfield bodies: the shared kernel and index
/// buffers, the pipelines per sample count, one `HeightfieldGPU` per body id, and the pool the
/// per-frame instance buffers come from.
@MainActor
final class HeightfieldRenderCache {

    /// One heightfield body to draw this frame.
    struct Entry {
        let body: ViewportBody
        /// The body's draw-order pick index (its ordinal among the visible bodies).
        let objectIndex: UInt32
        let state: HeightfieldGPU
        /// The tiles the camera sees.
        let draw: HeightfieldDrawSet
        /// The tiles whose shadows the camera can see; `nil` when shadows are off.
        let shadowDraw: HeightfieldDrawSet?
        /// Whether the field changed since this renderer last drew it.
        let changed: Bool
    }

    private let device: MTLDevice
    private let library: MTLLibrary
    private var shared: HeightfieldShared?
    private var pipelinesBySamples: [Int: HeightfieldPipelines] = [:]
    private var shadowPipeline: MTLRenderPipelineState?
    private var depthPipeline: MTLRenderPipelineState?
    private var selectionMaskPipeline: MTLRenderPipelineState?
    private var stencilPipelinesBySamples: [Int: MTLRenderPipelineState] = [:]
    private(set) var states: [String: HeightfieldGPU] = [:]
    private lazy var planPool = FrameBufferPool(device: device)

    /// Draws every tile at this level (tests).
    var forcedLevel: Int?
    /// Fields whose GPU state could not be built, so each is reported once rather than every frame.
    private var failedFields: Set<ObjectIdentifier> = []
    /// How many fields the GPU path has failed to build; exposed for tests.
    private(set) var failureCount = 0

    private static let log = Logger(subsystem: "OCCTSwiftViewport", category: "Heightfield")

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
    }

    func pipelines(sampleCount: Int, depthFormat: MTLPixelFormat) -> HeightfieldPipelines? {
        if let cached = pipelinesBySamples[sampleCount] { return cached }
        guard
            let built = HeightfieldPipelines(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat)
        else { return nil }
        pipelinesBySamples[sampleCount] = built
        return built
    }

    /// The shadow-map pipeline (depth only): `heightfield_shadow_vertex` + `shadow_clip_fragment`.
    func shadowPipelineState() -> MTLRenderPipelineState? {
        if let shadowPipeline { return shadowPipeline }
        shadowPipeline = RendererSharedSetup.makePipelineState(
            device: device, label: "heightfield_shadow", library: library,
            vertexFunction: "heightfield_shadow_vertex",
            fragmentFunction: "shadow_clip_fragment", depthPixelFormat: .depth32Float)
        return shadowPipeline
    }

    /// The SSAO and silhouette depth prepass pipeline (depth only).
    func depthPipelineState() -> MTLRenderPipelineState? {
        if let depthPipeline { return depthPipeline }
        depthPipeline = RendererSharedSetup.makePipelineState(
            device: device, label: "heightfield_depth", library: library,
            vertexFunction: "heightfield_depth_vertex",
            fragmentFunction: "depth_only_clip_fragment", depthPixelFormat: .depth32Float)
        return depthPipeline
    }

    /// The selection-mask pipeline: `heightfield_depth_vertex` + `selection_mask_fragment`,
    /// single-sample `.r8Uint` colour and no depth.
    func selectionMaskPipelineState() -> MTLRenderPipelineState? {
        if let selectionMaskPipeline { return selectionMaskPipeline }
        selectionMaskPipeline = RendererSharedSetup.makePipelineState(
            device: device, label: "heightfield_selection_mask", library: library,
            vertexFunction: "heightfield_depth_vertex",
            fragmentFunction: "selection_mask_fragment",
            colorPixelFormat: RendererSharedSetup.selectionMaskPixelFormat,
            depthPixelFormat: .invalid)
        return selectionMaskPipeline
    }

    /// The stencil-mark pipeline of the selection outline: writes no colour, so the main pass
    /// stencil marks the silhouette.
    func stencilMarkPipelineState(sampleCount: Int, depthFormat: MTLPixelFormat)
        -> MTLRenderPipelineState?
    {
        if let cached = stencilPipelinesBySamples[sampleCount] { return cached }
        let descriptor = RendererSharedSetup.renderPipelineDescriptor(
            label: "heightfield_stencil_mark", library: library,
            vertexFunction: "heightfield_depth_vertex",
            fragmentFunction: "depth_only_clip_fragment", colorPixelFormat: .bgra8Unorm,
            depthPixelFormat: depthFormat, stencilPixelFormat: depthFormat,
            sampleCount: sampleCount, blending: .disabled, vertexDescriptor: nil)
        descriptor.colorAttachments[0].writeMask = []
        stencilPipelinesBySamples[sampleCount] =
            RendererSharedSetup
            .makeRenderPipelineStateReporting(device: device, descriptor: descriptor)
        return stencilPipelinesBySamples[sampleCount]
    }

    /// Creates or refreshes the GPU state of every visible heightfield body, drops the state of
    /// bodies no longer passed, encodes the pending uploads at the head of `commandBuffer`, and
    /// plans each body's tiles for this camera.
    func prepare(
        bodies: [ViewportBody], commandBuffer: MTLCommandBuffer, view: simd_float4x4,
        projection: simd_float4x4, viewportHeight: Float, meshCellPixels: Float,
        clipPlanes: [SIMD4<Float>] = [], shadow: HeightfieldShadowView? = nil
    ) -> [Entry] {
        let targetPixels = min(
            max(meshCellPixels, Heightfield.meshCellPixelsRange.lowerBound),
            Heightfield.meshCellPixelsRange.upperBound)
        var entries: [Entry] = []
        var active = Set<String>()
        var objectIndex: UInt32 = 0
        for body in bodies {
            guard let field = body.heightfield else {
                if body.isVisible { objectIndex += 1 }
                continue
            }
            active.insert(body.id)
            guard body.isVisible else { continue }
            let index = objectIndex
            objectIndex += 1
            if shared == nil { shared = HeightfieldShared(device: device, library: library) }
            guard let shared else { continue }
            if states[body.id]?.field !== field {
                states[body.id] = nil
                if !failedFields.contains(ObjectIdentifier(field)) {
                    states[body.id] = HeightfieldGPU(field: field, device: device, shared: shared)
                    if states[body.id] == nil { reportFailure(of: field, bodyID: body.id) }
                }
            }
            guard let state = states[body.id] else { continue }
            let changed = state.encodeUpdates(commandBuffer: commandBuffer)
            let planView = HeightfieldView(
                model: body.transform, view: view, projection: projection,
                viewportHeight: viewportHeight, targetPixels: targetPixels,
                forcedLevel: forcedLevel, clipPlanes: clipPlanes)
            let levels = state.computeLevels(view: planView)
            let plan = state.pack(
                levels: levels, mask: levels.cameraVisible, pool: planPool,
                commandBuffer: commandBuffer)
            state.lastPlan = plan
            var shadowDraw: HeightfieldDrawSet?
            if let shadow, body.renderLayer == .geometry {
                let shadowPlan = state.makeShadowPlan(
                    levels: levels, view: planView, shadow: shadow, pool: planPool,
                    commandBuffer: commandBuffer)
                state.lastShadowPlan = shadowPlan
                shadowDraw = state.drawSet(plan: shadowPlan)
            } else {
                state.lastShadowPlan = nil
            }
            entries.append(
                Entry(
                    body: body, objectIndex: index, state: state,
                    draw: state.drawSet(plan: plan), shadowDraw: shadowDraw, changed: changed))
        }
        for id in states.keys where !active.contains(id) { states.removeValue(forKey: id) }
        return entries
    }

    /// Records, and logs once, that the GPU could not hold `field`, which is then not drawn.
    private func reportFailure(of field: Heightfield, bodyID: String) {
        failedFields.insert(ObjectIdentifier(field))
        failureCount += 1
        let bytes = HeightfieldGPU.estimatedBytes(for: field)
        Self.log.error(
            "Heightfield \(field.width, privacy: .public) x \(field.height, privacy: .public) of body \(bodyID, privacy: .public) could not be allocated on the GPU (about \(bytes, privacy: .public) bytes of textures); it will not be drawn."
        )
    }
}

// MARK: - Per-body GPU state

/// The GPU copy of one `Heightfield` for one renderer.
///
/// Keeps the height texture (level 0 plus the min pyramid), the attribute texture and the colour
/// ramp, and brings them up to date from the field's change log: only the 64 x 64 tiles touched by
/// edits since the version this renderer last drew are copied (through a pooled staging buffer,
/// blitted at the head of the frame's command buffer, so the CPU never writes a texture the GPU
/// may still be reading) and the pyramid is rebuilt over those tiles.
@MainActor
final class HeightfieldGPU {
    let field: Heightfield
    let device: MTLDevice
    let shared: HeightfieldShared
    let paddedWidth: Int
    let paddedHeight: Int
    let heights: MTLTexture
    let attributes: MTLTexture
    private let levelViews: [MTLTexture]
    private(set) var rampBuffer: MTLBuffer
    private let staging: FrameBufferPool
    private var seenVersion: UInt64 = 0
    private var seenRampVersion: UInt64 = 0
    private var rampSpace: AuthoredColorSpace = .sRGB

    /// Bytes copied into staging buffers, tiles uploaded, and full uploads, since creation.
    private(set) var uploadedBytes = 0
    private(set) var uploadedTiles = 0
    private(set) var fullUploads = 0
    /// Blit copy commands encoded since creation (two per block of consecutive dirty tiles).
    private(set) var blitCommands = 0
    /// Seconds the CPU spent on the last `encodeUpdates` / `makePlan`.
    private(set) var lastUpdateSeconds: Double = 0
    private(set) var lastPlanSeconds: Double = 0
    /// The camera plan of the most recent frame.
    var lastPlan: HeightfieldDrawPlan?
    /// The shadow plan of the most recent frame, if shadows were on.
    var lastShadowPlan: HeightfieldDrawPlan?

    /// Whether this build can write `Float16` heights: arm64 only, as Swift has no `Float16` on x86_64.
    static var supportsHalf: Bool {
        #if arch(arm64)
            return true
        #else
            return false
        #endif
    }

    /// The height texture format for `precision`: `.float16` falls back to 32-bit where the
    /// platform cannot write half floats (Intel Macs).
    static func storageFormat(
        for precision: HeightfieldPrecision, supportsHalf: Bool
    ) -> MTLPixelFormat {
        precision == .float16 && supportsHalf ? .r16Float : .r32Float
    }

    var pixelFormat: MTLPixelFormat {
        Self.storageFormat(for: field.precision, supportsHalf: Self.supportsHalf)
    }

    /// The GPU bytes the height pyramid and attribute texture of `field` take (float32 heights).
    static func estimatedBytes(for field: Heightfield) -> Int {
        let padded =
            (HeightfieldLayout.drawTileCount(cells: field.width) + 1) * HeightfieldLayout.tileCells
            * (HeightfieldLayout.drawTileCount(cells: field.height) + 1)
            * HeightfieldLayout.tileCells
        return padded * 4 * 4 / 3 + field.width * field.height
    }

    private var bytesPerHeight: Int { pixelFormat == .r16Float ? 2 : 4 }

    /// The widest texture the device allows, in texels.
    ///
    /// A test lowers it to provoke the failure path of a field the GPU cannot hold.
    static var textureSideLimit = 16_384

    init?(field: Heightfield, device: MTLDevice, shared: HeightfieldShared) {
        self.field = field
        self.device = device
        self.shared = shared
        paddedWidth =
            (HeightfieldLayout.drawTileCount(cells: field.width) + 1)
            * HeightfieldLayout.tileCells
        paddedHeight =
            (HeightfieldLayout.drawTileCount(cells: field.height) + 1)
            * HeightfieldLayout.tileCells
        guard max(paddedWidth, paddedHeight) <= Self.textureSideLimit else { return nil }
        let format = Self.storageFormat(for: field.precision, supportsHalf: Self.supportsHalf)

        let heightDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: paddedWidth, height: paddedHeight, mipmapped: false)
        heightDesc.mipmapLevelCount = HeightfieldLayout.levelCount
        heightDesc.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        heightDesc.storageMode = .private
        let attributeDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Uint, width: field.width, height: field.height, mipmapped: false)
        attributeDesc.usage = [.shaderRead]
        attributeDesc.storageMode = .private
        guard let heights = device.makeTexture(descriptor: heightDesc),
            let attributes = device.makeTexture(descriptor: attributeDesc),
            let ramp = device.makeBuffer(
                length: Heightfield.rampSize * MemoryLayout<SIMD4<Float>>.stride,
                options: .storageModeShared)
        else { return nil }
        heights.label = "heightfield_heights"
        attributes.label = "heightfield_attributes"
        var views: [MTLTexture] = []
        for level in 0..<HeightfieldLayout.levelCount {
            guard
                let view = heights.makeTextureView(
                    pixelFormat: format, textureType: .type2D, levels: level..<(level + 1),
                    slices: 0..<1)
            else { return nil }
            views.append(view)
        }
        self.heights = heights
        self.attributes = attributes
        self.rampBuffer = ramp
        self.levelViews = views
        self.staging = FrameBufferPool(device: device)
    }

    // MARK: Updates

    /// Encodes the uploads and pyramid rebuild for every edit since this renderer last drew, at
    /// the head of `commandBuffer`.
    ///
    /// - Returns: Whether anything changed since the last draw: an edit or a ramp change.
    @discardableResult
    func encodeUpdates(commandBuffer: MTLCommandBuffer) -> Bool {
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            lastUpdateSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) * 1e-9
        }
        let (version, changes, rampVersion) = field.changes(since: seenVersion)
        var changed = version != seenVersion
        if rampVersion != seenRampVersion {
            updateRamp(commandBuffer: commandBuffer)
            changed = true
        }

        var dirty: [SIMD2<Int>] = []
        let cols = HeightfieldLayout.tileCount(cells: field.width)
        let rows = HeightfieldLayout.tileCount(cells: field.height)
        switch changes {
        case .none:
            seenVersion = version
            return changed
        case .full:
            fullUploads += 1
            dirty.reserveCapacity(cols * rows)
            for ty in 0..<rows { for tx in 0..<cols { dirty.append(SIMD2(tx, ty)) } }
        case .regions(let regions):
            // Coalesce into per-tile flags: however many edits piled up, a tile uploads once.
            var flags = [Bool](repeating: false, count: cols * rows)
            let t = HeightfieldLayout.tileCells
            for region in regions {
                for ty in (region.y / t)...((region.maxY - 1) / t) {
                    for tx in (region.x / t)...((region.maxX - 1) / t) {
                        flags[ty * cols + tx] = true
                    }
                }
            }
            for ty in 0..<rows {
                for tx in 0..<cols where flags[ty * cols + tx] {
                    dirty.append(SIMD2(tx, ty))
                }
            }
        }
        seenVersion = version
        guard !dirty.isEmpty else { return changed }
        upload(tiles: dirty, commandBuffer: commandBuffer)
        buildPyramid(tiles: dirty, commandBuffer: commandBuffer)
        return changed
    }

    private func updateRamp(commandBuffer: MTLCommandBuffer) {
        let snapshot = field.rampSnapshot()
        seenRampVersion = snapshot.version
        rampSpace = snapshot.space
        // A new buffer rather than an in-place write: an earlier frame may still be reading the
        // old one.
        let byteCount = Heightfield.rampSize * MemoryLayout<SIMD4<Float>>.stride
        guard let fresh = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            return
        }
        snapshot.ramp.withUnsafeBytes {
            fresh.contents().copyMemory(from: $0.baseAddress!, byteCount: byteCount)
        }
        rampBuffer = fresh
    }

    private func upload(tiles: [SIMD2<Int>], commandBuffer: MTLCommandBuffer) {
        let t = HeightfieldLayout.tileCells
        let es = bytesPerHeight
        struct Block {
            var heightOffset: Int
            var attributeOffset: Int
            var width: Int
            var height: Int
            var origin: MTLOrigin
        }
        var blocks: [Block] = []
        blocks.reserveCapacity(tiles.count)
        var total = 0
        func align(_ n: Int) -> Int { (n + 15) & ~15 }
        // One block per run of consecutive dirty tiles in a tile row, so a densely edited field
        // costs a handful of blit commands rather than one per tile.
        var start = 0
        while start < tiles.count {
            var end = start + 1
            while end < tiles.count, tiles[end].y == tiles[start].y,
                tiles[end].x == tiles[end - 1].x + 1
            {
                end += 1
            }
            let x0 = tiles[start].x * t
            let y0 = tiles[start].y * t
            let w = min((tiles[end - 1].x + 1) * t, field.width) - x0
            let h = min(t, field.height - y0)
            let heightOffset = total
            total += align(w * h * es)
            let attributeOffset = total
            total += align(w * h)
            blocks.append(
                Block(
                    heightOffset: heightOffset, attributeOffset: attributeOffset, width: w,
                    height: h, origin: MTLOrigin(x: x0, y: y0, z: 0)))
            start = end
        }
        blitCommands += blocks.count * 2
        guard let buffer = staging.acquire(byteCount: total) else { return }
        let base = buffer.contents()
        let fieldWidth = field.width
        let half = pixelFormat == .r16Float
        field.withMirrors { heightsMirror, attributesMirror in
            for block in blocks {
                for row in 0..<block.height {
                    let srcIndex = (Int(block.origin.y) + row) * fieldWidth + Int(block.origin.x)
                    let dstHeights = base + block.heightOffset + row * block.width * es
                    let dstAttributes = base + block.attributeOffset + row * block.width
                    if half {
                        #if arch(arm64)
                            let out = dstHeights.bindMemory(to: Float16.self, capacity: block.width)
                            for i in 0..<block.width {
                                out[i] = Float16(heightsMirror[srcIndex + i])
                            }
                        #endif
                    } else {
                        dstHeights.copyMemory(
                            from: heightsMirror.baseAddress! + srcIndex,
                            byteCount: block.width * es)
                    }
                    dstAttributes.copyMemory(
                        from: attributesMirror.baseAddress! + srcIndex, byteCount: block.width)
                }
            }
        }
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "heightfield_upload"
            for block in blocks {
                let size = MTLSize(width: block.width, height: block.height, depth: 1)
                blit.copy(
                    from: buffer, sourceOffset: block.heightOffset,
                    sourceBytesPerRow: block.width * es,
                    sourceBytesPerImage: block.width * block.height * es, sourceSize: size,
                    to: heights, destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: block.origin)
                blit.copy(
                    from: buffer, sourceOffset: block.attributeOffset,
                    sourceBytesPerRow: block.width, sourceBytesPerImage: block.width * block.height,
                    sourceSize: size, to: attributes, destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: block.origin)
            }
            blit.endEncoding()
        }
        staging.release(buffer, after: commandBuffer)
        uploadedBytes += total
        uploadedTiles += tiles.count
    }

    private func buildPyramid(tiles: [SIMD2<Int>], commandBuffer: MTLCommandBuffer) {
        let coordinates = tiles.map { SIMD2<UInt32>(UInt32($0.x), UInt32($0.y)) }
        let byteCount = coordinates.count * MemoryLayout<SIMD2<UInt32>>.stride
        guard let tileBuffer = staging.acquire(byteCount: byteCount),
            let compute = commandBuffer.makeComputeCommandEncoder()
        else { return }
        coordinates.withUnsafeBytes {
            tileBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: byteCount)
        }
        compute.label = "heightfield_pyramid"
        compute.setComputePipelineState(shared.pyramidPipeline)
        compute.setBuffer(tileBuffer, offset: 0, index: 1)
        for level in 1...HeightfieldLayout.maxLevel {
            let texels = HeightfieldLayout.tileCells >> level
            var params = HeightfieldPyramidParams(
                size: SIMD2(UInt32(field.width), UInt32(field.height)), level: UInt32(level),
                tileTexels: UInt32(texels), tileCount: UInt32(tiles.count))
            compute.setTexture(levelViews[level - 1], index: 0)
            compute.setTexture(levelViews[level], index: 1)
            compute.setBytes(&params, length: MemoryLayout<HeightfieldPyramidParams>.size, index: 0)
            let threads = tiles.count * (texels + 2) * (texels + 2)
            compute.dispatchThreads(
                MTLSize(width: threads, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: min(64, threads), height: 1, depth: 1))
        }
        compute.endEncoding()
        staging.release(tileBuffer, after: commandBuffer)
    }

    // MARK: Planning

    /// Chooses each tile's level of detail for `view`, and which tiles the camera sees.
    func computeLevels(view: HeightfieldView) -> HeightfieldTileLevels {
        let cols = HeightfieldLayout.drawTileCount(cells: field.width)
        let rows = HeightfieldLayout.drawTileCount(cells: field.height)
        let t = HeightfieldLayout.tileCells
        let range = field.heightRange
        let cs = field.cellSize
        let origin = field.origin
        let frustum = Frustum(viewProjection: view.projection * view.view)
        let orthographic = view.projection.columns.3.w > 0.5
        let pixelsPerUnit = view.projection.columns.1.y * view.viewportHeight * 0.5
        let scaleX = simd_length(
            SIMD3(view.model.columns.0.x, view.model.columns.0.y, view.model.columns.0.z))
        let scaleY = simd_length(
            SIMD3(view.model.columns.1.x, view.model.columns.1.y, view.model.columns.1.z))
        let worldCell = max(cs.x * scaleX, cs.y * scaleY)
        let modelView = view.view * view.model

        var levels = [UInt8](repeating: 0, count: cols * rows)
        var inFrustum = [Bool](repeating: true, count: cols * rows)
        var unclipped = [Bool](repeating: true, count: cols * rows)
        var worldBoxes = [BoundingBox](
            repeating: BoundingBox(min: .zero, max: .zero), count: cols * rows)
        for ty in 0..<rows {
            for tx in 0..<cols {
                let x0 = Float(tx * t)
                let y0 = Float(ty * t)
                let x1 = Float(min((tx + 1) * t, field.width))
                let y1 = Float(min((ty + 1) * t, field.height))
                let lo = SIMD3(origin.x + x0 * cs.x, origin.y + y0 * cs.y, range.lowerBound)
                let hi = SIMD3(origin.x + x1 * cs.x, origin.y + y1 * cs.y, range.upperBound)
                let local = BoundingBox(min: lo, max: hi)
                let world = local.transformed(by: view.model)
                let index = ty * cols + tx
                worldBoxes[index] = world
                if view.cull, !frustum.intersects(world) { inFrustum[index] = false }
                if Self.isClippedAway(world, by: view.clipPlanes) { unclipped[index] = false }
                if let forced = view.forcedLevel {
                    levels[index] = UInt8(max(0, min(HeightfieldLayout.maxLevel, forced)))
                    continue
                }
                let centre = (lo + hi) * 0.5
                let radius = simd_length(world.max - world.min) * 0.5
                let viewCentre = modelView * SIMD4(centre, 1)
                let depth = orthographic ? 1 : max(-viewCentre.z - radius, 1e-3)
                let cellPixels = worldCell * pixelsPerUnit / depth
                levels[index] = UInt8(
                    HeightfieldLayout.level(
                        cellPixels: cellPixels, targetPixels: view.targetPixels))
            }
        }
        let visible = zip(inFrustum, unclipped).map { $0 && $1 }
        return HeightfieldTileLevels(
            cols: cols, rows: rows, levels: levels, cameraVisible: visible, inFrustum: inFrustum,
            unclipped: unclipped, worldBoxes: worldBoxes, worldCell: worldCell)
    }

    /// Whether `box` lies wholly on the clipped side of one of `planes`.
    static func isClippedAway(_ box: BoundingBox, by planes: [SIMD4<Float>]) -> Bool {
        for plane in planes {
            let normal = SIMD3(plane.x, plane.y, plane.z)
            // The corner furthest along the normal: if even it is clipped, the box is.
            let corner = SIMD3(
                normal.x >= 0 ? box.max.x : box.min.x, normal.y >= 0 ? box.max.y : box.min.y,
                normal.z >= 0 ? box.max.z : box.min.z)
            if simd_dot(normal, corner) + plane.w < 0 { return true }
        }
        return false
    }

    /// The tiles that can cast a shadow the camera sees, each at a level of detail.
    ///
    /// A tile the camera sees keeps its camera level, so its shadow is cast by the surface that is
    /// drawn. A tile off screen is kept when the light reaches it and the shadow it throws, swept
    /// along the light for up to `reach`, can enter the camera's frustum; it takes the coarser of
    /// its camera level and the level the shadow map's texel size allows.
    func makeShadowPlan(
        levels: HeightfieldTileLevels, view: HeightfieldView, shadow: HeightfieldShadowView,
        pool: FrameBufferPool, commandBuffer: MTLCommandBuffer
    ) -> HeightfieldDrawPlan {
        let lightFrustum = Frustum(viewProjection: shadow.lightViewProjection)
        let cameraFrustum = Frustum(viewProjection: view.projection * view.view)
        let m = shadow.lightViewProjection
        let texelsPerUnit =
            max(
                simd_length(SIMD3(m.columns.0.x, m.columns.1.x, m.columns.2.x)),
                simd_length(SIMD3(m.columns.0.y, m.columns.1.y, m.columns.2.y)))
            * Float(shadow.mapSize) * 0.5
        let lightLevel = UInt8(
            HeightfieldLayout.level(
                cellPixels: levels.worldCell * texelsPerUnit, targetPixels: view.targetPixels))
        let travel = simd_normalize(shadow.lightDirection) * shadow.reach

        var shadowLevels = levels
        var mask = [Bool](repeating: false, count: levels.levels.count)
        for index in levels.levels.indices where levels.unclipped[index] {
            let box = levels.worldBoxes[index]
            guard lightFrustum.intersects(box) else { continue }
            if levels.inFrustum[index] {
                mask[index] = true
                continue
            }
            var swept = BoundingBox(
                min: simd_min(box.min, box.min + travel), max: simd_max(box.max, box.max + travel))
            if let bounds = shadow.sceneBounds {
                // A shadow falls on the scene, so the sweep ends where it leaves the scene.
                swept = BoundingBox(
                    min: simd_max(swept.min, bounds.min), max: simd_min(swept.max, bounds.max))
            }
            guard !view.cull || cameraFrustum.intersects(swept) else { continue }
            mask[index] = true
            if view.forcedLevel == nil {
                shadowLevels.levels[index] = max(levels.levels[index], lightLevel)
            }
        }
        return pack(levels: shadowLevels, mask: mask, pool: pool, commandBuffer: commandBuffer)
    }

    /// Packs the tiles `mask` selects, grouped by level, into one instance buffer, with the
    /// neighbour levels that keep the seams between levels crack-free.
    func pack(
        levels tileLevels: HeightfieldTileLevels, mask: [Bool], pool: FrameBufferPool,
        commandBuffer: MTLCommandBuffer
    ) -> HeightfieldDrawPlan {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { lastPlanSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) * 1e-9 }

        let cols = tileLevels.cols
        let rows = tileLevels.rows
        let levels = tileLevels.levels
        let t = HeightfieldLayout.tileCells
        func level(_ x: Int, _ y: Int) -> Int? {
            guard x >= 0, y >= 0, x < cols, y < rows else { return nil }
            return Int(levels[y * cols + x])
        }
        var perLevel = [[HeightfieldTileInstance]](
            repeating: [], count: HeightfieldLayout.levelCount)
        for ty in 0..<rows {
            for tx in 0..<cols where mask[ty * cols + tx] {
                let own = Int(levels[ty * cols + tx])
                func edge(_ dx: Int, _ dy: Int) -> UInt32 {
                    UInt32(max(own, level(tx + dx, ty + dy) ?? own))
                }
                func corner(_ dx: Int, _ dy: Int) -> UInt32 {
                    // The four tiles meeting at the corner on side (dx, dy) of this tile.
                    var m = own
                    for ox in [0, dx] {
                        for oy in [0, dy] { m = max(m, level(tx + ox, ty + oy) ?? m) }
                    }
                    return UInt32(m)
                }
                let packed =
                    edge(-1, 0) | edge(1, 0) << 3 | edge(0, -1) << 6 | edge(0, 1) << 9
                    | corner(-1, -1) << 12 | corner(1, -1) << 15 | corner(-1, 1) << 18
                    | corner(1, 1) << 21
                perLevel[own].append(
                    HeightfieldTileInstance(
                        origin: SIMD2(UInt32(tx * t), UInt32(ty * t)), levels: packed))
            }
        }
        let total = perLevel.reduce(0) { $0 + $1.count }
        var ranges: [(first: Int, count: Int)] = []
        var first = 0
        for group in perLevel {
            ranges.append((first, group.count))
            first += group.count
        }
        var buffer: MTLBuffer?
        if total > 0 {
            let stride = MemoryLayout<HeightfieldTileInstance>.stride
            buffer = pool.acquire(byteCount: total * stride)
            if let buffer {
                var offset = 0
                for group in perLevel where !group.isEmpty {
                    group.withUnsafeBytes {
                        (buffer.contents() + offset).copyMemory(
                            from: $0.baseAddress!, byteCount: $0.count)
                    }
                    offset += group.count * stride
                }
                pool.release(buffer, after: commandBuffer)
            }
        }
        return HeightfieldDrawPlan(
            instanceBuffer: buffer, ranges: ranges, levelHistogram: perLevel.map(\.count))
    }

    /// The camera's plan: the tiles it sees, each at its level of detail.
    func makePlan(view: HeightfieldView, pool: FrameBufferPool, commandBuffer: MTLCommandBuffer)
        -> HeightfieldDrawPlan
    {
        let started = DispatchTime.now().uptimeNanoseconds
        let tileLevels = computeLevels(view: view)
        let plan = pack(
            levels: tileLevels, mask: tileLevels.cameraVisible, pool: pool,
            commandBuffer: commandBuffer)
        lastPlanSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) * 1e-9
        lastPlan = plan
        return plan
    }

    // MARK: Drawing

    /// What the encoders need to draw `plan`, as plain values.
    func drawSet(plan: HeightfieldDrawPlan) -> HeightfieldDrawSet {
        HeightfieldDrawSet(
            plan: plan, heights: heights, attributes: attributes, ramp: rampBuffer,
            params: HeightfieldDrawParams(
                size: SIMD2(UInt32(field.width), UInt32(field.height)), level: 0, quads: 0,
                cellSize: field.cellSize, origin: field.origin,
                rampMode: rampSpace == .linear ? 6 : 2),
            indexBuffers: shared.indexBuffers, indexCounts: shared.indexCounts)
    }

    // MARK: Test support

    /// Runs the pending updates in a command buffer of their own and returns the GPU seconds it
    /// took, waiting for it.
    func timedUpdate(commandQueue: MTLCommandQueue) -> Double? {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        encodeUpdates(commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
    }

    /// Reads pyramid level `level` back (row-major, `levelWidth x levelHeight`), waiting for the GPU.
    func readLevel(_ level: Int, commandQueue: MTLCommandQueue) -> (
        values: [Float], width: Int, height: Int
    )? {
        let w = max(1, paddedWidth >> level)
        let h = max(1, paddedHeight >> level)
        let es = bytesPerHeight
        guard let buffer = device.makeBuffer(length: w * h * es, options: .storageModeShared),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { return nil }
        blit.copy(
            from: heights, sourceSlice: 0, sourceLevel: level,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer,
            destinationOffset: 0, destinationBytesPerRow: w * es,
            destinationBytesPerImage: w * h * es)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var out = [Float](repeating: 0, count: w * h)
        if pixelFormat == .r16Float {
            #if arch(arm64)
                let p = buffer.contents().bindMemory(to: Float16.self, capacity: w * h)
                for i in 0..<(w * h) { out[i] = Float(p[i]) }
            #endif
        } else {
            let p = buffer.contents().bindMemory(to: Float.self, capacity: w * h)
            for i in 0..<(w * h) { out[i] = p[i] }
        }
        return (out, w, h)
    }

    /// Reads the attribute texture back (row-major).
    func readAttributes(commandQueue: MTLCommandQueue) -> [UInt8]? {
        let w = field.width
        let h = field.height
        guard let buffer = device.makeBuffer(length: w * h, options: .storageModeShared),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { return nil }
        blit.copy(
            from: attributes, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer,
            destinationOffset: 0, destinationBytesPerRow: w, destinationBytesPerImage: w * h)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return Array(
            UnsafeBufferPointer(
                start: buffer.contents().bindMemory(to: UInt8.self, capacity: w * h), count: w * h))
    }
}
