// RendererSharedBuffers.swift
// OCCTSwiftViewport
//
// GPU buffer construction shared by ViewportRenderer and OffscreenRenderer.

import Foundation
@preconcurrency import Metal
import simd

/// Per-body GPU buffer construction shared by the live and headless renderers.
///
/// Each renderer keeps its own cache type (the live one additionally carries tessellation patches,
/// meshlets, triangle styles and pick buffers), but the buffers themselves are built here so the
/// direct-mesh, interleaved, edge and point-cloud uploads have one implementation.
enum RendererSharedBuffers {

    /// The mesh buffers for one body.
    ///
    /// `normalBuffer` is non-nil only on the direct-mesh path, where `vertexBuffer` holds positions
    /// alone (stride 12) and the body draws through the direct-mesh pipelines.
    struct MeshBuffers {
        var vertexBuffer: MTLBuffer?
        var normalBuffer: MTLBuffer?
        var indexBuffer: MTLBuffer?
        var indexCount: Int = 0
        var vertexCount: Int = 0
    }

    /// Uploads a body's mesh, taking the direct-mesh path when it carries de-interleaved arrays.
    ///
    /// - Parameters:
    ///   - device: Device to allocate on.
    ///   - body: Body supplying positions, normals and indices.
    ///   - interleavedVertexData: Replacement for `body.vertexData` on the interleaved path — the
    ///     live renderer passes crease-smoothed normals here. Ignored on the direct-mesh path.
    /// - Returns: The uploaded buffers, all-nil when the body has no triangle mesh.
    static func makeMeshBuffers(
        device: MTLDevice,
        body: ViewportBody,
        interleavedVertexData: [Float]? = nil
    ) -> MeshBuffers {
        var buffers = MeshBuffers()
        guard !body.indices.isEmpty else { return buffers }

        if body.usesDirectMesh {
            // Direct-mesh path (Option A): upload de-interleaved positions + normals straight to
            // separate buffers — no CPU interleave. This is the shape OCCT's Mesh already provides.
            buffers.vertexBuffer = device.makeBuffer(
                bytes: body.meshPositions,
                length: body.meshPositions.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
            buffers.normalBuffer = device.makeBuffer(
                bytes: body.meshNormals,
                length: body.meshNormals.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
            buffers.vertexCount = body.meshPositions.count / 3
        } else {
            let vertexData = interleavedVertexData ?? body.vertexData
            guard !vertexData.isEmpty else { return buffers }
            buffers.vertexBuffer = device.makeBuffer(
                bytes: vertexData,
                length: vertexData.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
            buffers.vertexCount = body.vertexData.count / 6
        }

        buffers.indexBuffer = device.makeBuffer(
            bytes: body.indices,
            length: body.indices.count * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        )
        buffers.indexCount = body.indices.count
        return buffers
    }

    /// Flattens edge polylines into screen-expandable line-segment quads.
    ///
    /// Format per vertex: [x, y, z, arcLength, cornerX, cornerY, directionX, directionY, directionZ].
    /// - `arcLength` is the distance along the polyline from its start (in world units).
    /// - `corner` is `(along, side)`: `along` is -0.5 at the segment start and 0.5 at its end;
    ///   `side` (-0.5 or 0.5) is the perpendicular offset, in units of the line width.
    /// - `direction` is the normalized local-space segment direction.
    /// - Each segment produces 6 vertices: 4 corners plus 2 repeated vertices that break the strip.
    ///   A zero-length segment still produces its 6 (zero-area) vertices, so segment `k` always
    ///   starts at vertex `6k` and its triangles are `[[primitive_id]]` `6k...6k+5`: the quad edge
    ///   pick shader recovers the segment index as `primitive_id / 6`, matching the native line
    ///   buffer's numbering.
    static func quadEdgeLineVertices(from polylines: [[SIMD3<Float>]]) -> [Float] {
        var vertices: [Float] = []
        for polyline in polylines {
            guard polyline.count >= 2 else { continue }
            var arcLengths: [Float] = [0]
            for i in 1..<polyline.count {
                let d = length(polyline[i] - polyline[i - 1])
                arcLengths.append(arcLengths.last! + d)
            }
            for i in 0..<(polyline.count - 1) {
                let a = polyline[i]
                let b = polyline[i + 1]
                let segment = b - a
                let segmentLength = length(segment)
                // Any unit direction will do for a zero-length segment: both ends coincide, so
                // its quad has no area and draws nothing.
                let direction =
                    segmentLength > 0 ? segment / segmentLength : SIMD3<Float>(1, 0, 0)
                let arcA = arcLengths[i]
                let arcB = arcLengths[i + 1]
                // Strip order: start-left (twice), start-right, end-left, end-right (twice). With the
                // previous segment's trailing repeat, the doubled leading vertex makes every triangle
                // bridging two segments degenerate, so segments never connect.
                let corners: [(corner: SIMD2<Float>, atStart: Bool)] = [
                    (SIMD2<Float>(-0.5, -0.5), true),
                    (SIMD2<Float>(-0.5, -0.5), true),
                    (SIMD2<Float>(-0.5, 0.5), true),
                    (SIMD2<Float>(0.5, -0.5), false),
                    (SIMD2<Float>(0.5, 0.5), false),
                    (SIMD2<Float>(0.5, 0.5), false),
                ]
                for (corner, atStart) in corners {
                    let position = atStart ? a : b
                    let arcLength = atStart ? arcA : arcB
                    vertices.append(contentsOf: [
                        position.x, position.y, position.z, arcLength, corner.x, corner.y,
                        direction.x, direction.y, direction.z,
                    ])
                }
            }
        }
        return vertices
    }

    /// Samples an analytic arc to `segmentCount` segments: `segmentCount + 1` points from
    /// `t = 0` to `t = 1`.
    static func sampledArcPolyline(_ arc: ViewportArc, segmentCount: Int) -> [SIMD3<Float>] {
        let segments = max(segmentCount, 1)
        return (0...segments).map { arc.point(at: Float($0) / Float(segments)) }
    }

    /// Quad-strip vertices for one arc sampled to `segmentCount` segments.
    ///
    /// Same layout as `quadEdgeLineVertices(from:)` (stride 9, six vertices per segment), with the
    /// arc length measured from the arc's start so dash patterns run continuously round it. Used by
    /// both renderers so arcs honour `EdgeLineConfiguration` width and dashes like polyline edges.
    static func arcQuadEdgeVertices(_ arc: ViewportArc, segmentCount: Int) -> [Float] {
        quadEdgeLineVertices(from: [sampledArcPolyline(arc, segmentCount: segmentCount)])
    }

    /// Flattens edge polylines into line-segment pairs for native Metal line rendering.
    ///
    /// Format per vertex: [x, y, z, arcLength, 0, 0] (same stride as quad buffer for compatibility)
    /// - Only 2 vertices per segment (start, end) — suitable for MTLPrimitiveType.line
    /// - arcLength is included for consistency but unused by native line shader
    static func nativeEdgeLineVertices(from polylines: [[SIMD3<Float>]]) -> [Float] {
        var vertices: [Float] = []
        for polyline in polylines {
            guard polyline.count >= 2 else { continue }
            // Compute arc-length prefix sums
            var arcLengths: [Float] = [0]
            for i in 1..<polyline.count {
                let d = length(polyline[i] - polyline[i - 1])
                arcLengths.append(arcLengths.last! + d)
            }
            for i in 0..<(polyline.count - 1) {
                let a = polyline[i]
                let b = polyline[i + 1]
                let arcA = arcLengths[i]
                let arcB = arcLengths[i + 1]
                // Native lines: 2 vertices per segment (start, end)
                vertices.append(contentsOf: [a.x, a.y, a.z, arcA, 0, 0])
                vertices.append(contentsOf: [b.x, b.y, b.z, arcB, 0, 0])
            }
        }
        return vertices
    }

    /// Uploads flattened edge vertices, or `nil` when there are none.
    static func makeEdgeBuffer(device: MTLDevice, edgeVertices: [Float]) -> MTLBuffer? {
        guard !edgeVertices.isEmpty else { return nil }
        return device.makeBuffer(
            bytes: edgeVertices,
            length: edgeVertices.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
    }

    /// Uploads a tight position buffer (stride 12) for the visible point-cloud pass.
    static func makePointPositionBuffer(
        device: MTLDevice,
        vertices: [SIMD3<Float>]
    ) -> MTLBuffer? {
        guard !vertices.isEmpty else { return nil }
        return vertices.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: base,
                length: buf.count * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared
            )
        }
    }

    /// Uploads the per-point colour buffer (stride 16), or `nil` when it can't be used.
    ///
    /// A colour array whose length doesn't match `vertexCount` is dropped rather than read out of
    /// bounds; the point pass then falls back to the body colour.
    static func makePointColorBuffer(
        device: MTLDevice,
        vertexColors: [SIMD4<Float>],
        vertexCount: Int
    ) -> MTLBuffer? {
        guard !vertexColors.isEmpty, vertexColors.count == vertexCount else { return nil }
        return vertexColors.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: base,
                length: buf.count * MemoryLayout<SIMD4<Float>>.stride,
                options: .storageModeShared
            )
        }
    }
}

