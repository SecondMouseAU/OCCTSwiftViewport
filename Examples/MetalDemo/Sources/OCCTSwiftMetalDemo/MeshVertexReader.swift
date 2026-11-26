// MeshVertexReader.swift
// OCCTSwiftMetalDemo
//
// Reads a body's mesh vertices from whichever layout the renderer draws.

import OCCTSwiftViewport
import simd

/// Reads vertex positions and normals from a body's mesh, whichever layout it uses.
///
/// A direct-mesh body (`usesDirectMesh`) keeps its triangles in `meshPositions` and `meshNormals`
/// (stride 3) and leaves `vertexData` empty; any other mesh body is interleaved in `vertexData`
/// (stride 6). Reading only `vertexData` found no triangles on a direct-mesh body (issue #264).
///
/// The same rule as the library's `SceneRaycast.TrianglePositions` (internal) and
/// `ViewportBody.worldHitPoint(ray:triangleIndex:)`, minus the fallback to `vertices`, which are
/// B-Rep vertices rather than the mesh vertices `indices` refers to. Reads body-local coordinates.
struct MeshVertexReader {
    private enum Source {
        /// `meshPositions` and `meshNormals`, both stride 3.
        case direct(positions: [Float], normals: [Float])
        /// `vertexData`, stride 6.
        case interleaved([Float])
    }

    private let source: Source

    /// Returns `nil` when `body` has no mesh to read (no direct-mesh arrays and no `vertexData`).
    init?(_ body: ViewportBody) {
        if body.usesDirectMesh {
            source = .direct(positions: body.meshPositions, normals: body.meshNormals)
        } else if !body.vertexData.isEmpty {
            source = .interleaved(body.vertexData)
        } else {
            return nil
        }
    }

    /// The position of mesh vertex `index`, or `nil` when it is out of range.
    func position(at index: Int) -> SIMD3<Float>? {
        guard index >= 0 else { return nil }
        switch source {
        case .direct(let positions, _):
            return Self.vector(in: positions, at: index * 3)
        case .interleaved(let data):
            return Self.vector(in: data, at: index * 6)
        }
    }

    /// The position and normal of mesh vertex `index`, or `nil` when it is out of range.
    func vertex(at index: Int) -> (position: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard index >= 0 else { return nil }
        switch source {
        case .direct(let positions, let normals):
            guard let p = Self.vector(in: positions, at: index * 3),
                let n = Self.vector(in: normals, at: index * 3)
            else { return nil }
            return (p, n)
        case .interleaved(let data):
            guard let p = Self.vector(in: data, at: index * 6),
                let n = Self.vector(in: data, at: index * 6 + 3)
            else { return nil }
            return (p, n)
        }
    }

    /// Three consecutive floats starting at `start`, or `nil` when they run past the end.
    private static func vector(in data: [Float], at start: Int) -> SIMD3<Float>? {
        guard start + 2 < data.count else { return nil }
        return SIMD3<Float>(data[start], data[start + 1], data[start + 2])
    }
}

extension MeshVertexReader {
    /// Builds the interleaved (stride 6) triangles of one B-Rep face, each vertex lifted along
    /// its normal so the highlight does not z-fight the surface it covers.
    ///
    /// - Parameters:
    ///   - body: The picked body. Direct-mesh and interleaved bodies are both read.
    ///   - faceIndices: The face each triangle belongs to, parallel to `body.indices / 3`
    ///     (`CADBodyMetadata.faceIndices`).
    ///   - face: The face to highlight.
    ///   - offset: How far to lift each vertex along its normal.
    /// - Returns: The overlay's `vertexData` and `indices`, or `nil` when `body` has no mesh or no
    ///   triangle of `face` could be read. A triangle with a corner out of range is skipped whole.
    static func faceHighlightMesh(
        of body: ViewportBody,
        faceIndices: [Int32],
        face: Int32,
        offset: Float = 0.002
    ) -> (vertexData: [Float], indices: [UInt32])? {
        guard let reader = MeshVertexReader(body) else { return nil }
        var vertexData: [Float] = []
        var indices: [UInt32] = []
        var next: UInt32 = 0

        for (triangle, triangleFace) in faceIndices.enumerated() where triangleFace == face {
            let base = triangle * 3
            guard base + 2 < body.indices.count else { continue }

            // Skip the whole triangle if any corner is out of range, so the overlay's indices
            // always address three vertices that were appended.
            let corners = (0..<3).compactMap { corner in
                reader.vertex(at: Int(body.indices[base + corner]))
            }
            guard corners.count == 3 else { continue }

            for (position, normal) in corners {
                let lifted = position + normal * offset
                vertexData.append(contentsOf: [
                    lifted.x, lifted.y, lifted.z,
                    normal.x, normal.y, normal.z,
                ])
            }
            indices.append(contentsOf: [next, next + 1, next + 2])
            next += 3
        }

        guard !indices.isEmpty else { return nil }
        return (vertexData, indices)
    }
}
