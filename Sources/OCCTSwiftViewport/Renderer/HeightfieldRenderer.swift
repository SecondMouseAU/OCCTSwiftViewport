// HeightfieldRenderer.swift
// OCCTSwiftViewport
//
// GPU side of `Heightfield` (issue #139 spike): the height pyramid, dirty-tile uploads, per-tile
// level of detail and the instanced tile draws. Shared by the live and offscreen renderers.

import Foundation
@preconcurrency import Metal
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

/// Mirrors `HeightfieldParams` in Shaders.metal. Stride 48.
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

/// Mirrors `HeightfieldTile`. Stride 16.
struct HeightfieldTileInstance {
    var origin: SIMD2<UInt32>
    var levels: UInt32
    var pad: UInt32 = 0
}

/// Mirrors `HeightfieldPyramidParams`. Stride 32.
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
}

/// The tiles of one heightfield to draw this frame, grouped by level.
struct HeightfieldDrawPlan {
    var instanceBuffer: MTLBuffer?
    /// First instance and instance count per level.
    var ranges: [(first: Int, count: Int)]
    var levelHistogram: [Int]
    var tileCount: Int { levelHistogram.reduce(0, +) }
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
    /// The plan of the most recent `makePlan`.
    private(set) var lastPlan: HeightfieldDrawPlan?

    static var supportsHalf: Bool {
        #if arch(arm64)
            return true
        #else
            return false
        #endif
    }

    var pixelFormat: MTLPixelFormat {
        field.precision == .float16 && Self.supportsHalf ? .r16Float : .r32Float
    }

    private var bytesPerHeight: Int { pixelFormat == .r16Float ? 2 : 4 }

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
        let format: MTLPixelFormat =
            field.precision == .float16 && Self.supportsHalf ? .r16Float : .r32Float

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
    func encodeUpdates(commandBuffer: MTLCommandBuffer) {
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            lastUpdateSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) * 1e-9
        }
        let (version, changes, rampVersion) = field.changes(since: seenVersion)
        if rampVersion != seenRampVersion { updateRamp(commandBuffer: commandBuffer) }

        var dirty: [SIMD2<Int>] = []
        let cols = HeightfieldLayout.tileCount(cells: field.width)
        let rows = HeightfieldLayout.tileCount(cells: field.height)
        switch changes {
        case .none:
            seenVersion = version
            return
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
        guard !dirty.isEmpty else { return }
        upload(tiles: dirty, commandBuffer: commandBuffer)
        buildPyramid(tiles: dirty, commandBuffer: commandBuffer)
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

    /// Chooses each tile's level of detail for `view` and packs the visible tiles, grouped by
    /// level, into one instance buffer.
    func makePlan(view: HeightfieldView, pool: FrameBufferPool, commandBuffer: MTLCommandBuffer)
        -> HeightfieldDrawPlan
    {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { lastPlanSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) * 1e-9 }

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
        var visible = [Bool](repeating: true, count: cols * rows)
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
                if view.cull, !frustum.intersects(world) { visible[index] = false }
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

        // Pack: neighbour levels for the crack-free edges, grouped by level.
        func level(_ x: Int, _ y: Int) -> Int? {
            guard x >= 0, y >= 0, x < cols, y < rows else { return nil }
            return Int(levels[y * cols + x])
        }
        var perLevel = [[HeightfieldTileInstance]](
            repeating: [], count: HeightfieldLayout.levelCount)
        for ty in 0..<rows {
            for tx in 0..<cols where visible[ty * cols + tx] {
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
        let plan = HeightfieldDrawPlan(
            instanceBuffer: buffer, ranges: ranges, levelHistogram: perLevel.map(\.count))
        lastPlan = plan
        return plan
    }

    // MARK: Drawing

    /// The uniform block both stages of the shaded pass read.
    func drawParams() -> HeightfieldDrawParams {
        HeightfieldDrawParams(
            size: SIMD2(UInt32(field.width), UInt32(field.height)), level: 0, quads: 0,
            cellSize: field.cellSize, origin: field.origin,
            rampMode: rampSpace == .linear ? 6 : 2)
    }

    /// Binds the field's textures and ramp and draws every planned tile with the shaded pipeline
    /// already set on `encoder`.
    func encodeShadedDraws(encoder: MTLRenderCommandEncoder, plan: HeightfieldDrawPlan) {
        encoder.setVertexTexture(heights, index: 0)
        encoder.setFragmentTexture(heights, index: 5)
        encoder.setFragmentTexture(attributes, index: 6)
        encoder.setFragmentBuffer(rampBuffer, offset: 0, index: 4)
        encodeDraws(encoder: encoder, plan: plan, setFragmentParams: true)
    }

    func encodeDraws(
        encoder: MTLRenderCommandEncoder, plan: HeightfieldDrawPlan, setFragmentParams: Bool
    ) {
        guard let instances = plan.instanceBuffer else { return }
        let stride = MemoryLayout<HeightfieldTileInstance>.stride
        for level in 0..<HeightfieldLayout.levelCount where plan.ranges[level].count > 0 {
            var params = drawParams()
            params.level = UInt32(level)
            params.quads = UInt32(HeightfieldLayout.tileCells >> level)
            encoder.setVertexBuffer(
                instances, offset: plan.ranges[level].first * stride, index: 2)
            encoder.setVertexBytes(
                &params, length: MemoryLayout<HeightfieldDrawParams>.size, index: 3)
            if setFragmentParams {
                encoder.setFragmentBytes(
                    &params, length: MemoryLayout<HeightfieldDrawParams>.size, index: 3)
            }
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: shared.indexCounts[level], indexType: .uint16,
                indexBuffer: shared.indexBuffers[level], indexBufferOffset: 0,
                instanceCount: plan.ranges[level].count)
        }
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