// MARK: - Per-frame buffer pool

/// Shared-storage buffers for data the CPU rewrites every frame, such as sampled arcs.
///
/// A buffer handed out by `acquire(byteCount:)` stays reserved until `release(_:)`, which the
/// renderer calls from the frame's command-buffer completion handler. So the CPU never rewrites a
/// buffer the GPU may still be reading, however many frames are in flight. Released buffers are
/// reused, so a steady scene settles at one buffer per frame in flight.
final class FrameBufferPool: @unchecked Sendable {

    private let device: MTLDevice
    private let lock = NSLock()
    private var free: [MTLBuffer] = []
    private(set) var allocatedCount = 0

    init(device: MTLDevice) {
        self.device = device
    }

    /// A buffer of at least `byteCount` bytes that no in-flight frame is using.
    func acquire(byteCount: Int) -> MTLBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if let index = free.firstIndex(where: { $0.length >= byteCount }) {
            return free.remove(at: index)
        }
        guard
            let buffer = device.makeBuffer(
                length: max(byteCount, 4096), options: .storageModeShared)
        else { return nil }
        allocatedCount += 1
        return buffer
    }

    /// Returns `buffer` to the pool once the GPU has finished with it.
    func release(_ buffer: MTLBuffer) {
        lock.lock()
        defer { lock.unlock() }
        free.append(buffer)
    }

    /// Releases `buffer` when `commandBuffer` completes.
    func release(_ buffer: MTLBuffer, after commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { [self] _ in release(buffer) }
    }
}
