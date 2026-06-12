// MeasurementPicking.swift
// ViewportKit
//
// Reconstructs a world-space surface point from a GPU pick result, for
// tap-to-measure interaction.

import simd

extension ViewportBody {
    /// World-space position where `ray` intersects the triangle at `triangleIndex`,
    /// accounting for this body's `transform`.
    ///
    /// The triangle vertices are looked up from `indices` / `vertexData` (stride 6:
    /// position + normal), transformed into world space, then intersected with the
    /// ray via Moller-Trumbore. Returns `nil` if the index is out of range or the
    /// ray misses the (transformed) triangle.
    ///
    /// `triangleIndex` matches `PickResult.triangleIndex` for a `.face` pick.
    public func worldHitPoint(ray: Ray, triangleIndex: Int) -> SIMD3<Float>? {
        let stride = 6
        let base = triangleIndex * 3
        guard base >= 0, base + 2 < indices.count else { return nil }

        let i0 = Int(indices[base])
        let i1 = Int(indices[base + 1])
        let i2 = Int(indices[base + 2])

        func worldVertex(_ idx: Int) -> SIMD3<Float>? {
            let b = idx * stride
            guard b + 2 < vertexData.count else { return nil }
            let local = SIMD4<Float>(vertexData[b], vertexData[b + 1], vertexData[b + 2], 1)
            let world = transform * local
            return SIMD3<Float>(world.x, world.y, world.z)
        }

        guard let v0 = worldVertex(i0),
              let v1 = worldVertex(i1),
              let v2 = worldVertex(i2) else { return nil }

        guard let t = ray.intersectsTriangle(v0: v0, v1: v1, v2: v2) else { return nil }
        return ray.origin + ray.direction * t
    }
}
