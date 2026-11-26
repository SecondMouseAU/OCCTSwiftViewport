// GeometryUtils.swift
// OCCTSwiftMetalDemo
//
// Geometry utilities for selection hit-testing.

import simd
import OCCTSwiftViewport

/// Geometry helper functions for sub-body selection.
enum GeometryUtils {

    /// Shortest distance from a point to a line segment.
    static func pointToSegmentDistance(
        point: SIMD3<Float>,
        a: SIMD3<Float>,
        b: SIMD3<Float>
    ) -> Float {
        let ab = b - a
        let ap = point - a
        let lengthSq = simd_dot(ab, ab)
        guard lengthSq > 1e-12 else { return simd_distance(point, a) }

        let t = simd_clamp(simd_dot(ap, ab) / lengthSq, 0, 1)
        let closest = a + ab * t
        return simd_distance(point, closest)
    }

    /// Shortest distance from a point to a polyline (sequence of connected segments).
    static func pointToPolylineDistance(
        point: SIMD3<Float>,
        polyline: [SIMD3<Float>]
    ) -> Float {
        guard polyline.count >= 2 else { return .infinity }
        var minDist: Float = .infinity
        for i in 0..<(polyline.count - 1) {
            let d = pointToSegmentDistance(point: point, a: polyline[i], b: polyline[i + 1])
            minDist = min(minDist, d)
        }
        return minDist
    }

    /// Intersects a ray with a specific triangle from a body's geometry.
    ///
    /// Returns the 3D hit point in the body's local space (`transform` is not applied), or nil if
    /// the triangle index or one of its vertices is out of range, the body has no mesh, or there
    /// is no intersection. Reads a direct-mesh body (`usesDirectMesh`) and an interleaved one.
    static func hitPointOnTriangle(
        ray: Ray,
        body: ViewportBody,
        triangleIndex: Int
    ) -> SIMD3<Float>? {
        let baseIndex = triangleIndex * 3
        guard baseIndex >= 0, baseIndex + 2 < body.indices.count,
            // Direct-mesh bodies keep their positions in `meshPositions`, not `vertexData`.
            let reader = MeshVertexReader(body),
            let v0 = reader.position(at: Int(body.indices[baseIndex])),
            let v1 = reader.position(at: Int(body.indices[baseIndex + 1])),
            let v2 = reader.position(at: Int(body.indices[baseIndex + 2]))
        else { return nil }

        guard let t = ray.intersectsTriangle(v0: v0, v1: v1, v2: v2) else { return nil }
        return ray.origin + ray.direction * t
    }
}
