// RendererSharedBuffers.swift
// OCCTSwiftViewport
//
// GPU buffer construction shared by ViewportRenderer and OffscreenRenderer.

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

    /// Flattens edge polylines into line-segment quads with the interleaved stride-6 layout.
    ///
    /// Format per vertex: [x, y, z, arcLength, 0, 0]
    /// - arcLength is the distance along the polyline from its start (in world units).
    /// - The last two components are reserved (normal slots, zeroed for backward compat).
    /// - For native Metal lines (width=1, solid), only first 2 vertices per segment are used (start, end).
    /// - For quad-expanded lines, all 6 vertices per segment are used:
    ///   4 corner vertices (start×2, end×2) + 2 degenerate vertices to break triangle strip between segments.
    static func edgeLineVertices(from polylines: [[SIMD3<Float>]]) -> [Float] {
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
                // For native lines: 2 vertices (start, end)
                // For quad expansion: 4 corner vertices (start×2, end×2) + 2 degenerate vertices
                // Degenerate vertices break the triangle strip between segments
                vertices.append(contentsOf: [a.x, a.y, a.z, arcA, 0, 0])  // corner 0
                vertices.append(contentsOf: [a.x, a.y, a.z, arcA, 0, 0])  // corner 1
                vertices.append(contentsOf: [b.x, b.y, b.z, arcB, 0, 0])  // corner 2
                vertices.append(contentsOf: [b.x, b.y, b.z, arcB, 0, 0])  // corner 3
                // Degenerate vertices (duplicate of last corner) to break triangle strip
                vertices.append(contentsOf: [b.x, b.y, b.z, arcB, 0, 0])  // degenerate
                vertices.append(contentsOf: [b.x, b.y, b.z, arcB, 0, 0])  // degenerate
            }
        }
        return vertices
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
